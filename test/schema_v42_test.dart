import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The schema-v42 applier pins: created_at/updated_at projection, the
/// tag_ids column maintenance, the plaintext FTS backend (the v42
/// migration's fts table + the repository indexer), and the class-node
/// projection (the TS store's INSERT OR IGNORE INTO node parity) with its
/// row-LWW mirror on class.update and the delete/restore registry mirror.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const ws = '0192a000-0000-7000-8000-000000000001';
  const actor = '0192a000-0000-7000-8000-000000000002';

  late AppDatabase database;
  late NodeCacheRepository cache;
  late RelayAppliers appliers;

  OperationEnvelope envelope(
    String opType,
    String objectId,
    int physical,
    String timestamp,
    Map<String, dynamic> payload,
  ) =>
      OperationEnvelope(
        id: '0192a000-0000-7000-8000-00000000d$physical',
        workspaceId: ws,
        actorId: actor,
        deviceId: 'v42-test-device',
        hlc: Hlc(physical: physical, logical: 0),
        affectedNodeIds: [objectId],
        opType: opType,
        payload: payload,
        timestamp: timestamp,
      );

  Future<Map<String, Object?>?> nodeRow(String uuid) async {
    final db = await database.database;
    final rows = await db.rawQuery(
      'SELECT * FROM node_cache WHERE uuid = ?',
      [uuid],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> ftsRows() async {
    final db = await database.database;
    return db.rawQuery(
      'SELECT d.node_id AS node_id, s.content AS content '
      'FROM search_index_fts_docid d '
      'JOIN search_index_fts s ON s.rowid = d.docid ORDER BY d.node_id',
    );
  }

  setUp(() async {
    final ffiDb = await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    database = AppDatabase.fromDatabase(ffiDb);
    await database.initializeSchema();
    cache = NodeCacheRepository(database);
    appliers = RelayAppliers(cache);
  });

  tearDown(() async {
    await database.close();
    AppDatabase.reset();
  });

  group('created_at / updated_at projection', () {
    const page = '0192a000-0000-7000-8000-000000000101';

    test('object.create stamps both with the envelope timestamp', () async {
      await appliers.apply(envelope('object.create', page, 10,
          '2026-11-01T09:00:00.000Z', {
        'objectId': page,
        'isEmbedded': false,
        'classIds': <String>[],
      }));
      final row = await nodeRow(page);
      expect(row!['created_at'], '2026-11-01T09:00:00.000Z');
      expect(row['updated_at'], '2026-11-01T09:00:00.000Z');
    });

    test('object.update bumps updated_at, created_at rides the create', () async {
      await appliers.apply(envelope('object.create', page, 10,
          '2026-11-01T09:00:00.000Z', {
        'objectId': page,
        'isEmbedded': false,
        'classIds': <String>[],
      }));
      await appliers.apply(envelope('object.update', page, 20,
          '2026-11-02T10:00:00.000Z', {
        'objectId': page,
        'contentAst': [
          {'type': 'text', 'text': 'Edited title'}
        ],
      }));
      final row = await nodeRow(page);
      expect(row!['created_at'], '2026-11-01T09:00:00.000Z');
      expect(row['updated_at'], '2026-11-02T10:00:00.000Z');
    });

    test('a soft delete bumps updated_at (TS parity) and restore leaves it',
        () async {
      await appliers.apply(envelope('object.create', page, 10,
          '2026-11-01T09:00:00.000Z', {
        'objectId': page,
        'isEmbedded': false,
        'classIds': <String>[],
      }));
      await appliers.apply(envelope('object.delete', page, 20,
          '2026-11-03T08:00:00.000Z', {
        'objectId': page,
      }));
      final deleted = await nodeRow(page);
      expect(deleted!['is_archived'], 1);
      expect(deleted['updated_at'], '2026-11-03T08:00:00.000Z');
      expect(deleted['created_at'], '2026-11-01T09:00:00.000Z');
      await appliers.apply(envelope('object.restore', page, 30,
          '2026-11-03T09:00:00.000Z', {
        'objectId': page,
      }));
      final restored = await nodeRow(page);
      expect(restored!['is_archived'], 0);
      // TS restore does NOT bump node.updated_at (only the class registry).
      expect(restored['updated_at'], '2026-11-03T08:00:00.000Z');
    });
  });

  group('tag_ids projection', () {
    const page = '0192a000-0000-7000-8000-000000000102';
    const tag1 = '0192a000-0000-7000-8000-0000000000c1';
    const tag2 = '0192a000-0000-7000-8000-0000000000c2';

    test('create seeds the column; a re-issued create re-derives it', () async {
      await appliers.apply(envelope('object.create', page, 10,
          '2026-11-01T09:00:00.000Z', {
        'objectId': page,
        'isEmbedded': false,
        'classIds': <String>[],
        'tagIds': [tag1],
      }));
      var row = await nodeRow(page);
      expect(jsonDecode(row!['tag_ids'] as String), [tag1]);
      // The membership carrier re-issue (add-wins) re-derives the list.
      await appliers.apply(envelope('object.create', page, 20,
          '2026-11-02T09:00:00.000Z', {
        'objectId': page,
        'classIds': <String>[],
        'tagIds': [tag1, tag2],
      }));
      row = await nodeRow(page);
      expect(jsonDecode(row!['tag_ids'] as String), [tag1, tag2]);
    });
  });

  group('the plaintext FTS backend (search_index_fts)', () {
    const page = '0192a000-0000-7000-8000-000000000103';

    test('a create indexes the folded plaintext through the docid map',
        () async {
      await appliers.apply(envelope('object.create', page, 10,
          '2026-11-01T09:00:00.000Z', {
        'objectId': page,
        'isEmbedded': false,
        'classIds': <String>[],
        'contentAst': [
          {'type': 'text', 'text': 'Perú itinerary'}
        ],
      }));
      final rows = await ftsRows();
      expect(rows, hasLength(1));
      expect(rows.first['node_id'], page);
      // Diacritic-folded (the foldSearchText mirror), case preserved.
      expect(rows.first['content'], 'Peru itinerary');
    });

    test('an update re-indexes; an archival purges the row', () async {
      await appliers.apply(envelope('object.create', page, 10,
          '2026-11-01T09:00:00.000Z', {
        'objectId': page,
        'isEmbedded': false,
        'classIds': <String>[],
        'contentAst': [
          {'type': 'text', 'text': 'First title'}
        ],
      }));
      await appliers.apply(envelope('object.update', page, 20,
          '2026-11-02T09:00:00.000Z', {
        'objectId': page,
        'contentAst': [
          {'type': 'text', 'text': 'Second title'}
        ],
      }));
      var rows = await ftsRows();
      expect(rows, hasLength(1));
      expect(rows.first['content'], 'Second title');
      await appliers.apply(envelope('object.delete', page, 30,
          '2026-11-03T09:00:00.000Z', {
        'objectId': page,
      }));
      rows = await ftsRows();
      expect(rows, isEmpty);
    });

    test('a hard delete purges the fts rows with the subtree', () async {
      await appliers.apply(envelope('object.create', page, 10,
          '2026-11-01T09:00:00.000Z', {
        'objectId': page,
        'isEmbedded': false,
        'classIds': <String>[],
        'contentAst': [
          {'type': 'text', 'text': 'Doomed'}
        ],
      }));
      expect(await ftsRows(), hasLength(1));
      await appliers.apply(envelope('object.delete', page, 20,
          '2026-11-03T09:00:00.000Z', {
        'objectId': page,
        'permanent': true,
      }));
      expect(await ftsRows(), isEmpty);
      final db = await database.database;
      final docidRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM search_index_fts_docid',
      );
      expect(docidRows.first['count'], 0);
    });
  });

  group('the class-node projection (schema v42)', () {
    const genre = '0192a000-0000-7000-8000-0000000000e1';

    OperationEnvelope classCreate(int physical, String timestamp) =>
        envelope('class.create', genre, physical, timestamp, {
          'classId': genre,
          'contentAst': [
            {'type': 'text', 'text': 'Genre collection'}
          ],
          'icon': 'book',
          'color': 'red',
        });

    test('class.create projects a node row (title-is-content, root-locked)',
        () async {
      await appliers.apply(classCreate(10, '2026-11-01T09:00:00.000Z'));
      final row = await nodeRow(genre);
      expect(row, isNotNull);
      expect(row!['is_class'], 1);
      expect(row['parent_uuid'], isNull);
      expect(row['is_embedded'], 0);
      expect(row['is_page'], 0);
      expect(row['created_at'], '2026-11-01T09:00:00.000Z');
      expect(row['updated_at'], '2026-11-01T09:00:00.000Z');
      final content = jsonDecode(row['name'] as String) as List<dynamic>;
      expect(content.first['text'], 'Genre collection');
      final node = await cache.getByUuid(genre);
      expect(node!.displayName, 'Genre collection');
      expect(node.isClass, isTrue);
    });

    test('class.update mirrors to the node row under the row LWW', () async {
      await appliers.apply(classCreate(10, '2026-11-01T09:00:00.000Z'));
      // A newer update lands.
      await appliers.apply(envelope(
          'class.update', genre, 30, '2026-11-03T09:00:00.000Z', {
        'classId': genre,
        'contentAst': [
          {'type': 'text', 'text': 'Newer title'}
        ],
      }));
      var node = await cache.getByUuid(genre);
      expect(node!.displayName, 'Newer title');
      // A STALE update (lower HLC) does not touch the node row — but the
      // registry keeps its replace semantics (the TS parity).
      await appliers.apply(envelope(
          'class.update', genre, 20, '2026-11-02T09:00:00.000Z', {
        'classId': genre,
        'contentAst': [
          {'type': 'text', 'text': 'Stale title'}
        ],
      }));
      node = await cache.getByUuid(genre);
      expect(node!.displayName, 'Newer title');
      expect((await cache.getClassByUuid(genre))!.name, 'Stale title');
    });

    test('a user-class delete trashes the node row with the registry; '
        'restore revives both', () async {
      await appliers.apply(classCreate(10, '2026-11-01T09:00:00.000Z'));
      await appliers.apply(envelope(
          'object.delete', genre, 20, '2026-11-03T09:00:00.000Z', {
        'objectId': genre,
      }));
      var row = await nodeRow(genre);
      expect(row!['is_archived'], 1);
      expect(await cache.classActiveState(genre), isFalse);
      await appliers.apply(envelope(
          'object.restore', genre, 30, '2026-11-03T10:00:00.000Z', {
        'objectId': genre,
      }));
      row = await nodeRow(genre);
      expect(row!['is_archived'], 0);
      expect(await cache.classActiveState(genre), isTrue);
    });
  });
}
