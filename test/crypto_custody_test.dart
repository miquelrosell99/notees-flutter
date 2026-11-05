@Timeout(Duration(minutes: 2))
library;

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/crypto/crypto_custody.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/data/repositories/auth_repository.dart';
import 'package:notees/domain/models/relay/payload_crypto.dart';

/// Custody wiring (plan-04 F5): the login kdf record derives the in-memory
/// master key (wrong password ⇒ a login-level error, never a silent keyless
/// session), and workspace open fetch-or-ensures the workspace key with
/// first-write-wins adoption. Keys never touch secure storage.
///
/// The scrypt KDF (N=131072) is deliberately expensive; the derivations are
/// built once per group, not per test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // No-op the flutter_secure_storage channel: token persistence is not what
  // these tests exercise.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );

  const password = 'correct horse battery staple';
  const userJson = <String, dynamic>{
    'id': '30000000-0000-4000-8000-000000000001',
    'uuid': '30000000-0000-4000-8000-000000000001',
    'email': 'user@example.com',
    'name': 'User',
    'role': 'user',
    'is_active': true,
  };

  group('AuthRepository kdf consumption', () {
    late SecureStorage secureStorage;
    // One scrypt derivation for the whole group (the KDF is the expensive
    // step; each login below re-derives from the SAME record).
    late final MasterAndKdf masterAndKdf;

    setUpAll(() async {
      masterAndKdf = await buildMasterAndKdf(password);
    });

    setUp(() {
      secureStorage = const SecureStorage();
    });

    tearDown(() {
      clearCryptoCustody();
    });

    Dio loginDio(Map<String, dynamic> Function() body) {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/auth/login') {
              handler.resolve(Response(
                requestOptions: options,
                data: body(),
                statusCode: 200,
              ));
              return;
            }
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'unexpected request: ${options.path}',
            ));
          },
        ),
      );
      return dio;
    }

    test('login with a kdf record derives + holds the master key', () async {
      final repo = AuthRepository(dio: loginDio(() => {
            'token': 'tok',
            'user': userJson,
            'kdf': masterAndKdf.record.toJson(),
          }), secureStorage: secureStorage);
      final result = await repo.login(
        email: 'user@example.com',
        password: password,
      );

      expect(result, isA<LoginSuccess>());
      expect(hasMasterKey, isTrue);
    });

    test('wrong password fails at the verifier as a login error', () async {
      final repo = AuthRepository(dio: loginDio(() => {
            'token': 'tok',
            'user': userJson,
            'kdf': masterAndKdf.record.toJson(),
          }), secureStorage: secureStorage);

      expect(
        repo.login(email: 'user@example.com', password: 'wrong password'),
        throwsA(isA<AuthException>()),
      );
      expect(hasMasterKey, isFalse);
    });

    test('a keyless login response drops custody (no master held)', () async {
      // First establish custody, then sign in somewhere keyless.
      await deriveMasterKey(password, masterAndKdf.record.toJson());
      expect(hasMasterKey, isTrue);

      final repo = AuthRepository(dio: loginDio(() => {
            'token': 'tok',
            'user': userJson,
          }), secureStorage: secureStorage);
      await repo.login(email: 'user@example.com', password: password);

      expect(hasMasterKey, isFalse);
    });

    test('a 2FA-completed response has no password: a stale master slot '
        'drops even when the response carries a kdf record', () async {
      // First establish custody (a previous account/session), then complete
      // a 2FA challenge — the response carries the kdf record but the client
      // has no password at this point, so it cannot derive; the stale slot
      // must not serve the new session.
      await deriveMasterKey(password, masterAndKdf.record.toJson());
      expect(hasMasterKey, isTrue);

      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/auth/2fa/verify') {
              handler.resolve(Response(
                requestOptions: options,
                data: {
                  'token': 'tok',
                  'user': userJson,
                  'kdf': masterAndKdf.record.toJson(),
                },
                statusCode: 200,
              ));
              return;
            }
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'unexpected request: ${options.path}',
            ));
          },
        ),
      );
      final repo =
          AuthRepository(dio: dio, secureStorage: secureStorage);
      await repo.verifyTwoFactor(preauthToken: 'pre', code: '123456');

      expect(hasMasterKey, isFalse);
    });
  });

  // Distinct workspace ids per ensure test: the custody cache is
  // module-level state shared across tests in this isolate.
  const workspace404 = '10000000-0000-4000-8000-0000000000f1';
  const workspaceCached = '10000000-0000-4000-8000-0000000000f2';
  const workspaceExisting = '10000000-0000-4000-8000-0000000000f3';
  const workspaceConflict = '10000000-0000-4000-8000-0000000000f4';
  const workspaceForeign = '10000000-0000-4000-8000-0000000000f5';
  const workspaceNoMaster = '10000000-0000-4000-8000-0000000000f6';

  group('ensureWorkspaceKey (fetch-or-ensure, first write wins)', () {
    // One derivation for the whole group; individual tests reuse the held
    // master (the 'no master' test re-derives at its end).
    late final MasterAndKdf masterAndKdf;

    setUpAll(() async {
      masterAndKdf = await buildMasterAndKdf(password);
    });

    setUp(() async {
      // Cheap guard (sub-second): a preceding test may have dropped custody.
      if (!hasMasterKey) {
        await deriveMasterKey(password, masterAndKdf.record.toJson());
      }
    });

    tearDownAll(() {
      clearCryptoCustody();
    });

    /// Scripts the key routes for [ws]: GET serves [storedWrapped] (404 when
    /// null); a PUT stores the wrapped key it carries. Each test uses its
    /// own workspace id — the custody cache is module-level state.
    Dio keyDio({
      required String ws,
      String? storedWrapped,
      List<String>? getLog,
      List<String>? putLog,
    }) {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/workspaces/$ws/key') {
              if (options.method == 'GET') {
                getLog?.add('GET');
                if (storedWrapped == null) {
                  handler.reject(DioException(
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: 404,
                    ),
                    type: DioExceptionType.badResponse,
                  ));
                  return;
                }
                handler.resolve(Response(
                  requestOptions: options,
                  data: {'wrappedKey': storedWrapped},
                  statusCode: 200,
                ));
                return;
              }
              // PUT
              if (putLog != null) {
                putLog.add(
                  (options.data as Map<String, dynamic>)['wrappedKey']
                      as String,
                );
              }
              storedWrapped =
                  (options.data as Map<String, dynamic>)['wrappedKey']
                      as String;
              handler.resolve(Response(requestOptions: options, statusCode: 204));
              return;
            }
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'unexpected request: ${options.path}',
            ));
          },
        ),
      );
      return dio;
    }

    test('404: generates, wraps, stores, and returns the new key',
        () async {
      final getLog = <String>[];
      final putLog = <String>[];
      final dio = keyDio(ws: workspace404, getLog: getLog, putLog: putLog);

      final key = await ensureWorkspaceKey(dio, workspace404);
      expect(await exportWorkspaceKey(key), hasLength(32));
      expect(getLog, ['GET']);
      expect(putLog, hasLength(1));

      // The stored wrapped key opens under the master.
      final reopened = await unwrapWorkspaceKey(
        masterAndKdf.master,
        putLog.single,
      );
      expect(await reopened.extractBytes(), await key.extractBytes());
    });

    test('second ensure for the same workspace is cached (no re-fetch)',
        () async {
      final getLog = <String>[];
      final dio = keyDio(ws: workspaceCached, getLog: getLog);

      final first = await ensureWorkspaceKey(dio, workspaceCached);
      final second = await ensureWorkspaceKey(dio, workspaceCached);
      expect(await first.extractBytes(), await second.extractBytes());
      expect(getLog, ['GET']); // one fetch, served from the cache after
    });

    test('existing wrapped key: fetch + unwrap', () async {
      final existing = generateWorkspaceKey();
      final wrapped =
          await wrapWorkspaceKey(masterAndKdf.master, existing);
      final dio = keyDio(ws: workspaceExisting, storedWrapped: wrapped);

      final key = await ensureWorkspaceKey(dio, workspaceExisting);
      expect(await key.extractBytes(), await existing.extractBytes());
    });

    test('PUT 409: adopts the winner instead of splitting the workspace',
        () async {
      // The winner stored ITS key while our PUT raced; the GET after the
      // 409 serves the winner's wrapped key.
      final winnerKey = generateWorkspaceKey();
      final winnerWrapped =
          await wrapWorkspaceKey(masterAndKdf.master, winnerKey);
      var getCalls = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path != '/workspaces/$workspaceConflict/key') {
              handler.reject(DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                error: 'unexpected request: ${options.path}',
              ));
              return;
            }
            if (options.method == 'GET') {
              getCalls++;
              // First GET: keyless workspace. The adopt re-GET: the winner.
              if (getCalls == 1) {
                handler.reject(DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 404,
                  ),
                  type: DioExceptionType.badResponse,
                ));
                return;
              }
              handler.resolve(Response(
                requestOptions: options,
                data: {'wrappedKey': winnerWrapped},
                statusCode: 200,
              ));
              return;
            }
            handler.reject(DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 409,
              ),
              type: DioExceptionType.badResponse,
            ));
          },
        ),
      );

      final key = await ensureWorkspaceKey(dio, workspaceConflict);
      expect(await key.extractBytes(), await winnerKey.extractBytes());
      expect(getCalls, 2);
    });

    test('a stored key under a different master is a loud error', () async {
      final otherMaster = generateMasterKey();
      final foreign = generateWorkspaceKey();
      final dio = keyDio(
        ws: workspaceForeign,
        storedWrapped: await wrapWorkspaceKey(otherMaster, foreign),
      );

      expect(
        ensureWorkspaceKey(dio, workspaceForeign),
        throwsA(isA<StateError>()),
      );
    });

    test('no master key held: loud error, not a silent keyless ensure',
        () async {
      clearCryptoCustody();
      addTearDown(() async {
        // Restore the group-shared custody for any test that follows.
        await deriveMasterKey(password, masterAndKdf.record.toJson());
      });
      final dio = keyDio(ws: workspaceNoMaster);
      expect(
        ensureWorkspaceKey(dio, workspaceNoMaster),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('resolveWorkspaceKey (fail-loud ruling)', () {
    // Distinct workspace ids per test (module-level custody cache).
    const wsOk = '10000000-0000-4000-8000-0000000000e1';
    const wsWrongMaster = '10000000-0000-4000-8000-0000000000e2';
    const wsOffline = '10000000-0000-4000-8000-0000000000e3';
    const wsProbeLocked = '10000000-0000-4000-8000-0000000000e4';
    const wsProbeKeyless = '10000000-0000-4000-8000-0000000000e5';

    late final MasterAndKdf masterAndKdf;

    setUpAll(() async {
      masterAndKdf = await buildMasterAndKdf(password);
      await deriveMasterKey(password, masterAndKdf.record.toJson());
    });

    setUp(() async {
      if (!hasMasterKey) {
        await deriveMasterKey(password, masterAndKdf.record.toJson());
      }
    });

    tearDownAll(() {
      clearCryptoCustody();
    });

    /// Key routes for [ws]: GET serves [storedWrapped] (404 when null); a
    /// PUT stores the wrapped key; everything fails with a connection error
    /// when [offline].
    Dio probeDio({
      required String ws,
      String? storedWrapped,
      bool offline = false,
    }) {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (offline || options.path != '/workspaces/$ws/key') {
              handler.reject(DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                error: 'offline',
              ));
              return;
            }
            if (options.method == 'GET') {
              if (storedWrapped == null) {
                handler.reject(DioException(
                  requestOptions: options,
                  response: Response(
                    requestOptions: options,
                    statusCode: 404,
                  ),
                  type: DioExceptionType.badResponse,
                ));
                return;
              }
              handler.resolve(Response(
                requestOptions: options,
                data: {'wrappedKey': storedWrapped},
                statusCode: 200,
              ));
              return;
            }
            storedWrapped =
                (options.data as Map<String, dynamic>)['wrappedKey']
                    as String;
            handler.resolve(Response(requestOptions: options, statusCode: 204));
          },
        ),
      );
      return dio;
    }

    test('master held + fetch-or-ensure succeeds: the open is sealed',
        () async {
      final resolution =
          await resolveWorkspaceKey(probeDio(ws: wsOk), wsOk);
      expect(resolution.locked, isFalse);
      expect(resolution.key, isNotNull);
    });

    test('master held + stored key under another master: the wrapped row '
        'proves keyed → locked', () async {
      final otherMaster = generateMasterKey();
      final foreign = generateWorkspaceKey();
      final dio = probeDio(
        ws: wsWrongMaster,
        storedWrapped: await wrapWorkspaceKey(otherMaster, foreign),
      );
      final resolution =
          await resolveWorkspaceKey(dio, wsWrongMaster);
      expect(resolution.locked, isTrue);
      expect(resolution.key, isNull);
    });

    test('master held + relay unreachable: an HTTP failure with no proof '
        'of keying stays keyless', () async {
      final resolution =
          await resolveWorkspaceKey(probeDio(ws: wsOffline, offline: true), wsOffline);
      expect(resolution.locked, isFalse);
      expect(resolution.key, isNull);
    });

    test('no master + wrapped row: locked (the row needs only membership)',
        () async {
      clearCryptoCustody();
      addTearDown(() async {
        await deriveMasterKey(password, masterAndKdf.record.toJson());
      });
      final existing = generateWorkspaceKey();
      final dio = probeDio(
        ws: wsProbeLocked,
        storedWrapped:
            await wrapWorkspaceKey(masterAndKdf.master, existing),
      );
      final resolution =
          await resolveWorkspaceKey(dio, wsProbeLocked);
      expect(resolution.locked, isTrue);
      expect(resolution.key, isNull);
    });

    test('no master + no wrapped row: keyless open', () async {
      clearCryptoCustody();
      addTearDown(() async {
        await deriveMasterKey(password, masterAndKdf.record.toJson());
      });
      final resolution =
          await resolveWorkspaceKey(probeDio(ws: wsProbeKeyless), wsProbeKeyless);
      expect(resolution.locked, isFalse);
      expect(resolution.key, isNull);
    });
  });
}

/// A master key plus its server-style kdf record, built once per test.
class MasterAndKdf {
  MasterAndKdf(this.master, this.record);
  final SecretKey master;
  final KdfRecord record;
}

Future<MasterAndKdf> buildMasterAndKdf(String password) async {
  final master = generateMasterKey();
  final record = await createKdfRecord(master, password);
  return MasterAndKdf(master, record);
}
