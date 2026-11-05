import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/data/repositories/auth_repository.dart';

/// `POST /auth/unlock` (the W2 unlock re-prompt's server half): returns
/// {kdf} only — NO session is minted; the same per-IP counter and
/// per-account lockout as login. Wrong password is the form error;
/// account-locked carries the retry-after message.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );

  const email = 'user@example.com';
  const password = 'correct horse battery staple';
  const kdf = <String, dynamic>{
    'algorithm': 'scrypt',
    'N': 131072,
    'r': 8,
    'p': 1,
    'salt': 'AQIDBAUGBwgJCgsMDQ4PEA',
    'wrappedMasterKey': 'oKGio6SlpqeoqaqrEa5lc67bpNjQU9ACvDQTRW',
    'keyVerifier': '12aPlhN1yihN2nOKLlxUSperu4hEr-qg2LS54MbGTtk',
  };

  /// Serves /auth/unlock with [status]; the body mirrors the server's wire
  /// error envelope {error: {code, message, status}}.
  Dio unlockDio(int status) {
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/auth/unlock') {
            if (status == 200) {
              handler.resolve(Response(
                requestOptions: options,
                data: const {'kdf': kdf},
                statusCode: 200,
              ));
              return;
            }
            final message = status == 401
                ? 'invalid email or password'
                : 'too many failed attempts — try again in 5 minutes';
            handler.reject(DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: status,
                data: {
                  'error': {
                    'code': status == 401
                        ? 'invalid_credentials'
                        : 'account_locked',
                    'message': message,
                    'status': status,
                  },
                },
              ),
              type: DioExceptionType.badResponse,
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

  AuthRepository repoFor(int status) => AuthRepository(
        dio: unlockDio(status),
        secureStorage: const SecureStorage(),
      );

  group('AuthRepository.unlock', () {
    test('returns the kdf record on success (no session minted)', () async {
      final kdfJson = await repoFor(200).unlock(
        email: email,
        password: password,
      );
      expect(kdfJson, kdf);
    });

    test('wrong password surfaces the server message as a form error',
        () async {
      Object? error;
      try {
        await repoFor(401).unlock(email: email, password: 'wrong');
      } catch (e) {
        error = e;
      }
      expect(error, isA<AuthException>());
      expect((error! as AuthException).message, 'invalid email or password');
    });

    test('account locked surfaces the retry-after message', () async {
      Object? error;
      try {
        await repoFor(429).unlock(email: email, password: password);
      } catch (e) {
        error = e;
      }
      expect(error, isA<AuthException>());
      expect((error! as AuthException).message,
          contains('try again in 5 minutes'));
    });

    test('a success body without a kdf record fails loud', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(Response(
              requestOptions: options,
              data: const {'ok': true},
              statusCode: 200,
            ));
          },
        ),
      );
      final repo =
          AuthRepository(dio: dio, secureStorage: const SecureStorage());
      expect(
        repo.unlock(email: email, password: password),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
