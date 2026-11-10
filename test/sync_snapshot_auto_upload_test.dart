import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/payload_crypto.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:notees/features/home/providers/connectivity_provider.dart';
import 'package:notees/features/settings/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// In-memory stand-in for the relay: an op log, an optional snapshot row
/// (meta + blob), request counters, and failure scripting.
class FakeRelay {
  final envelopes = <Map<String, dynamic>>[];
  Uint8List? snapshotBlob;
  bool snapshotSealed = false;
  int snapshotHlcPhysical = 0;
  var putCount = 0;
  var partCount = 0;
  var commitCount = 0;
  Map<String, dynamic>? lastCommit;
  Map<String, dynamic>? lastPutQuery;
  String? lastUploadId;
  int? rejectPutStatus;
  var nextSeq = 0;

  void addEnvelope(Map<String, dynamic> envelope) {
    nextSeq++;
    envelopes.add({...envelope, 'seq': nextSeq});
  }

  Map<String, dynamic> snapshotMeta() => {
        'snapshotId': snapshotBlob != null ? 'snap-1' : null,
        'hlc': {
          'physical': snapshotBlob != null ? snapshotHlcPhysical : 0,
          'logical': 0,
        },
        'hasSnapshot': snapshotBlob != null,
        'restoreEpoch': 0,
        'upToSeq': null,
        'sealed': snapshotSealed,
      };
}

Map<String, dynamic> createEnvelope(
  String objectId,
  String text, {
  int physical = 1,
}) =>
    {
      'id': '0192a000-0000-7000-8000-${physical.toString().padLeft(12, '0')}',
      'protocolVersion': 3,
      'workspaceId': workspaceId,
      'actorId': user1,
      'deviceId': device,
      'hlc': {'physical': physical, 'logical': 0},
      'affectedNodeIds': [objectId],
      'opType': 'object.create',
      'payload': {
        'objectId': objectId,
        'contentAst': [
          {'type': 'text', 'text': text},
        ],
        'isEmbedded': false,
        'classIds': <String>[],
      },
      'timestamp': '2026-09-24T12:00:00.000Z',
    };

const workspaceId = '10000000-0000-4000-8000-000000000001';
const node1 = '20000000-0000-4000-8000-000000000001';
const user1 = '30000000-0000-4000-8000-000000000001';
const device = '40000000-0000-4000-8000-000000000001';

final workspaceKey = importWorkspaceKey(
  b64uEncode(List<int>.generate(32, (i) => 0x42)),
);

/// Snapshot AUTO-upload (`maybeUploadSnapshot` parity): the watermark gate
/// matrix, the file-based pipeline (transport selection, size rules, temp
/// cleanup), the 413/oversize warn-once reports, and the network gate.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  // The pipeline builds/seals snapshot images in temp files via path_provider.
  final tempDir = Directory.systemTemp.createTempSync('notees_upload_test');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => tempDir.path,
  );

  List<FileSystemEntity> snapshotTempFiles() => tempDir
      .listSync()
      .where((entity) => entity.path.contains('notees_snapshot_'))
      .toList();

  Dio buildDio(FakeRelay relay) {
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.path == '/relay/v2/snapshot') {
            handler.resolve(Response(
              requestOptions: options,
              data: relay.snapshotMeta(),
              statusCode: 200,
            ));
            return;
          }
          if (options.path == '/relay/v2/snapshot/data' &&
              options.method == 'GET') {
            final blob = relay.snapshotBlob;
            if (blob == null) {
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
              data: blob.toList(),
              statusCode: 200,
            ));
            return;
          }
          if (options.path == '/relay/v2/snapshot/data' &&
              options.method == 'PUT') {
            relay.putCount++;
            relay.lastPutQuery =
                Map<String, dynamic>.from(options.queryParameters);
            final status = relay.rejectPutStatus;
            if (status != null) {
              handler.reject(DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: status,
                ),
                type: DioExceptionType.badResponse,
              ));
              return;
            }
            final body = options.data;
            final List<int> bytes;
            if (body is Stream) {
              final drained = <int>[];
              await for (final chunk in body.cast<List<int>>()) {
                drained.addAll(chunk);
              }
              bytes = drained;
            } else {
              bytes = (body as List<int>?) ?? const <int>[];
            }
            relay.snapshotBlob = Uint8List.fromList(bytes);
            relay.snapshotSealed = options.queryParameters['sealed'] == '1';
            relay.snapshotHlcPhysical =
                (options.queryParameters['physical'] as int?) ?? 0;
            handler.resolve(Response(requestOptions: options, statusCode: 204));
            return;
          }
          if (options.path == '/relay/v2/snapshot/data/part') {
            relay.partCount++;
            relay.lastUploadId = options.queryParameters['upload'] as String?;
            handler.resolve(Response(
              requestOptions: options,
              data: {'upload': relay.lastUploadId, 'index': 0},
              statusCode: 201,
            ));
            return;
          }
          if (options.path == '/relay/v2/snapshot/data/commit') {
            relay.commitCount++;
            relay.lastCommit =
                Map<String, dynamic>.from(options.queryParameters);
            handler.resolve(Response(
              requestOptions: options,
              data: {'snapshotId': 'snap-committed'},
              statusCode: 201,
            ));
            return;
          }
          if (options.path == '/relay/v2/catch-up') {
            final afterSeq =
                (options.data as Map<String, dynamic>)['afterSeq'] as int? ??
                    0;
            final page = relay.envelopes
                .where((e) => (e['seq'] as int) > afterSeq)
                .toList();
            handler.resolve(Response(
              requestOptions: options,
              data: {
                'envelopes': page,
                'nextAfterSeq': page.isEmpty ? null : page.last['seq'],
                'hasMore': false,
                'restoreEpoch': 0,
                'totalRemaining': 0,
              },
              statusCode: 200,
            ));
            return;
          }
          handler.resolve(Response(
            requestOptions: options,
            data: const {'savedCount': 1, 'savedIds': ['id']},
            statusCode: 200,
          ));
        },
      ),
    );
    return dio;
  }

  group('SyncV2Service snapshot auto-upload', () {
    late AppDatabase database;

    setUpAll(() {
      NodeCacheRepository.snapshotDbOpener =
          (path) => databaseFactoryFfi.openDatabase(
                path,
                options: OpenDatabaseOptions(singleInstance: false),
              );
    });

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      // Keep pull() from force-resetting the workspace on empty metadata.
      final cache = NodeCacheRepository(database);
      await cache.upsertClass(uuid: 'class-1', name: 'Class');
      await cache.upsertPropertySchema(
        PropertySchemaRow(uuid: 'schema-1', workspaceId: workspaceId, name: 'P'),
      );
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    Future<SyncV2Service> buildService(
      FakeRelay relay, {
      bool keyed = true,
      bool Function()? autoUploadGate,
      int? snapshotChunkThreshold,
      int? snapshotPartSize,
      int? snapshotUploadLimit,
      int? snapshotCompactThreshold,
    }) async {
      final service = SyncV2Service(
        database: database,
        dio: buildDio(relay),
        clientId: device,
        autoUploadGate: autoUploadGate,
        snapshotChunkThreshold: snapshotChunkThreshold,
        snapshotPartSize: snapshotPartSize,
        snapshotUploadLimit: snapshotUploadLimit,
        snapshotCompactThreshold: snapshotCompactThreshold,
      );
      await service.setWorkspaceId(workspaceId);
      if (keyed) service.workspaceKey = workspaceKey;
      return service;
    }

    test('auto-uploads after a pull when the server has no snapshot; the '
        'watermark gates a second pull', () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'checkpoint me'));
      final service = await buildService(relay);

      await service.pull();
      expect(relay.putCount, 1);
      expect(relay.partCount, 0);
      expect(relay.commitCount, 0);
      // Keyed: the blob is sealed, declares sealed=1, covers the received
      // HLC, and opens under the workspace key.
      expect(relay.lastPutQuery!['sealed'], '1');
      expect(relay.lastPutQuery!['physical'], 1);
      final blob = relay.snapshotBlob!;
      final opened = await decryptBytes(workspaceKey, blob);
      expect(latin1.decode(opened, allowInvalid: true)
          .contains('checkpoint me'), isTrue);

      // Second pull: the durable watermark (received == uploaded) suppresses
      // the re-upload even against a lagging/absent server checkpoint.
      await service.pull();
      expect(relay.putCount, 1);
    });

    test('skips when the server snapshot is newer than the received '
        'watermark', () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'content'))
        // A plaintext server snapshot at HLC 99 — a keyed client skips it
        // (the empty-store trap) and must NOT upload over it.
        ..snapshotBlob = Uint8List.fromList(latin1.encode('not a database'))
        ..snapshotHlcPhysical = 99;
      final service = await buildService(relay);

      await service.pull();
      expect(relay.putCount, 0);
      // The server blob is untouched.
      expect(latin1.decode(relay.snapshotBlob!, allowInvalid: true),
          'not a database');
    });

    test('uploads when the server snapshot is older and no upload watermark '
        'exists', () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'content'))
        ..snapshotBlob = Uint8List.fromList(latin1.encode('legacy image'))
        ..snapshotHlcPhysical = 0;
      final service = await buildService(relay);

      await service.pull();
      expect(relay.putCount, 1);
      expect(relay.lastPutQuery!['physical'], 1);
    });

    test('the upload watermark persists across a service rebuild', () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'content'));
      final serviceA = await buildService(relay);
      await serviceA.pull();
      expect(relay.putCount, 1);
      await serviceA.stopRealtime();
      // The server checkpoint lags (or is gone) again.
      relay
        ..snapshotBlob = null
        ..snapshotSealed = false;

      // A fresh service on the same database: the watermark gate (not the
      // server gate) suppresses the re-upload.
      final serviceB = await buildService(relay);
      await serviceB.pull();
      expect(relay.putCount, 1);
    });

    test('keyless session uploads plaintext, unsealed', () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'plain checkpoint'));
      final service = await buildService(relay, keyed: false);

      await service.pull();
      expect(relay.putCount, 1);
      expect(relay.lastPutQuery!.containsKey('sealed'), isFalse);
      // The blob is a plaintext SQLite image.
      expect(relay.snapshotBlob![0], 0x53); // 'S' of the SQLite magic
      expect(
        latin1
            .decode(relay.snapshotBlob!, allowInvalid: true)
            .contains('plain checkpoint'),
        isTrue,
      );
    });

    test('sealed size at/over the chunk threshold rides multipart parts read '
        'from the file', () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'chunked checkpoint'));
      final service = await buildService(
        relay,
        snapshotChunkThreshold: 4 * 1024,
        snapshotPartSize: 2 * 1024,
      );

      await service.pull();
      expect(relay.putCount, 0);
      expect(relay.commitCount, 1);
      expect(relay.partCount, greaterThan(1));
      expect(relay.lastCommit!['sealed'], '1');
      expect(relay.lastCommit!['upload'], isNotNull);
      expect(relay.lastCommit!['physical'], 1);
    });

    test('sealed size below the chunk threshold rides a single PUT streamed '
        'from the file', () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'small checkpoint'));
      final service = await buildService(relay);

      await service.pull();
      expect(relay.putCount, 1);
      expect(relay.partCount, 0);
      expect(relay.commitCount, 0);
    });

    test('a sealed image at/over the upload limit skips with a warn-once '
        'report; the pull still succeeds', () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'oversize checkpoint'));
      final service = await buildService(
        relay,
        snapshotUploadLimit: 4 * 1024,
      );

      final printed = <String>[];
      final oldPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) printed.add(message);
      };
      addTearDown(() => debugPrint = oldPrint);

      await service.pull();
      expect(relay.putCount, 0);
      expect(printed.where((m) => m.contains('body cap')), hasLength(1));

      // Warn-once: a second pull stays silent (and still uploads nothing).
      printed.clear();
      await service.pull();
      expect(relay.putCount, 0);
      expect(printed.where((m) => m.contains('body cap')), isEmpty);
    });

    test('a 413 reports once per session, never fails the pull, and retries '
        'on later pulls', () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'rejected checkpoint'))
        ..rejectPutStatus = 413;
      final service = await buildService(relay);

      final printed = <String>[];
      final oldPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) printed.add(message);
      };
      addTearDown(() => debugPrint = oldPrint);

      // The pull completes despite the rejected upload.
      await service.pull();
      expect(relay.putCount, 1);
      expect(printed.where((m) => m.contains('413')), hasLength(1));

      // The watermark was NOT set: the next pull retries the upload, but the
      // session already reported — silent.
      printed.clear();
      await service.pull();
      expect(relay.putCount, 2);
      expect(printed.where((m) => m.contains('413')), isEmpty);
    });

    test('the network gate suppresses the auto-upload when closed',
        () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'gated checkpoint'));
      final service = await buildService(relay, autoUploadGate: () => false);

      await service.pull();
      expect(relay.putCount, 0);
      expect(relay.snapshotBlob, isNull);
    });

    test('the compact threshold VACUUMs the build file and still uploads',
        () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'compacted checkpoint'));
      final service = await buildService(
        relay,
        snapshotCompactThreshold: 1, // every build compacts
      );

      await service.pull();
      expect(relay.putCount, 1);
      final opened = await decryptBytes(workspaceKey, relay.snapshotBlob!);
      expect(
        latin1.decode(opened, allowInvalid: true)
            .contains('compacted checkpoint'),
        isTrue,
      );
    });

    test('temp files are cleaned after the auto-upload', () async {
      final relay = FakeRelay()
        ..addEnvelope(createEnvelope(node1, 'clean checkpoint'));
      final service = await buildService(relay);

      await service.pull();
      expect(relay.putCount, 1);
      expect(snapshotTempFiles(), isEmpty);
    });
  });

  group('ConnectivityProvider unmetered heuristic', () {
    // The auto-upload's "Wi-Fi only" gate: wifi/ethernet/vpn/other read as
    // unmetered, mobile/satellite as metered, offline never unmetered.
    const cases = <(List<ConnectivityResult>, bool)>[
      ([ConnectivityResult.wifi], true),
      ([ConnectivityResult.ethernet], true),
      ([ConnectivityResult.vpn], true),
      ([ConnectivityResult.other], true),
      ([ConnectivityResult.bluetooth], true),
      ([ConnectivityResult.mobile], false),
      ([ConnectivityResult.satellite], false),
      ([ConnectivityResult.wifi, ConnectivityResult.mobile], false),
      ([ConnectivityResult.none], false),
      (<ConnectivityResult>[], false),
    ];
    for (final (results, expected) in cases) {
      test('${results.map((r) => r.name).join('+')} → unmetered=$expected',
          () {
        expect(ConnectivityProvider.isUnmetered(results), expected);
      });
    }
  });

  group('Settings: upload checkpoints on Wi-Fi only', () {
    test('defaults to on and persists', () async {
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      final settings = SettingsProvider(prefs);
      addTearDown(settings.dispose);

      expect(settings.uploadSnapshotsOnWifiOnly, isTrue);
      await settings.setUploadSnapshotsOnWifiOnly(false);
      expect(settings.uploadSnapshotsOnWifiOnly, isFalse);
      // Re-read from the same prefs: durable.
      expect(prefs.getBool('upload_snapshots_on_wifi_only'), isFalse);
    });
  });
}
