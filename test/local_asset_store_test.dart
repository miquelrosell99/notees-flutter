import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/domain/services/local_asset_store.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('LocalAssetStore', () {
    late Directory tempDir;
    late LocalAssetStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('notees_assets_test');
      store = LocalAssetStore(baseDirectory: tempDir);
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('blob round-trip: hash → store → read → delete', () async {
      final bytes = Uint8List.fromList(utf8.encode('hello asset'));

      final hash = await store.putBytes(bytes);
      expect(hash, hasLength(64)); // SHA-256 hex digest

      final file = await store.blobFile(hash);
      expect(file, isNotNull);
      expect(await file!.readAsBytes(), bytes);
      expect(await store.readBytes(hash), bytes);

      await store.deleteBlob(hash);
      expect(await store.blobFile(hash), isNull);
      expect(await store.readBytes(hash), isNull);
    });

    test('stores blobs content-addressed: same bytes, same hash', () async {
      final first = await store.putBytes(Uint8List.fromList([1, 2, 3]));
      final second = await store.putBytes(Uint8List.fromList([1, 2, 3]));
      expect(first, second);

      final other = await store.putBytes(Uint8List.fromList([1, 2, 4]));
      expect(other, isNot(first));
    });

    test('metadata sidecar round-trip and listing', () async {
      const info = LocalAssetInfo(
        nodeId: 'node-1',
        assetHash: 'hash-1',
        mimeType: 'audio/mp4',
        sizeBytes: 42,
        originalName: 'voice.m4a',
      );
      await store.saveMetadata(info);

      final read = await store.readMetadata('node-1');
      expect(read, isNotNull);
      expect(read!.nodeId, 'node-1');
      expect(read.assetHash, 'hash-1');
      expect(read.mimeType, 'audio/mp4');
      expect(read.sizeBytes, 42);
      expect(read.originalName, 'voice.m4a');
      expect(read.category, 'audio');

      expect(await store.readMetadata('missing'), isNull);

      await store.saveMetadata(
        const LocalAssetInfo(
          nodeId: 'node-2',
          assetHash: 'hash-2',
          mimeType: 'image/png',
          sizeBytes: 7,
          originalName: 'photo.png',
        ),
      );
      final listed = await store.listMetadata();
      expect(listed.map((a) => a.nodeId), containsAll(['node-1', 'node-2']));
    });

    test('mimeTypeForPath categorizes capture file types', () {
      expect(LocalAssetService.mimeTypeForPath('/x/photo.jpg'), 'image/jpeg');
      expect(LocalAssetService.mimeTypeForPath('/x/voice.m4a'), 'audio/mp4');
      expect(LocalAssetService.mimeTypeForPath('/x/blob.bin'),
          'application/octet-stream');
    });
  });

  group('LocalAssetService op sequence', () {
    late Directory tempDir;
    late LocalAssetStore store;
    late AppDatabase database;
    late SyncV2Service syncService;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('notees_assets_test');
      store = LocalAssetStore(baseDirectory: tempDir);
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      syncService = SyncV2Service(
        database: database,
        // No base URL: any network attempt would throw, so tests passing
        // prove the local upload performs no network I/O.
        dio: Dio(),
        clientId: 'test-client',
        serverless: true,
      );
      await syncService.setWorkspaceId('local-ws');
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    Future<File> writeTempFile(String name, List<int> bytes) async {
      final file = File('${tempDir.path}/$name');
      await file.writeAsBytes(bytes);
      return file;
    }

    Future<List<Map<String, dynamic>>> recordedOps() async {
      final db = await database.database;
      return db.query('relay_operations', orderBy: 'rowid');
    }

    test('upload emits node.create + asset.upload mirroring the server shapes',
        () async {
      final file = await writeTempFile('voice.m4a', [10, 20, 30]);
      final service = LocalAssetService(syncService, store: store);

      final info = await service.upload(file, parentUuid: 'parent-1');

      final ops = await recordedOps();
      expect(ops, hasLength(2));

      expect(ops[0]['op_type'], 'node.create');
      final create =
          jsonDecode(ops[0]['payload'] as String) as Map<String, dynamic>;
      expect(create['nodeId'], info.nodeId);
      expect(create['kind'], 'block');
      expect(create['parentId'], 'parent-1');
      expect(create['classIds'], [SystemClassUuids.asset]);
      final initialContent = create['initialContent'] as List<dynamic>;
      expect(initialContent.single['type'], 'paragraph');

      expect(ops[1]['op_type'], 'asset.upload');
      final upload =
          jsonDecode(ops[1]['payload'] as String) as Map<String, dynamic>;
      expect(upload['assetId'], info.nodeId);
      expect(upload['nodeId'], info.nodeId);
      expect(upload['assetHash'], info.assetHash);
      expect(upload['mimeType'], 'audio/mp4');
      expect(upload['sizeBytes'], 3);
      expect(upload['originalName'], 'voice.m4a');

      // The node landed in the derived cache flagged as an asset, and the ops
      // stay in the outbox so a later server attach replays them.
      final node = await syncService.cache.getByUuid(info.nodeId);
      expect(node, isNotNull);
      expect(node!.isAsset, isTrue);
      expect(node.displayName, 'voice');
      final db = await database.database;
      expect(await db.query('relay_outbox'), hasLength(2));

      // Bytes are stored content-addressed on disk.
      expect(await store.readBytes(info.assetHash), [10, 20, 30]);
      expect((await store.readMetadata(info.nodeId))?.assetHash,
          info.assetHash);
    });

    test('conversion emits class.assign + asset.upload', () async {
      await syncService.enqueue(
        type: 'create',
        nodeUuid: 'n-existing',
        contentAst: AstBuilder.parseInline('Block'),
      );
      await syncService.flush();

      final file = await writeTempFile('photo.png', [1, 2, 3, 4]);
      final service = LocalAssetService(syncService, store: store);
      final info = await service.upload(file, existingNodeUuid: 'n-existing');

      expect(info.nodeId, 'n-existing');
      expect(info.mimeType, 'image/png');

      final ops = await recordedOps();
      expect(ops, hasLength(3));
      expect(ops[1]['op_type'], 'class.assign');
      final assign =
          jsonDecode(ops[1]['payload'] as String) as Map<String, dynamic>;
      expect(assign['nodeId'], 'n-existing');
      expect(assign['classId'], SystemClassUuids.asset);
      expect(ops[2]['op_type'], 'asset.upload');

      final node = await syncService.cache.getByUuid('n-existing');
      expect(node!.isAsset, isTrue);
    });

    test('rolls back the blob when op emission fails', () async {
      // A service without a workspace id: emitLocal throws before writing.
      final orphanDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final orphanDatabase = AppDatabase.fromDatabase(orphanDb);
      await orphanDatabase.initializeSchema();
      final noWorkspaceSync = SyncV2Service(
        database: orphanDatabase,
        dio: Dio(),
        clientId: 'test-client',
        serverless: true,
      );
      final service = LocalAssetService(noWorkspaceSync, store: store);
      final file = await writeTempFile('voice.m4a', [10, 20, 30]);
      final expectedHash =
          await LocalAssetStore.hashBytes(Uint8List.fromList([10, 20, 30]));

      await expectLater(
        service.upload(file),
        throwsA(isA<SyncV2Exception>()),
      );

      expect(await store.blobFile(expectedHash), isNull);
      expect(await store.listMetadata(), isEmpty);

      await orphanDatabase.close();
    });
  });
}
