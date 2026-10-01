import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_stringifier.dart';
import '../../core/utils/node_display_name.dart';
import '../../core/utils/search_index_builder.dart';
import '../local/app_database.dart';
import '../models/linked_reference.dart';
import '../models/node.dart';
import '../models/page_content.dart';
import '../models/property.dart';
import '../../domain/models/relay/hlc.dart';
import '../../domain/models/relay/lww.dart';
import '../../domain/models/search_filters.dart';

/// Lightweight in-memory representation of a row from the server's `class` table.
class _ClassRow {
  _ClassRow({
    required this.uuid,
    required this.name,
    this.icon,
    this.color,
    this.description,
    this.extendsUuids = const [],
    this.active = true,
    this.createdAt,
    this.updatedAt,
  });

  final String uuid;
  final String name;
  final String? icon;
  final String? color;
  final String? description;
  final List<String> extendsUuids;
  final bool active;
  final String? createdAt;
  final String? updatedAt;
}

/// Lightweight in-memory representation of a row from the server's
/// `property_schema` table.
class PropertySchemaRow {
  PropertySchemaRow({
    required this.uuid,
    required this.workspaceId,
    required this.name,
    this.icon,
    this.type = 'text',
    this.multi = false,
    this.isSystem = false,
    this.scope = 'global',
    this.nodeUuid,
    this.iconVisibility,
    this.validationRules,
    this.required = false,
    this.readonly = false,
    this.hideWhenEmpty = false,
    this.defaultValue,
    this.classFilterUuids = const [],
    this.options = const [],
    this.computed,
    this.active = true,
    this.createdAt,
    this.updatedAt,
  });

  final String uuid;
  final String workspaceId;
  final String name;
  final String? icon;
  final String type;
  final bool multi;
  final bool isSystem;
  final String scope;
  final String? nodeUuid;
  final String? iconVisibility;
  final Map<String, dynamic>? validationRules;
  final bool required;
  final bool readonly;
  final bool hideWhenEmpty;
  final dynamic defaultValue;
  final List<String> classFilterUuids;
  final List<Map<String, dynamic>> options;
  final String? computed;
  final bool active;
  final String? createdAt;
  final String? updatedAt;
}

/// Lightweight in-memory representation of a row from the server's
/// `class_property_edge` table.
class ClassPropertyEdgeRow {
  ClassPropertyEdgeRow({
    required this.classUuid,
    required this.propertyUuid,
    this.sequence = 0,
    this.defaultValue,
    this.hidden = false,
    this.required,
    this.readonly,
    this.hideWhenEmpty,
  });

  final String classUuid;
  final String propertyUuid;
  final int sequence;
  final dynamic defaultValue;
  final bool hidden;
  final bool? required;
  final bool? readonly;
  final bool? hideWhenEmpty;
}

/// Local cache of server node state populated by pull sync.
class NodeCacheRepository {
  NodeCacheRepository(this._database);

  final AppDatabase _database;

  /// Opens the temp-file DB used by [buildV2SnapshotBytes]. Production uses
  /// the platform sqflite plugin; tests override this with the ffi factory
  /// (sqflite_common_ffi is a dev dependency and cannot be imported here).
  static Future<Database> Function(String path) snapshotDbOpener = openDatabase;

  static const _lastSyncKey = 'sync_v1_last_sync';

  Future<String?> getLastSync() async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_state',
      where: 'key = ?',
      whereArgs: [_lastSyncKey],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setLastSync(String? value) async {
    final db = await _database.database;
    if (value == null) {
      await db.delete(
        'sync_state',
        where: 'key = ?',
        whereArgs: [_lastSyncKey],
      );
      return;
    }
    await db.insert('sync_state', {
      'key': _lastSyncKey,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsert(Node node) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await _upsertNodeInTxn(txn, node);
      await _indexNodeInTxn(txn, node);
    });
  }

  Future<void> upsertMany(List<Node> nodes) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final node in nodes) {
        batch.insert(
          'node_cache',
          _nodeToRow(node, now),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      await _indexNodesInTxn(txn, nodes);
    });
  }

  Future<void> deleteByUuid(String uuid) async {
    final db = await _database.database;
    await db.delete('node_cache', where: 'uuid = ?', whereArgs: [uuid]);
  }

  Future<void> deleteByUuids(List<String> uuids) async {
    if (uuids.isEmpty) return;
    final db = await _database.database;
    final placeholders = uuids.map((_) => '?').join(',');
    await db.rawDelete(
      'DELETE FROM node_cache WHERE uuid IN ($placeholders)',
      uuids,
    );
  }

  /// Hard-deletes [uuid] and its whole subtree plus derived rows, matching
  /// the v2 `object.delete permanent:true` semantics: node rows, search
  /// index, favorites, task completions/recurrence, share rows, content-HLC
  /// markers, class membership, and property rows all go. (The v1 server
  /// cascade only removed the single row; v2 deletes the subtree.)
  Future<void> hardDelete(String uuid) async {
    final ids = await subtreeUuids(uuid);
    if (ids.isEmpty) return;
    final placeholders = ids.map((_) => '?').join(',');
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM node_cache WHERE uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM search_index WHERE node_uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM user_favorite WHERE node_uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM task_completion WHERE node_uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM task_recurrence WHERE node_uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM node_user_share WHERE node_uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM node_content_hlc WHERE node_uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM class_member_set WHERE node_uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM tag_member_set WHERE node_uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM property_value WHERE node_uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM property_value_tombstone WHERE node_uuid IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM collection_member WHERE object_id IN ($placeholders)',
        ids,
      );
      await txn.rawDelete(
        'DELETE FROM edge WHERE source_id IN ($placeholders) OR target_id IN ($placeholders)',
        [...ids, ...ids],
      );
    });
  }

  Future<Node?> getByUuid(String uuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
    if (rows.isEmpty) return null;
    return _nodeFromRow(rows.first);
  }

  Future<List<Node>> getByUuids(List<String> uuids) async {
    if (uuids.isEmpty) return const [];
    final db = await _database.database;
    final placeholders = uuids.map((_) => '?').join(',');
    final rows = await db.rawQuery(
      'SELECT payload FROM node_cache WHERE uuid IN ($placeholders)',
      uuids,
    );
    return rows.map(_nodeFromRow).toList();
  }

  Future<List<Node>> getAll({bool includeDeleted = false}) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where: includeDeleted ? null : 'is_deleted = 0',
    );
    return rows.map(_nodeFromRow).toList();
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete('node_cache');
      await txn.delete('class_member_set');
      await txn.delete('tag_member_set');
      await txn.delete('class_extends');
      await txn.delete('class_hierarchy');
      await txn.delete('property_value');
      await txn.delete('property_value_tombstone');
      await txn.delete('collection_member');
      await txn.delete('edge');
      await txn.delete('class_property');
    });
  }

  /// Ids of [uuid] and its whole subtree (inclusive), via a parent walk.
  Future<List<String>> subtreeUuids(String uuid) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      '''
      WITH RECURSIVE subtree(uuid) AS (
        SELECT uuid FROM node_cache WHERE uuid = ?
        UNION ALL
        SELECT n.uuid FROM subtree s JOIN node_cache n ON n.parent_uuid = s.uuid
      )
      SELECT uuid FROM subtree ORDER BY uuid
    ''',
      [uuid],
    );
    return rows.map((r) => r['uuid'] as String).toList();
  }

  /// Restores the local node cache from a server-derived snapshot byte
  /// payload.
  ///
  /// The v2 snapshot is a serialized derived-state SQLite database (the
  /// store schema in `v2/packages/store/src/schema.ts`). This method opens it
  /// in a temp file and maps the v2 shape into the local cache: `node`
  /// (node_type/is_active/name/class_ids + hlc winner) into `node_cache`,
  /// `node_child_order.position` strings into the fractional `position`
  /// column, `class_member_set` and `property_value` rows into the local
  /// derived tables, `class_extends` into the edge/closure tables (closure
  /// rebuilt deterministically), and `class` / `property_schema` /
  /// `class_property` into their caches.
  Future<void> restoreFromSnapshot(Uint8List bytes, String workspaceId) async {
    final tempDir = await getTemporaryDirectory();
    final tempPath = join(
      tempDir.path,
      'notees_snapshot_${DateTime.now().millisecondsSinceEpoch}.db',
    );
    final tempFile = File(tempPath);
    await tempFile.writeAsBytes(bytes, flush: true);

    Database? snapshotDb;
    try {
      snapshotDb = await openDatabase(tempPath);
      final snapshot = await readSnapshot(snapshotDb, workspaceId);
      final db = await _database.database;
      await db.transaction((txn) async {
        await txn.delete('node_cache');
        await txn.delete('search_index');
        await txn.delete('class_cache');
        await txn.delete('property_schema');
        await txn.delete('class_property_edge');
        // The snapshot's content is newer than any locally tracked content
        // HLC; catch-up resumes from the snapshot cursor, so stale-op
        // detection restarts from scratch.
        await txn.delete('node_content_hlc');
        await txn.delete('class_member_set');
        await txn.delete('tag_member_set');
        await txn.delete('class_extends');
        await txn.delete('class_hierarchy');
        await txn.delete('property_value');
        await txn.delete('property_value_tombstone');
        await txn.delete('collection_member');
        final now = DateTime.now().millisecondsSinceEpoch;
        final nodeBatch = txn.batch();
        for (final node in snapshot.nodes) {
          nodeBatch.insert(
            'node_cache',
            _nodeToRow(node, now),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await nodeBatch.commit(noResult: true);
        await _indexNodesInTxn(
          txn,
          snapshot.nodes.where((n) => !n.isDeleted).toList(),
        );
        final memberBatch = txn.batch();
        for (final row in snapshot.classMemberRows) {
          memberBatch.insert('class_member_set', row);
        }
        await memberBatch.commit(noResult: true);
        final tagMemberBatch = txn.batch();
        for (final row in snapshot.tagMemberRows) {
          tagMemberBatch.insert('tag_member_set', row);
        }
        await tagMemberBatch.commit(noResult: true);
        final valueBatch = txn.batch();
        for (final row in snapshot.propertyValueRows) {
          valueBatch.insert('property_value', row);
        }
        await valueBatch.commit(noResult: true);
        final tombstoneBatch = txn.batch();
        for (final row in snapshot.propertyTombstoneRows) {
          tombstoneBatch.insert('property_value_tombstone', row);
        }
        await tombstoneBatch.commit(noResult: true);
        final collectionBatch = txn.batch();
        for (final row in snapshot.collectionMemberRows) {
          collectionBatch.insert('collection_member', row);
        }
        await collectionBatch.commit(noResult: true);
        final extendsBatch = txn.batch();
        for (final (classId, parentId) in snapshot.classExtendsEdges) {
          extendsBatch.insert('class_extends', {
            'class_id': classId,
            'parent_class_id': parentId,
          });
        }
        await extendsBatch.commit(noResult: true);
        final classBatch = txn.batch();
        for (final cls in snapshot.classes) {
          classBatch.insert(
            'class_cache',
            _classToRow(cls),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await classBatch.commit(noResult: true);
        final propertyBatch = txn.batch();
        for (final schema in snapshot.propertySchemas) {
          propertyBatch.insert(
            'property_schema',
            _propertySchemaToRow(schema),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await propertyBatch.commit(noResult: true);
        final edgeBatch = txn.batch();
        for (final edge in snapshot.classPropertyEdges) {
          edgeBatch.insert(
            'class_property_edge',
            _classPropertyEdgeToRow(edge),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await edgeBatch.commit(noResult: true);
      });
      // Closure is rebuilt after the class cache + edges land.
      await rebuildClassHierarchy();
    } finally {
      await snapshotDb?.close();
      try {
        await tempFile.delete();
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }

  /// Reads the v2 snapshot into a [SnapshotRestoreData] bundle.
  ///
  /// Exposed for testing; most callers should use [restoreFromSnapshot].
  Future<SnapshotRestoreData> readSnapshot(
    Database db,
    String workspaceId,
  ) async {
    final nodes = await readNodesFromSnapshotDatabase(db, workspaceId);
    final nodeIds = nodes.map((n) => n.uuid).toList();
    final placeholders = nodeIds.map((_) => '?').join(',');

    // OR-Set membership rows (keyed by the snapshot's node ids).
    final classMemberRows = <Map<String, dynamic>>[];
    final tagMemberRows = <Map<String, dynamic>>[];
    if (nodeIds.isNotEmpty) {
      final rows = await db.rawQuery(
        'SELECT node_id, class_id, present, hlc_physical, hlc_logical, actor_id '
        'FROM class_member_set WHERE node_id IN ($placeholders) ORDER BY node_id, class_id',
        nodeIds,
      );
      for (final row in rows) {
        classMemberRows.add({
          'node_uuid': row['node_id'],
          'class_id': row['class_id'],
          'present': row['present'],
          'hlc_physical': row['hlc_physical'] ?? 0,
          'hlc_logical': row['hlc_logical'] ?? 0,
          'actor_id': row['actor_id'],
        });
      }
    }

    // Pre-tags snapshots (store schema < v6) have no tag_member_set table;
    // the store's migrate() creates it on restore, so an absent table just
    // means "no tag rows".
    if (nodeIds.isNotEmpty && await _snapshotHasTable(db, 'tag_member_set')) {
      final tagRows = await db.rawQuery(
        'SELECT node_id, tag_id, present, hlc_physical, hlc_logical, actor_id '
        'FROM tag_member_set WHERE node_id IN ($placeholders) ORDER BY node_id, tag_id',
        nodeIds,
      );
      for (final row in tagRows) {
        tagMemberRows.add({
          'node_uuid': row['node_id'],
          'tag_id': row['tag_id'],
          'present': row['present'],
          'hlc_physical': row['hlc_physical'] ?? 0,
          'hlc_logical': row['hlc_logical'] ?? 0,
          'actor_id': row['actor_id'],
        });
      }
    }

    // Property rows with their LWW winners.
    final propertyValueRows = <Map<String, dynamic>>[];
    final propertyTombstoneRows = <Map<String, dynamic>>[];
    if (nodeIds.isNotEmpty) {
      final rows = await db.rawQuery(
        'SELECT node_id, property_schema_id, value, idx, metadata, hlc_physical, '
        'hlc_logical, actor_id FROM property_value '
        'WHERE node_id IN ($placeholders) ORDER BY node_id, property_schema_id, idx',
        nodeIds,
      );
      for (final row in rows) {
        propertyValueRows.add({
          'id': '${row['node_id']}:${row['property_schema_id']}:${row['idx']}',
          'node_uuid': row['node_id'],
          'property_schema_id': row['property_schema_id'],
          'value': row['value'],
          'idx': row['idx'] ?? 0,
          'metadata': row['metadata'],
          'hlc_physical': row['hlc_physical'] ?? 0,
          'hlc_logical': row['hlc_logical'] ?? 0,
          'actor_id': row['actor_id'],
        });
      }
      final tombRows = await db.rawQuery(
        'SELECT node_id, property_schema_id, idx, hlc_physical, hlc_logical, '
        'actor_id FROM property_value_tombstone WHERE node_id IN ($placeholders)',
        nodeIds,
      );
      for (final row in tombRows) {
        propertyTombstoneRows.add({
          'node_uuid': row['node_id'],
          'property_schema_id': row['property_schema_id'],
          'idx': row['idx'] ?? 0,
          'hlc_physical': row['hlc_physical'] ?? 0,
          'hlc_logical': row['hlc_logical'] ?? 0,
          'actor_id': row['actor_id'],
        });
      }
    }

    // Collection membership.
    final collectionMemberRows = <Map<String, dynamic>>[];
    if (nodeIds.isNotEmpty) {
      final collectionRows = await db.rawQuery(
        'SELECT collection_id, object_id, present, hlc_physical, hlc_logical, '
        'actor_id FROM collection_member WHERE object_id IN ($placeholders)',
        nodeIds,
      );
      for (final row in collectionRows) {
        collectionMemberRows.add({
          'collection_id': row['collection_id'],
          'object_id': row['object_id'],
          'present': row['present'],
          'hlc_physical': row['hlc_physical'] ?? 0,
          'hlc_logical': row['hlc_logical'] ?? 0,
          'actor_id': row['actor_id'],
        });
      }
    }

    // Direct extends edges.
    final extendsRows = await db.rawQuery(
      'SELECT class_id, parent_class_id FROM class_extends ORDER BY class_id, parent_class_id',
    );
    final classExtendsEdges = extendsRows
        .map((r) => (r['class_id'] as String, r['parent_class_id'] as String))
        .toList();

    return SnapshotRestoreData(
      nodes: nodes,
      classes: await _readClassesFromSnapshotDatabase(db, workspaceId),
      propertySchemas: await _readPropertySchemasFromSnapshotDatabase(
        db,
        workspaceId,
      ),
      classPropertyEdges: await _readClassPropertyEdgesFromSnapshotDatabase(
        db,
        workspaceId,
      ),
      classMemberRows: classMemberRows,
      tagMemberRows: tagMemberRows,
      propertyValueRows: propertyValueRows,
      propertyTombstoneRows: propertyTombstoneRows,
      collectionMemberRows: collectionMemberRows,
      classExtendsEdges: classExtendsEdges,
    );
  }

  /// True when [table] exists in a snapshot database (older-schema snapshot
  /// bytes may predate a table — CREATE TABLE IF NOT EXISTS in the store's
  /// migrate() never alters, so restore must tolerate absent tables).
  Future<bool> _snapshotHasTable(Database db, String table) async {
    final rows = await db.rawQuery(
      'SELECT name FROM sqlite_master WHERE type = ? AND name = ?',
      ['table', table],
    );
    return rows.isNotEmpty;
  }

  /// Reads [Node] objects from a v2 server-derived snapshot database.
  ///
  /// Exposed for testing; most callers should use [restoreFromSnapshot].
  /// Class rows (`node_type = 'class'`) are skipped: the local cache keeps
  /// classes in `class_cache`, which is the structural authority here.
  Future<List<Node>> readNodesFromSnapshotDatabase(
    Database db,
    String workspaceId,
  ) async {
    final nodeRows = await db.query(
      'node',
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
    );
    if (nodeRows.isEmpty) return const [];

    final nodeIds = nodeRows.map((r) => r['id'] as String).toList();
    final placeholders = nodeIds.map((_) => '?').join(',');

    // Property values for these nodes, projected per (node, schema): a
    // single idx row stays a scalar, multiple rows become a list.
    final propertiesByNode = <String, Map<String, dynamic>>{};
    final propRows = await db.rawQuery(
      'SELECT node_id, property_schema_id, value, idx FROM property_value '
      'WHERE node_id IN ($placeholders) ORDER BY property_schema_id, idx ASC',
      nodeIds,
    );
    final grouped = <String, Map<String, List<dynamic>>>{};
    for (final row in propRows) {
      final nodeId = row['node_id'] as String;
      final schemaId = row['property_schema_id'] as String;
      final rawValue = row['value'] as String;
      dynamic decoded;
      try {
        decoded = jsonDecode(rawValue);
      } catch (_) {
        decoded = rawValue;
      }
      ((grouped[nodeId] ??= {})[schemaId] ??= []).add(decoded);
    }
    grouped.forEach((nodeId, bySchema) {
      final projected = <String, dynamic>{};
      bySchema.forEach((schemaId, values) {
        projected[schemaId] = values.length == 1 ? values.single : values;
      });
      propertiesByNode[nodeId] = projected;
    });

    // Fractional child-order positions (kept as strings).
    final positionByNode = <String, String>{};
    final orderRows = await db.rawQuery(
      'SELECT child_id, position FROM node_child_order WHERE child_id IN ($placeholders)',
      nodeIds,
    );
    for (final row in orderRows) {
      final position = row['position'] as String?;
      if (position != null) {
        positionByNode[row['child_id'] as String] = position;
      }
    }

    return nodeRows.where((row) => row['node_type'] != 'class').map((row) {
      final uuid = row['id'] as String;
      final nodeType = row['node_type'] as String? ?? 'block';
      final classIdsJson = row['class_ids'] as String?;
      final classIds = (jsonDecode(classIdsJson ?? '[]') as List<dynamic>)
          .cast<String>();
      final tagIdsJson = row['tag_ids'] as String?;
      final tagIds = (jsonDecode(tagIdsJson ?? '[]') as List<dynamic>)
          .cast<String>();
      final classOrderJson = row['class_order'] as String?;
      final classOrder = (jsonDecode(classOrderJson ?? '[]') as List<dynamic>)
          .cast<String>();
      final contentJson = row['content'] as String?;
      final content = (jsonDecode(contentJson ?? '[]') as List<dynamic>)
          .cast<Map<String, dynamic>>();
      // The derived content column can hold the CRDT text wrapper
      // ([{type:'text', text:'<real AST JSON>'}]); unwrap before storing so
      // titles render as text instead of raw JSON.
      final name = jsonEncode(unwrapCrdtContentAst(content));

      return Node(
        id: 0,
        uuid: uuid,
        name: name,
        // Title-is-content: the display name derives from the content
        // excerpt (date labels formatted); there is no node `name` column
        // on v2 snapshots anymore.
        displayName: deriveDisplayName(name),
        icon: row['icon'] as String?,
        color: row['color'] as String?,
        parentUuid: row['parent_id'] as String?,
        sequence: double.tryParse(positionByNode[uuid] ?? '') ?? 0.0,
        position: positionByNode[uuid],
        isPage: nodeType == 'page',
        isTask: classIds.contains(SystemClassUuids.task),
        isDaily: classIds.contains(SystemClassUuids.day),
        isMonthly: classIds.contains(SystemClassUuids.month),
        isYearly: classIds.contains(SystemClassUuids.year),
        isTable: classIds.contains(SystemClassUuids.table),
        isAsset: classIds.contains(SystemClassUuids.asset),
        isComment: classIds.contains(SystemClassUuids.comment),
        isDeleted: false,
        isArchived: (row['is_active'] as int? ?? 1) == 0,
        classesUuid: classIds,
        tagsUuid: tagIds,
        classOrder: classOrder,
        properties: propertiesByNode[uuid] ?? const {},
        createDate: row['created_at'] as String?,
        writeDate: row['updated_at'] as String?,
        nodeType: nodeType,
        hlcPhysical: (row['hlc_physical'] as num?)?.toInt() ?? 0,
        hlcLogical: (row['hlc_logical'] as num?)?.toInt() ?? 0,
        actorId: row['actor_id'] as String?,
      );
    }).toList();
  }

  /// Reads class rows from a v2 server-derived snapshot database.
  Future<List<_ClassRow>> _readClassesFromSnapshotDatabase(
    Database db,
    String workspaceId,
  ) async {
    final rows = await db.query(
      'class',
      where: 'workspace_id = ? AND active = 1',
      whereArgs: [workspaceId],
      orderBy: 'name ASC',
    );
    final extendsByClass = <String, List<String>>{};
    final edgeRows = await db.rawQuery(
      'SELECT class_id, parent_class_id FROM class_extends ORDER BY class_id, parent_class_id',
    );
    for (final edge in edgeRows) {
      (extendsByClass[edge['class_id'] as String] ??= []).add(
        edge['parent_class_id'] as String,
      );
    }
    return rows.map((row) {
      final classId = row['id'] as String;
      return _ClassRow(
        uuid: classId,
        name: _normalizeClassName(row['name'] as String?),
        icon: row['icon'] as String?,
        color: row['color'] as String?,
        description: row['description'] as String?,
        extendsUuids: extendsByClass[classId] ?? const [],
        active: (row['active'] as int? ?? 1) == 1,
        createdAt: row['created_at'] as String?,
        updatedAt: row['updated_at'] as String?,
      );
    }).toList();
  }

  /// Reads property-schema rows from a v2 server-derived snapshot database.
  Future<List<PropertySchemaRow>> _readPropertySchemasFromSnapshotDatabase(
    Database db,
    String workspaceId,
  ) async {
    final rows = await db.query(
      'property_schema',
      where: 'workspace_id = ? AND active = 1',
      whereArgs: [workspaceId],
    );
    return rows.map((row) {
      List<String> classFilterUuids;
      List<Map<String, dynamic>> options;
      try {
        classFilterUuids =
            (jsonDecode(row['target_class_filter'] as String? ?? '[]')
                    as List<dynamic>)
                .cast<String>();
      } catch (_) {
        classFilterUuids = const [];
      }
      try {
        options =
            (jsonDecode(row['options'] as String? ?? '[]') as List<dynamic>)
                .cast<Map<String, dynamic>>();
      } catch (_) {
        options = const [];
      }
      return PropertySchemaRow(
        uuid: row['id'] as String,
        workspaceId: row['workspace_id'] as String,
        name: row['name'] as String,
        type: row['type'] as String? ?? 'text',
        multi: (row['multi'] as int? ?? 0) == 1,
        isSystem: false,
        scope: row['scope'] as String? ?? 'global',
        iconVisibility: null,
        validationRules: null,
        required: false,
        readonly: false,
        hideWhenEmpty: false,
        defaultValue: null,
        classFilterUuids: classFilterUuids,
        options: options,
        computed: null,
        active: (row['active'] as int? ?? 1) == 1,
        createdAt: row['created_at'] as String?,
        updatedAt: row['updated_at'] as String?,
      );
    }).toList();
  }

  /// Reads class-property binding rows from a v2 server-derived snapshot
  /// database (the v2 `class_property` table; empty by default in M1).
  Future<List<ClassPropertyEdgeRow>>
  _readClassPropertyEdgesFromSnapshotDatabase(
    Database db,
    String workspaceId,
  ) async {
    final rows = await db.rawQuery(
      'SELECT cp.class_id, cp.property_schema_id, cp.sequence, cp.default_value, '
      'cp.required, cp.readonly, cp.hide_when_empty '
      'FROM class_property cp '
      'JOIN class c ON c.id = cp.class_id '
      'WHERE c.workspace_id = ? AND c.active = 1',
      [workspaceId],
    );
    return rows.map((row) {
      dynamic defaultValue;
      try {
        final raw = row['default_value'] as String?;
        defaultValue = raw == null ? null : jsonDecode(raw);
      } catch (_) {
        defaultValue = row['default_value'];
      }
      return ClassPropertyEdgeRow(
        classUuid: row['class_id'] as String,
        propertyUuid: row['property_schema_id'] as String,
        sequence: row['sequence'] as int? ?? 0,
        defaultValue: defaultValue,
        hidden: false,
        required: row['required'] == null
            ? null
            : (row['required'] as int) == 1,
        readonly: row['readonly'] == null
            ? null
            : (row['readonly'] as int) == 1,
        hideWhenEmpty: row['hide_when_empty'] == null
            ? null
            : (row['hide_when_empty'] as int) == 1,
      );
    }).toList();
  }

  // === Local read queries used when the relay sync service is active ===

  /// Recently touched pages, newest first. Excludes journal date pages,
  /// which live in the dedicated Journals section.
  Future<List<Node>> getRecentPages({int limit = 10}) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where:
          'is_page = 1 AND is_deleted = 0 AND is_archived = 0 AND is_daily = 0 AND is_monthly = 0 AND is_yearly = 0',
      orderBy: "COALESCE(write_date, '') DESC, synced_at DESC",
      limit: limit,
    );
    return rows.map(_nodeFromRow).toList();
  }

  /// Top-level pages with no parent. Excludes journal date pages.
  Future<List<Node>> getRootPages() async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where:
          'is_page = 1 AND is_deleted = 0 AND is_archived = 0 AND parent_uuid IS NULL AND is_daily = 0 AND is_monthly = 0 AND is_yearly = 0',
      orderBy: "COALESCE(write_date, '') DESC",
    );
    return rows.map(_nodeFromRow).toList();
  }

  /// Full-text search over the local index.
  Future<List<Node>> searchNodes(String query, {int limit = 20}) async {
    final uuids = await searchLocal(query, limit: limit);
    return getByUuids(uuids);
  }

  /// Task nodes, optionally including completed ones.
  Future<List<Node>> getTasks({bool includeComplete = false}) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where: 'is_task = 1 AND is_deleted = 0 AND is_archived = 0',
      orderBy: "COALESCE(write_date, '') DESC",
    );
    final tasks = rows.map(_nodeFromRow).toList();
    if (includeComplete) return tasks;
    return tasks.where((n) => !_isClosedTask(n)).toList();
  }

  /// Classes from the dedicated `class_cache` table.
  /// Filters out system/structural classes (e.g. `page`, `class`) that are not
  /// meaningful as user-facing class categories.
  Future<List<Node>> getClasses() async {
    final db = await _database.database;
    final rows = await db.query(
      'class_cache',
      where: 'active = 1',
      orderBy: 'name ASC',
    );
    const hidden = <String>{SystemClassUuids.class_, SystemClassUuids.page};
    return rows
        .map(_classFromRow)
        .where((c) => !hidden.contains(c.uuid))
        .toList();
  }

  /// Number of active classes currently cached.
  Future<int> classCacheCount() async {
    final db = await _database.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM class_cache WHERE active = 1',
    );
    final count = result.firstOrNull?['count'];
    return (count is int ? count : int.tryParse(count.toString()) ?? 0);
  }

  /// Number of active property schemas currently cached.
  Future<int> propertySchemaCacheCount() async {
    final db = await _database.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM property_schema WHERE active = 1',
    );
    final count = result.firstOrNull?['count'];
    return (count is int ? count : int.tryParse(count.toString()) ?? 0);
  }

  /// A single class by UUID, or `null` if it is not cached.
  Future<Node?> getClassByUuid(String uuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'class_cache',
      where: 'uuid = ? AND active = 1',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _classFromRow(rows.first);
  }

  /// Creates or updates a class row in the local cache.
  Future<void> upsertClass({
    required String uuid,
    String? name,
    String? icon,
    String? color,
    String? description,
    List<String>? extendsUuids,
    bool active = true,
    String? createdAt,
    String? updatedAt,
  }) async {
    final db = await _database.database;
    await db.insert('class_cache', {
      'uuid': uuid,
      'name': _normalizeClassName(name),
      'icon': icon,
      'color': color,
      'description': description,
      'extends_uuid': jsonEncode(extendsUuids ?? const <String>[]),
      'active': active ? 1 : 0,
      'created_at': createdAt,
      'updated_at': updatedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // === v2 derived state (relay-v2 appliers; see AppDatabase._migrateV16) ===

  /// Row-level LWW metadata for [uuid]'s node row, if any.
  Future<NodeRowMeta?> getRowMeta(String uuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      columns: ['node_type', 'hlc_physical', 'hlc_logical', 'actor_id'],
      where: 'uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return NodeRowMeta(
      nodeType: row['node_type'] as String?,
      physical: (row['hlc_physical'] as num?)?.toInt() ?? 0,
      logical: (row['hlc_logical'] as num?)?.toInt() ?? 0,
      actor: row['actor_id'] as String? ?? '',
    );
  }

  /// True when [uuid] is a class (v2 classes are tree-external: they can
  /// never be a parent). Classes live in [class_cache]; a node row with
  /// node_type 'class' also counts.
  Future<bool> isClassNode(String uuid) async {
    final meta = await getRowMeta(uuid);
    if (meta?.nodeType == 'class') return true;
    return await getClassByUuid(uuid) != null;
  }

  // --- fractional child positions --------------------------------------

  /// The stored fractional position of [childUuid] under [parentUuid].
  Future<String?> childPosition(String parentUuid, String childUuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      columns: ['position'],
      where: 'parent_uuid = ? AND uuid = ?',
      whereArgs: [parentUuid, childUuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['position'] as String?;
  }

  /// Lexicographically-last child position under [parentUuid]
  /// (append-after target); optionally excluding [excludeChildUuid].
  Future<String?> lastChildPosition(
    String parentUuid, {
    String? excludeChildUuid,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      columns: ['position'],
      where: excludeChildUuid == null
          ? 'parent_uuid = ? AND position IS NOT NULL'
          : 'parent_uuid = ? AND position IS NOT NULL AND uuid != ?',
      whereArgs: excludeChildUuid == null
          ? [parentUuid]
          : [parentUuid, excludeChildUuid],
      orderBy: 'position DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['position'] as String?;
  }

  /// The first sibling position strictly after [afterPosition] under
  /// [parentUuid], excluding [excludeChildUuid] (the moving child).
  Future<String?> nextSiblingPosition(
    String parentUuid,
    String afterPosition, {
    String? excludeChildUuid,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      columns: ['position'],
      where: excludeChildUuid == null
          ? 'parent_uuid = ? AND position > ?'
          : 'parent_uuid = ? AND position > ? AND uuid != ?',
      whereArgs: excludeChildUuid == null
          ? [parentUuid, afterPosition]
          : [parentUuid, afterPosition, excludeChildUuid],
      orderBy: 'position ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['position'] as String?;
  }

  // --- OR-Set class membership ------------------------------------------

  /// Winner row of the (node, class) membership pair, if any.
  Future<LwwWinner?> classMemberWinner(String nodeUuid, String classId) async {
    final db = await _database.database;
    final rows = await db.query(
      'class_member_set',
      columns: ['hlc_physical', 'hlc_logical', 'actor_id'],
      where: 'node_uuid = ? AND class_id = ?',
      whereArgs: [nodeUuid, classId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      physical: (row['hlc_physical'] as num?)?.toInt() ?? 0,
      logical: (row['hlc_logical'] as num?)?.toInt() ?? 0,
      actor: row['actor_id'] as String? ?? '',
    );
  }

  /// Upserts a membership pair when [incoming] beats the stored winner
  /// (or no row exists).
  Future<void> upsertClassMember(
    String nodeUuid,
    String classId,
    bool present,
    LwwWinner incoming,
  ) async {
    final db = await _database.database;
    await db.insert('class_member_set', {
      'node_uuid': nodeUuid,
      'class_id': classId,
      'present': present ? 1 : 0,
      'hlc_physical': incoming.physical,
      'hlc_logical': incoming.logical,
      'actor_id': incoming.actor,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Recomputes [uuid]'s class list from the membership OR-Set's present
  /// rows and refreshes the class-derived flags. User order
  /// (node_cache.class_order, written by class.reorder) wins: ordered
  /// members first, then any unlisted present members sorted by id
  /// (recomputeClassIds in the v2 store appliers).
  Future<void> recomputeClassIds(String uuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'class_member_set',
      columns: ['class_id'],
      where: 'node_uuid = ? AND present = 1',
      whereArgs: [uuid],
      orderBy: 'class_id ASC',
    );
    final present = rows.map((r) => r['class_id'] as String).toList();
    final order = await classOrderOf(uuid);
    final presentSet = present.toSet();
    final orderedSet = order.toSet();
    final classIds = <String>[
      ...order.where(presentSet.contains),
      ...present.where((id) => !orderedSet.contains(id)),
    ];
    final node = await getByUuid(uuid);
    if (node == null) return;
    final flags = _deriveFlags(classIds);
    await upsert(
      Node(
        id: node.id,
        uuid: node.uuid,
        name: node.name,
        displayName: node.displayName,
        icon: node.icon,
        color: node.color,
        parentId: node.parentId,
        parentUuid: node.parentUuid,
        pageId: node.pageId,
        pageUuid: node.pageUuid,
        sequence: node.sequence,
        position: node.position,
        isPage: node.isPage,
        isTask: flags.isTask,
        isDaily: flags.isDaily,
        isMonthly: flags.isMonthly,
        isYearly: flags.isYearly,
        isTable: flags.isTable,
        isAsset: flags.isAsset,
        isComment: flags.isComment,
        isDeleted: node.isDeleted,
        isArchived: node.isArchived,
        isPrivate: node.isPrivate,
        classes: node.classes,
        classesUuid: classIds,
        tags: node.tags,
        tagsUuid: node.tagsUuid,
        properties: node.properties,
        children: node.children,
        createDate: node.createDate,
        writeDate: node.writeDate,
        extendsUuid: node.extendsUuid,
        title: node.title,
        nodeType: node.nodeType,
        classOrder: order,
        hlcPhysical: node.hlcPhysical,
        hlcLogical: node.hlcLogical,
        actorId: node.actorId,
      ),
    );
  }

  /// The stored user-defined class order for [uuid] (class.reorder,
  /// LWW-by-arrival); empty when never reordered.
  Future<List<String>> classOrderOf(String uuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      columns: ['class_order'],
      where: 'uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return const [];
    try {
      final parsed = jsonDecode(rows.first['class_order'] as String? ?? '[]');
      if (parsed is List) return parsed.cast<String>();
    } catch (_) {}
    return const [];
  }

  /// Writes [uuid]'s full ordered class-member list (class.reorder applier;
  /// display-only LWW-by-arrival, convergent per op order).
  Future<void> setClassOrder(String uuid, List<String> classIds) async {
    final db = await _database.database;
    await db.update(
      'node_cache',
      {'class_order': jsonEncode(classIds)},
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
  }

  // --- OR-Set tag membership (page-scoped page assignments) ---------------

  /// Winner row of the (node, tag) membership pair, if any.
  Future<LwwWinner?> tagMemberWinner(String nodeUuid, String tagId) async {
    final db = await _database.database;
    final rows = await db.query(
      'tag_member_set',
      columns: ['hlc_physical', 'hlc_logical', 'actor_id'],
      where: 'node_uuid = ? AND tag_id = ?',
      whereArgs: [nodeUuid, tagId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      physical: (row['hlc_physical'] as num?)?.toInt() ?? 0,
      logical: (row['hlc_logical'] as num?)?.toInt() ?? 0,
      actor: row['actor_id'] as String? ?? '',
    );
  }

  /// Upserts a tag membership pair (the applier gates on the winner first).
  Future<void> upsertTagMember(
    String nodeUuid,
    String tagId,
    bool present,
    LwwWinner incoming,
  ) async {
    final db = await _database.database;
    await db.insert('tag_member_set', {
      'node_uuid': nodeUuid,
      'tag_id': tagId,
      'present': present ? 1 : 0,
      'hlc_physical': incoming.physical,
      'hlc_logical': incoming.logical,
      'actor_id': incoming.actor,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Recomputes [uuid]'s tag list from the tag OR-Set's present rows
  /// (sorted by id — recomputeTagIds in the v2 store appliers).
  Future<void> recomputeTagIds(String uuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'tag_member_set',
      columns: ['tag_id'],
      where: 'node_uuid = ? AND present = 1',
      whereArgs: [uuid],
      orderBy: 'tag_id ASC',
    );
    final tagIds = rows.map((r) => r['tag_id'] as String).toList();
    final node = await getByUuid(uuid);
    if (node == null) return;
    await upsert(
      Node(
        id: node.id,
        uuid: node.uuid,
        name: node.name,
        displayName: node.displayName,
        icon: node.icon,
        color: node.color,
        parentId: node.parentId,
        parentUuid: node.parentUuid,
        pageId: node.pageId,
        pageUuid: node.pageUuid,
        sequence: node.sequence,
        position: node.position,
        isPage: node.isPage,
        isTask: node.isTask,
        isDaily: node.isDaily,
        isMonthly: node.isMonthly,
        isYearly: node.isYearly,
        isTable: node.isTable,
        isAsset: node.isAsset,
        isComment: node.isComment,
        isDeleted: node.isDeleted,
        isArchived: node.isArchived,
        isPrivate: node.isPrivate,
        classes: node.classes,
        classesUuid: node.classesUuid,
        tags: node.tags,
        tagsUuid: tagIds,
        properties: node.properties,
        children: node.children,
        createDate: node.createDate,
        writeDate: node.writeDate,
        extendsUuid: node.extendsUuid,
        title: node.title,
        nodeType: node.nodeType,
        classOrder: node.classOrder,
        hlcPhysical: node.hlcPhysical,
        hlcLogical: node.hlcLogical,
        actorId: node.actorId,
      ),
    );
  }

  // --- class extends + hierarchy closure --------------------------------

  /// All direct extends edges (class_id, parent_class_id), sorted.
  Future<List<(String, String)>> classExtendsEdges() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT class_id, parent_class_id FROM class_extends '
      'ORDER BY class_id, parent_class_id',
    );
    return rows
        .map((r) => (r['class_id'] as String, r['parent_class_id'] as String))
        .toList();
  }

  /// Replace semantics: [parentClassIds] IS the class's full parent set.
  Future<void> replaceClassExtends(
    String classId,
    List<String> parentClassIds,
  ) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete(
        'class_extends',
        where: 'class_id = ?',
        whereArgs: [classId],
      );
      final batch = txn.batch();
      for (final parentId in parentClassIds.toSet()) {
        batch.insert('class_extends', {
          'class_id': classId,
          'parent_class_id': parentId,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  /// True when [ancestorId] is in [classId]'s pre-write closure.
  Future<bool> hierarchyContains(String classId, String ancestorId) async {
    final db = await _database.database;
    final rows = await db.query(
      'class_hierarchy',
      columns: ['ancestor_id'],
      where: 'class_id = ? AND ancestor_id = ?',
      whereArgs: [classId, ancestorId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Deterministic full rebuild of the class_hierarchy closure from the
  /// class_extends edge set (port of the v2 store's rebuildClassHierarchy:
  /// rows inserted per class in sorted id order with sorted ancestor
  /// order, so wipe -> replay converges to identical state).
  Future<void> rebuildClassHierarchy() async {
    final db = await _database.database;
    final classes = await db.rawQuery(
      'SELECT uuid FROM class_cache WHERE active = 1 ORDER BY uuid',
    );
    final edges = await classExtendsEdges();
    final parentsById = <String, List<String>>{};
    for (final (classId, parentId) in edges) {
      (parentsById[classId] ??= []).add(parentId);
    }
    await db.transaction((txn) async {
      await txn.delete('class_hierarchy');
      final batch = txn.batch();
      for (final row in classes) {
        final classId = row['uuid'] as String;
        final ancestors = <String>{};
        final visited = {classId};
        final queue = [...(parentsById[classId] ?? const <String>[])];
        while (queue.isNotEmpty) {
          final cursor = queue.removeAt(0);
          if (visited.contains(cursor)) continue;
          visited.add(cursor);
          ancestors.add(cursor);
          queue.addAll(parentsById[cursor] ?? const <String>[]);
        }
        batch.insert('class_hierarchy', {
          'class_id': classId,
          'ancestor_id': classId,
        });
        for (final ancestorId in ancestors.toList()..sort()) {
          batch.insert('class_hierarchy', {
            'class_id': classId,
            'ancestor_id': ancestorId,
          });
        }
      }
      await batch.commit(noResult: true);
    });
  }

  // --- multi-value properties (LWW + tombstones) -------------------------

  /// Winner of the live property slot, if any.
  Future<LwwWinner?> propertyValueWinner(
    String nodeUuid,
    String schemaId,
    int idx,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'property_value',
      columns: ['hlc_physical', 'hlc_logical', 'actor_id'],
      where: 'node_uuid = ? AND property_schema_id = ? AND idx = ?',
      whereArgs: [nodeUuid, schemaId, idx],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      physical: (row['hlc_physical'] as num?)?.toInt() ?? 0,
      logical: (row['hlc_logical'] as num?)?.toInt() ?? 0,
      actor: row['actor_id'] as String? ?? '',
    );
  }

  /// Winner of the slot's tombstone, if any.
  Future<LwwWinner?> propertyTombstoneWinner(
    String nodeUuid,
    String schemaId,
    int idx,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'property_value_tombstone',
      columns: ['hlc_physical', 'hlc_logical', 'actor_id'],
      where: 'node_uuid = ? AND property_schema_id = ? AND idx = ?',
      whereArgs: [nodeUuid, schemaId, idx],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      physical: (row['hlc_physical'] as num?)?.toInt() ?? 0,
      logical: (row['hlc_logical'] as num?)?.toInt() ?? 0,
      actor: row['actor_id'] as String? ?? '',
    );
  }

  Future<void> upsertPropertyValue(
    String nodeUuid,
    String schemaId,
    int idx,
    String valueJson,
    String? metadataJson,
    LwwWinner incoming,
  ) async {
    final db = await _database.database;
    await db.insert('property_value', {
      'id': '$nodeUuid:$schemaId:$idx',
      'node_uuid': nodeUuid,
      'property_schema_id': schemaId,
      'value': valueJson,
      'idx': idx,
      'metadata': metadataJson,
      'hlc_physical': incoming.physical,
      'hlc_logical': incoming.logical,
      'actor_id': incoming.actor,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deletePropertyValue(
    String nodeUuid,
    String schemaId,
    int idx,
  ) async {
    final db = await _database.database;
    await db.delete(
      'property_value',
      where: 'node_uuid = ? AND property_schema_id = ? AND idx = ?',
      whereArgs: [nodeUuid, schemaId, idx],
    );
  }

  /// Upserts the slot tombstone when [incoming] beats the stored winner.
  Future<void> upsertPropertyTombstone(
    String nodeUuid,
    String schemaId,
    int idx,
    LwwWinner incoming,
  ) async {
    final db = await _database.database;
    await db.insert('property_value_tombstone', {
      'node_uuid': nodeUuid,
      'property_schema_id': schemaId,
      'idx': idx,
      'hlc_physical': incoming.physical,
      'hlc_logical': incoming.logical,
      'actor_id': incoming.actor,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// All live property rows for [nodeUuid], ordered by schema then idx.
  Future<List<PropertyValueRow>> propertyValuesFor(String nodeUuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'property_value',
      where: 'node_uuid = ?',
      whereArgs: [nodeUuid],
      orderBy: 'property_schema_id ASC, idx ASC',
    );
    return rows.map((row) {
      dynamic decoded;
      try {
        decoded = jsonDecode(row['value'] as String);
      } catch (_) {
        decoded = row['value'];
      }
      dynamic metadata;
      final rawMetadata = row['metadata'] as String?;
      if (rawMetadata != null) {
        try {
          metadata = jsonDecode(rawMetadata);
        } catch (_) {
          metadata = rawMetadata;
        }
      }
      return PropertyValueRow(
        schemaId: row['property_schema_id'] as String,
        idx: (row['idx'] as num?)?.toInt() ?? 0,
        value: decoded,
        metadata: metadata,
      );
    }).toList();
  }

  /// Rebuilds the node's payload `properties` projection from the
  /// property_value table (single row -> scalar, multiple rows -> list).
  Future<void> projectNodeProperties(String nodeUuid) async {
    final node = await getByUuid(nodeUuid);
    if (node == null) return;
    final rows = await propertyValuesFor(nodeUuid);
    final bySchema = <String, List<dynamic>>{};
    for (final row in rows) {
      (bySchema[row.schemaId] ??= []).add(row.value);
    }
    final projected = <String, dynamic>{};
    bySchema.forEach((schemaId, values) {
      projected[schemaId] = values.length == 1 ? values.single : values;
    });
    await upsert(
      Node(
        id: node.id,
        uuid: node.uuid,
        name: node.name,
        displayName: node.displayName,
        icon: node.icon,
        color: node.color,
        parentId: node.parentId,
        parentUuid: node.parentUuid,
        pageId: node.pageId,
        pageUuid: node.pageUuid,
        sequence: node.sequence,
        position: node.position,
        isPage: node.isPage,
        isTask: node.isTask,
        isDaily: node.isDaily,
        isMonthly: node.isMonthly,
        isYearly: node.isYearly,
        isTable: node.isTable,
        isAsset: node.isAsset,
        isComment: node.isComment,
        isDeleted: node.isDeleted,
        isArchived: node.isArchived,
        isPrivate: node.isPrivate,
        classes: node.classes,
        classesUuid: node.classesUuid,
        tags: node.tags,
        tagsUuid: node.tagsUuid,
        properties: projected,
        children: node.children,
        createDate: node.createDate,
        writeDate: node.writeDate,
        extendsUuid: node.extendsUuid,
        title: node.title,
        nodeType: node.nodeType,
        classOrder: node.classOrder,
        hlcPhysical: node.hlcPhysical,
        hlcLogical: node.hlcLogical,
        actorId: node.actorId,
      ),
    );
  }

  // --- collection membership (OR-Set) -----------------------------------

  Future<LwwWinner?> collectionMemberWinner(
    String collectionId,
    String objectId,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'collection_member',
      columns: ['hlc_physical', 'hlc_logical', 'actor_id'],
      where: 'collection_id = ? AND object_id = ?',
      whereArgs: [collectionId, objectId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      physical: (row['hlc_physical'] as num?)?.toInt() ?? 0,
      logical: (row['hlc_logical'] as num?)?.toInt() ?? 0,
      actor: row['actor_id'] as String? ?? '',
    );
  }

  Future<void> upsertCollectionMember(
    String collectionId,
    String objectId,
    bool present,
    LwwWinner incoming,
  ) async {
    final db = await _database.database;
    await db.insert('collection_member', {
      'collection_id': collectionId,
      'object_id': objectId,
      'present': present ? 1 : 0,
      'hlc_physical': incoming.physical,
      'hlc_logical': incoming.logical,
      'actor_id': incoming.actor,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Marks a class as deleted/inactive.
  Future<void> deleteClass(String uuid) async {
    final db = await _database.database;
    await db.update(
      'class_cache',
      {'active': 0},
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// Updates the extends list for a class.
  Future<void> setClassExtends(String uuid, List<String> extendsUuids) async {
    final db = await _database.database;
    await db.update(
      'class_cache',
      {'extends_uuid': jsonEncode(extendsUuids)},
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// Direct children of [parentUuid] in v2 fractional position order.
  ///
  /// Rows carrying a lexicographic `position` sort before legacy rows, which
  /// keep falling back to the numeric `sequence`.
  Future<List<Node>> getChildren(String parentUuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where: 'parent_uuid = ? AND is_deleted = 0 AND is_archived = 0',
      whereArgs: [parentUuid],
      orderBy:
          'CASE WHEN position IS NULL THEN 1 ELSE 0 END, position ASC, '
          'sequence ASC, synced_at DESC',
    );
    return rows.map(_nodeFromRow).toList();
  }

  /// Archived nodes (the restorable "trash" set; deletes are hard deletes).
  Future<List<Node>> getArchived() async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where: 'is_archived = 1',
      orderBy: 'synced_at DESC',
    );
    return rows.map(_nodeFromRow).toList();
  }

  /// Best-effort page content: the page node plus its cached children.
  Future<PageContent> getPageContent(String uuid) async {
    final node = await getByUuid(uuid);
    if (node == null) {
      throw StateError('Node not found in local cache: $uuid');
    }
    final children = await getChildren(uuid);
    final pageNode = Node(
      id: node.id,
      uuid: node.uuid,
      name: node.name,
      displayName: node.displayName,
      icon: node.icon,
      color: node.color,
      parentId: node.parentId,
      parentUuid: node.parentUuid,
      pageId: node.pageId,
      pageUuid: node.pageUuid,
      sequence: node.sequence,
      isPage: node.isPage,
      isTask: node.isTask,
      isDaily: node.isDaily,
      isMonthly: node.isMonthly,
      isYearly: node.isYearly,
      isTable: node.isTable,
      isAsset: node.isAsset,
      isComment: node.isComment,
      isDeleted: node.isDeleted,
      isPrivate: node.isPrivate,
      classes: node.classes,
      classesUuid: node.classesUuid,
      tags: node.tags,
      tagsUuid: node.tagsUuid,
      properties: node.properties,
      children: children,
      createDate: node.createDate,
      writeDate: node.writeDate,
      classOrder: node.classOrder,
    );
    return PageContent(node: pageNode, linkedReferences: const []);
  }

  /// Live properties of [uuid], read from the derived `property_value` table
  /// (the v2 LWW authority). Multiple idx rows under one schema surface as a
  /// list; a single row stays a scalar. Legacy rows that predate the table
  /// fall back to the payload projection.
  Future<List<NodePropertyValue>> getNodeProperties(String uuid) async {
    final rows = await propertyValuesFor(uuid);
    if (rows.isNotEmpty) {
      final bySchema = <String, List<dynamic>>{};
      for (final row in rows) {
        (bySchema[row.schemaId] ??= []).add(row.value);
      }
      final entries = <NodePropertyValue>[];
      for (final entry in bySchema.entries) {
        final schema = await getPropertySchema(entry.key);
        entries.add(
          NodePropertyValue(
            property:
                schema ??
                _knownPropertySchemas[entry.key] ??
                _genericProperty(entry.key),
            values: entry.value,
          ),
        );
      }
      return entries;
    }
    final node = await getByUuid(uuid);
    if (node == null) return const [];
    final entries = <NodePropertyValue>[];
    for (final entry in node.properties.entries) {
      final schema = await getPropertySchema(entry.key);
      entries.add(
        NodePropertyValue(
          property:
              schema ??
              _knownPropertySchemas[entry.key] ??
              _genericProperty(entry.key),
          values: [entry.value],
        ),
      );
    }
    return entries;
  }

  /// Best-effort available properties for a node.
  ///
  /// Returns property schemas attached to any of the node's classes, ordered by
  /// the class-property-edge sequence. Task nodes also get the hard-coded task
  /// status/deadline/scheduled/priority schemas as a fallback.
  Future<List<Property>> getAvailableProperties(String uuid) async {
    final node = await getByUuid(uuid);
    if (node == null) return const [];
    final classUuids = node.classesUuid;
    final fromClasses = classUuids.isEmpty
        ? const <Property>[]
        : await getPropertySchemasForClasses(classUuids);
    if (!node.isTask) return fromClasses;

    final existing = fromClasses.map((p) => p.uuid).toSet();
    return [
      ...fromClasses,
      ..._taskProperties.where((p) => !existing.contains(p.uuid)),
    ];
  }

  /// Property schemas attached to [classUuids] via class-property edges.
  Future<List<Property>> getPropertySchemasForClasses(
    List<String> classUuids,
  ) async {
    if (classUuids.isEmpty) return const [];
    final db = await _database.database;
    final placeholders = classUuids.map((_) => '?').join(',');
    final rows = await db.rawQuery(
      'SELECT ps.* FROM property_schema ps '
      'INNER JOIN class_property_edge cpe ON cpe.property_uuid = ps.uuid '
      'WHERE cpe.class_uuid IN ($placeholders) AND ps.active = 1 AND cpe.hidden = 0 '
      'ORDER BY cpe.sequence ASC, ps.name ASC',
      classUuids,
    );
    return rows.map(_propertySchemaFromRow).toList();
  }

  /// A single cached property schema by UUID.
  Future<Property?> getPropertySchema(String uuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'property_schema',
      where: 'uuid = ? AND active = 1',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _propertySchemaFromRow(rows.first);
  }

  /// A single cached property schema row by UUID, including the fields the
  /// [Property] model does not expose (`required`, `defaultValue`, `computed`).
  Future<PropertySchemaRow?> getPropertySchemaRow(String uuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'property_schema',
      where: 'uuid = ? AND active = 1',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _propertySchemaRowFromDb(rows.first);
  }

  /// Class-level property metadata for [classUuid].
  Future<List<ClassProperty>> getClassProperties(String classUuid) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT c.name AS class_name, c.uuid AS class_uuid, ps.uuid AS property_uuid, '
      'ps.name AS property_name, ps.type AS property_type, cpe.sequence, '
      'cpe.default_value, cpe.hidden, cpe.required, cpe.readonly '
      'FROM class_property_edge cpe '
      'INNER JOIN property_schema ps ON ps.uuid = cpe.property_uuid '
      'INNER JOIN class_cache c ON c.uuid = cpe.class_uuid '
      'WHERE cpe.class_uuid = ? AND ps.active = 1 '
      'ORDER BY cpe.sequence ASC',
      [classUuid],
    );
    return rows.map((row) {
      dynamic defaultValue;
      try {
        final raw = row['default_value'] as String?;
        defaultValue = raw == null ? null : jsonDecode(raw);
      } catch (_) {
        defaultValue = row['default_value'];
      }
      return ClassProperty(
        classNodeUuid: row['class_uuid'] as String,
        classNodeName: row['class_name'] as String? ?? '',
        propertyUuid: row['property_uuid'] as String,
        propertyName: row['property_name'] as String? ?? '',
        propertyType: row['property_type'] as String? ?? 'text',
        sequence: row['sequence'] as int? ?? 0,
        defaultValue: defaultValue,
        hidden: (row['hidden'] as int? ?? 0) == 1,
        required: (row['required'] as int? ?? 0) == 1,
      );
    }).toList();
  }

  /// Walks parent_uuid chain from [uuid] up to a root.
  Future<List<String>> getBreadcrumbs(String uuid) async {
    final result = <String>[];
    var current = uuid;
    for (var i = 0; i < 20; i++) {
      final node = await getByUuid(current);
      if (node == null) break;
      result.add(node.uuid);
      if (node.parentUuid == null) break;
      current = node.parentUuid!;
    }
    return result.reversed.toList();
  }

  /// Backlinks are not rebuilt locally yet.
  Future<LinkedReferencesResult> getLinkedReferences(String uuid) async {
    return const LinkedReferencesResult(references: [], totalCount: 0);
  }

  /// Structured local search with filters.
  Future<List<Node>> searchWithFilters(SearchFilters filters) async {
    final db = await _database.database;

    // Start with text matches when a query is present.
    List<String> candidateUuids;
    if (filters.query.trim().isNotEmpty) {
      candidateUuids = await searchLocal(filters.query, limit: 1000);
      if (candidateUuids.isEmpty) return const [];
    } else {
      final rows = await db.query(
        'node_cache',
        columns: ['uuid'],
        where: 'is_deleted = 0 AND is_archived = 0',
      );
      candidateUuids = rows.map((r) => r['uuid'] as String).toList();
    }

    final nodes = await getByUuids(candidateUuids);
    final filtered = nodes.where((n) => _matchesFilters(n, filters)).toList();
    _sortFiltered(filtered, filters);

    final start = (filters.page - 1) * filters.limit;
    if (start >= filtered.length) return const [];
    return filtered.sublist(
      start,
      (start + filters.limit).clamp(0, filtered.length),
    );
  }

  // === Local search index ===

  // === Favorites ===

  // Favorites are keyed per actor, matching the server-side
  // `user_favorite(actor_id, node_id, workspace_id)` keying. A null [actorId]
  // means "no authenticated user is wired into sync yet" and reads/writes
  // fall back to workspace-scoped behavior (single-user installs).

  /// Favorite nodes for [workspaceId] in order.
  Future<List<Node>> getFavorites(
    String workspaceId, {
    int limit = 50,
    String? actorId,
  }) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      '''
      SELECT nc.payload
      FROM user_favorite uf
      INNER JOIN node_cache nc ON nc.uuid = uf.node_uuid
      WHERE uf.workspace_id = ? ${actorId != null ? 'AND uf.actor_id = ?' : ''}
        AND nc.is_deleted = 0 AND nc.is_archived = 0
      ORDER BY uf.position ASC, uf.updated_at DESC
      LIMIT ?
    ''',
      [workspaceId, ?actorId, limit],
    );
    return rows.map(_nodeFromRow).toList();
  }

  /// UUIDs of favorite nodes for [workspaceId] in order.
  Future<List<String>> getFavoriteUuids(
    String workspaceId, {
    String? actorId,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'user_favorite',
      columns: ['node_uuid'],
      where: actorId != null
          ? 'workspace_id = ? AND actor_id = ?'
          : 'workspace_id = ?',
      whereArgs: [workspaceId, ?actorId],
      orderBy: 'position ASC, updated_at DESC',
    );
    return rows.map((r) => r['node_uuid'] as String).toList();
  }

  Future<void> addFavorite(
    String workspaceId,
    String nodeUuid, {
    String? actorId,
  }) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      '''
      SELECT COALESCE(MAX(position), -1) AS pos
      FROM user_favorite
      WHERE workspace_id = ? AND actor_id = ?
    ''',
      [workspaceId, actorId ?? ''],
    );
    final pos = (rows.first['pos'] as int? ?? -1) + 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('user_favorite', {
      'workspace_id': workspaceId,
      'actor_id': actorId ?? '',
      'node_uuid': nodeUuid,
      'position': pos,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeFavorite(
    String workspaceId,
    String nodeUuid, {
    String? actorId,
  }) async {
    final db = await _database.database;
    await db.delete(
      'user_favorite',
      where: actorId != null
          ? 'workspace_id = ? AND actor_id = ? AND node_uuid = ?'
          : 'workspace_id = ? AND node_uuid = ?',
      whereArgs: [workspaceId, ?actorId, nodeUuid],
    );
  }

  Future<void> reorderFavorites(
    String workspaceId,
    List<String> nodeUuids, {
    String? actorId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final actor = actorId ?? '';
    await db.transaction((txn) async {
      if (nodeUuids.isEmpty) {
        // Matches the server applier: an empty list clears the actor's
        // favorites.
        await txn.delete(
          'user_favorite',
          where: 'workspace_id = ? AND actor_id = ?',
          whereArgs: [workspaceId, actor],
        );
        return;
      }
      await txn.delete(
        'user_favorite',
        where:
            'workspace_id = ? AND actor_id = ? AND node_uuid NOT IN (${nodeUuids.map((_) => '?').join(',')})',
        whereArgs: [workspaceId, actor, ...nodeUuids],
      );
      for (var i = 0; i < nodeUuids.length; i++) {
        await txn.insert('user_favorite', {
          'workspace_id': workspaceId,
          'actor_id': actor,
          'node_uuid': nodeUuids[i],
          'position': i,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Applies a `user.favorite.add` operation to the local derived state.
  Future<void> applyFavoriteAdd(
    String workspaceId,
    String actorId,
    String nodeUuid,
  ) async {
    await addFavorite(workspaceId, nodeUuid, actorId: actorId);
  }

  /// Applies a `user.favorite.remove` operation to the local derived state.
  Future<void> applyFavoriteRemove(
    String workspaceId,
    String actorId,
    String nodeUuid,
  ) async {
    await removeFavorite(workspaceId, nodeUuid, actorId: actorId);
  }

  /// Applies a `user.favorite.reorder` operation to the local derived state.
  Future<void> applyFavoriteReorder(
    String workspaceId,
    String actorId,
    List<String> nodeUuids,
  ) async {
    await reorderFavorites(workspaceId, nodeUuids, actorId: actorId);
  }

  // === Task completions ===

  /// Records a task completion in the local derived state.
  Future<void> recordTaskCompletion(
    String nodeUuid,
    String completionId, {
    String? completedAt,
    String? scheduledDate,
    String? deadlineDate,
    String? status,
  }) async {
    final db = await _database.database;
    await db.insert('task_completion', {
      'completion_id': completionId,
      'node_uuid': nodeUuid,
      'completed_at': completedAt,
      'scheduled_date': scheduledDate,
      'deadline_date': deadlineDate,
      'status': status,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Deletes a task completion from the local derived state.
  Future<void> deleteTaskCompletion(
    String nodeUuid,
    String completionId,
  ) async {
    final db = await _database.database;
    await db.delete(
      'task_completion',
      where: 'completion_id = ?',
      whereArgs: [completionId],
    );
  }

  /// Returns the most recent completion id for [nodeUuid], or null if none.
  Future<String?> getMostRecentTaskCompletionId(String nodeUuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'task_completion',
      columns: ['completion_id'],
      where: 'node_uuid = ?',
      whereArgs: [nodeUuid],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['completion_id'] as String?;
  }

  /// Number of completions recorded for [nodeUuid]; used to honor recurrence
  /// `end_after_count` when expanding occurrence dates.
  Future<int> getTaskCompletionCount(String nodeUuid) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) as count FROM task_completion WHERE node_uuid = ?',
      [nodeUuid],
    );
    return rows.first['count'] as int? ?? 0;
  }

  // === Task recurrence ===

  /// Applies a `task.setRecurrence` operation to the local derived state.
  ///
  /// Mirrors the server applier: one rule per node, replaced on each set. The
  /// rule JSON is stored verbatim so the reminders path can expand it when
  /// scheduling due-date notifications.
  Future<void> applyTaskSetRecurrence(
    String nodeUuid, {
    String? recurrenceId,
    Map<String, dynamic>? rule,
    String? actorId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      await txn.delete(
        'task_recurrence',
        where: 'node_uuid = ?',
        whereArgs: [nodeUuid],
      );
      await txn.insert('task_recurrence', {
        'recurrence_id': (recurrenceId == null || recurrenceId.isEmpty)
            ? const Uuid().v7()
            : recurrenceId,
        'node_uuid': nodeUuid,
        'rule': jsonEncode(rule ?? const <String, dynamic>{}),
        'actor_id': actorId,
        'created_at': now,
        'updated_at': now,
      });
    });
  }

  /// Applies a `task.deleteRecurrence` operation to the local derived state.
  Future<void> applyTaskDeleteRecurrence(
    String nodeUuid, {
    String? recurrenceId,
  }) async {
    final db = await _database.database;
    if (recurrenceId != null && recurrenceId.isNotEmpty) {
      await db.delete(
        'task_recurrence',
        where: 'node_uuid = ? AND recurrence_id = ?',
        whereArgs: [nodeUuid, recurrenceId],
      );
    } else {
      // The server deletes by node id only.
      await db.delete(
        'task_recurrence',
        where: 'node_uuid = ?',
        whereArgs: [nodeUuid],
      );
    }
  }

  /// The recurrence rule currently stored for [nodeUuid], if any.
  Future<Map<String, dynamic>?> getTaskRecurrence(String nodeUuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'task_recurrence',
      columns: ['rule'],
      where: 'node_uuid = ?',
      whereArgs: [nodeUuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      return jsonDecode(rows.first['rule'] as String) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // === User shares ===

  /// Applies a `share.user.grant` operation to the local derived state.
  ///
  /// Mirrors the server applier: one share per (node, target user), replaced
  /// on each grant.
  Future<void> applyShareUserGrant(
    String workspaceId, {
    required String nodeUuid,
    required String targetUserId,
    String? shareId,
    int permissionBits = 0,
    String role = '',
    String? createdBy,
    String? createdAt,
  }) async {
    final db = await _database.database;
    await db.insert('node_user_share', {
      'workspace_id': workspaceId,
      'node_uuid': nodeUuid,
      'target_user_id': targetUserId,
      'role': role,
      'permission_bits': permissionBits,
      'share_id': (shareId == null || shareId.isEmpty)
          ? const Uuid().v7()
          : shareId,
      'created_by': createdBy,
      'created_at': createdAt ?? DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Applies a `share.user.revoke` operation to the local derived state.
  ///
  /// Mirrors the server applier: delete by share id, with a fallback delete
  /// by node/user pair for callers that emit those instead.
  Future<void> applyShareUserRevoke(
    String workspaceId, {
    String? shareId,
    String? nodeUuid,
    String? targetUserId,
  }) async {
    final db = await _database.database;
    if (shareId != null && shareId.isNotEmpty) {
      await db.delete(
        'node_user_share',
        where: 'workspace_id = ? AND share_id = ?',
        whereArgs: [workspaceId, shareId],
      );
    }
    if (nodeUuid != null && targetUserId != null) {
      await db.delete(
        'node_user_share',
        where: 'workspace_id = ? AND node_uuid = ? AND target_user_id = ?',
        whereArgs: [workspaceId, nodeUuid, targetUserId],
      );
    }
  }

  /// Nodes shared with [userId] in [workspaceId], joined against the node
  /// cache; deleted and archived nodes are excluded.
  Future<List<Node>> getSharedWithMe(
    String workspaceId,
    String userId, {
    int limit = 50,
  }) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      '''
      SELECT nc.payload
      FROM node_user_share nus
      INNER JOIN node_cache nc ON nc.uuid = nus.node_uuid
      WHERE nus.workspace_id = ? AND nus.target_user_id = ?
        AND nc.is_deleted = 0 AND nc.is_archived = 0
      ORDER BY nus.created_at DESC
      LIMIT ?
    ''',
      [workspaceId, userId, limit],
    );
    return rows.map(_nodeFromRow).toList();
  }

  // === Client-produced v2 snapshots (restoreFromSnapshot's inverse) =========

  /// Serializes the local derived state into a v2 derived-state snapshot
  /// (the store schema in `v2/packages/store/src/schema.ts`) — the inverse
  /// of [restoreFromSnapshot], used by the explicit snapshot-upload trigger.
  ///
  /// The bytes are a real SQLite database file: a temp-file DB is populated
  /// from the local tables (nodes incl. title/position/node_type/hlc winner,
  /// fractional child order, classes + extends closure, OR-Set membership,
  /// property rows with their LWW winners, collection membership, edges) and
  /// read back as bytes. Search/FTS and stats tables are intentionally
  /// skipped: the server rebuilds them on restore.
  Future<Uint8List?> buildV2SnapshotBytes(String workspaceId) async {
    final tempDir = await getTemporaryDirectory();
    final tempPath = join(
      tempDir.path,
      'notees_snapshot_build_${DateTime.now().millisecondsSinceEpoch}.db',
    );
    final tempFile = File(tempPath);

    Database? buildDb;
    try {
      buildDb = await snapshotDbOpener(tempPath);
      await _createV2SnapshotSchema(buildDb);
      await _populateV2Snapshot(buildDb, workspaceId);
      // Read back the raw file bytes (flush by closing first).
      await buildDb.close();
      buildDb = null;
      return await tempFile.readAsBytes();
    } catch (error) {
      // A failed build must never crash the caller (the upload is
      // best-effort); surface the reason for debugging.
      debugPrint('buildV2SnapshotBytes failed: $error');
      return null;
    } finally {
      await buildDb?.close();
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }

  Future<void> _createV2SnapshotSchema(Database db) async {
    await db.execute('''
      CREATE TABLE node (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        node_type TEXT NOT NULL DEFAULT 'block',
        parent_id TEXT,
        class_ids TEXT NOT NULL DEFAULT '[]',
        name TEXT,
        content TEXT NOT NULL DEFAULT '[]',
        icon TEXT,
        color TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT,
        updated_at TEXT,
        created_by TEXT,
        updated_by TEXT,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE node_child_order (
        parent_id TEXT NOT NULL,
        child_id TEXT NOT NULL,
        position TEXT NOT NULL,
        PRIMARY KEY (parent_id, child_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE class (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        name TEXT NOT NULL,
        icon TEXT,
        color TEXT,
        description TEXT,
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT,
        updated_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE class_member_set (
        node_id TEXT NOT NULL,
        class_id TEXT NOT NULL,
        present INTEGER NOT NULL,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT,
        PRIMARY KEY (node_id, class_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE class_extends (
        class_id TEXT NOT NULL,
        parent_class_id TEXT NOT NULL,
        PRIMARY KEY (class_id, parent_class_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE class_hierarchy (
        class_id TEXT NOT NULL,
        ancestor_id TEXT NOT NULL,
        PRIMARY KEY (class_id, ancestor_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE property_schema (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        name TEXT NOT NULL,
        type TEXT NOT NULL DEFAULT 'text',
        multi INTEGER NOT NULL DEFAULT 0,
        scope TEXT NOT NULL DEFAULT 'global',
        options TEXT NOT NULL DEFAULT '[]',
        target_class_filter TEXT,
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT,
        updated_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE property_value (
        id TEXT PRIMARY KEY,
        node_id TEXT NOT NULL,
        property_schema_id TEXT NOT NULL,
        value TEXT NOT NULL,
        idx INTEGER NOT NULL DEFAULT 0,
        metadata TEXT,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE property_value_tombstone (
        node_id TEXT NOT NULL,
        property_schema_id TEXT NOT NULL,
        idx INTEGER NOT NULL DEFAULT 0,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT,
        PRIMARY KEY (node_id, property_schema_id, idx)
      )
    ''');
    await db.execute('''
      CREATE TABLE collection_member (
        collection_id TEXT NOT NULL,
        object_id TEXT NOT NULL,
        present INTEGER NOT NULL,
        hlc_physical INTEGER NOT NULL DEFAULT 0,
        hlc_logical INTEGER NOT NULL DEFAULT 0,
        actor_id TEXT,
        PRIMARY KEY (collection_id, object_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE edge (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL DEFAULT '',
        source_id TEXT NOT NULL,
        target_id TEXT,
        type TEXT NOT NULL,
        verb TEXT,
        metadata TEXT,
        created_at TEXT
      )
    ''');
  }

  Future<void> _populateV2Snapshot(Database db, String workspaceId) async {
    final local = await _database.database;

    // icon/color live in the node payload JSON (node_cache has no columns
    // for them); title/position/node_type/hlc ride in the v16 columns.
    final nodeRows = await local.rawQuery(
      'SELECT uuid, name, title, position, node_type, parent_uuid, classes_uuid, '
      'is_deleted, is_archived, write_date, hlc_physical, hlc_logical, '
      'actor_id, payload FROM node_cache',
    );
    final batch = db.batch();
    for (final row in nodeRows) {
      final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      final nodeType = row['node_type'] as String? ??
          ((payload['is_page'] as bool? ?? false) ? 'page' : 'block');
      final isDeleted = (row['is_deleted'] as int? ?? 0) == 1;
      final isArchived = (row['is_archived'] as int? ?? 0) == 1;
      final content = row['name'] as String? ?? '[]';
      final position = row['position'] as String?;
      batch.insert('node', {
        'id': row['uuid'],
        'workspace_id': workspaceId,
        'node_type': nodeType,
        'parent_id': row['parent_uuid'],
        'class_ids': row['classes_uuid'] ?? '[]',
        'name': row['title'],
        'content': content,
        'icon': payload['icon'],
        'color': payload['color'],
        'is_active': (isDeleted || isArchived) ? 0 : 1,
        'created_at': payload['create_date'],
        'updated_at': row['write_date'],
        'hlc_physical': row['hlc_physical'] ?? 0,
        'hlc_logical': row['hlc_logical'] ?? 0,
        'actor_id': row['actor_id'],
      });
      if (row['parent_uuid'] != null && position != null) {
        batch.insert('node_child_order', {
          'parent_id': row['parent_uuid'],
          'child_id': row['uuid'],
          'position': position,
        });
      }
    }

    final classRows = await local.rawQuery(
      'SELECT uuid, name, icon, color, description, active, created_at, updated_at '
      'FROM class_cache',
    );
    for (final row in classRows) {
      batch.insert('class', {
        'id': row['uuid'],
        'workspace_id': workspaceId,
        'name': row['name'],
        'icon': row['icon'],
        'color': row['color'],
        'description': row['description'],
        'active': row['active'] ?? 1,
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
      });
    }

    for (final table in [
      'class_member_set',
      'class_extends',
      'class_hierarchy',
      'collection_member',
    ]) {
      final rows = await local.rawQuery('SELECT * FROM $table');
      for (final row in rows) {
        batch.insert(table, Map<String, dynamic>.from(row));
      }
    }

    final schemaRows = await local.rawQuery('SELECT * FROM property_schema');
    for (final row in schemaRows) {
      batch.insert('property_schema', {
        'id': row['uuid'],
        'workspace_id': workspaceId,
        'name': row['name'],
        'type': row['type'],
        'multi': row['multi'] ?? 0,
        'scope': row['scope'] ?? 'global',
        'options': row['options'] ?? '[]',
        'target_class_filter': row['class_filter_uuids'],
        'active': row['active'] ?? 1,
        'created_at': row['created_at'],
        'updated_at': row['updated_at'],
      });
    }

    final valueRows = await local.rawQuery('SELECT * FROM property_value');
    for (final row in valueRows) {
      batch.insert('property_value', {
        'id': row['id'],
        'node_id': row['node_uuid'],
        'property_schema_id': row['property_schema_id'],
        'value': row['value'],
        'idx': row['idx'] ?? 0,
        'metadata': row['metadata'],
        'hlc_physical': row['hlc_physical'] ?? 0,
        'hlc_logical': row['hlc_logical'] ?? 0,
        'actor_id': row['actor_id'],
      });
    }
    final tombRows =
        await local.rawQuery('SELECT * FROM property_value_tombstone');
    for (final row in tombRows) {
      batch.insert('property_value_tombstone', {
        'node_id': row['node_uuid'],
        'property_schema_id': row['property_schema_id'],
        'idx': row['idx'] ?? 0,
        'hlc_physical': row['hlc_physical'] ?? 0,
        'hlc_logical': row['hlc_logical'] ?? 0,
        'actor_id': row['actor_id'],
      });
    }

    final edgeRows = await local.rawQuery('SELECT * FROM edge');
    for (final row in edgeRows) {
      batch.insert('edge', Map<String, dynamic>.from(row));
    }
    await batch.commit(noResult: true);
  }

  // === Class → property bindings + effective read model ====================
  // (SCHEMA.md "Class properties"; ports of the v2 store's
  // applyClassPropertySet/Unset and effective.ts getEffectiveProperties.)

  /// Winner of a binding row, if any.
  Future<LwwWinner?> classPropertyBindingWinner(
    String classId,
    String schemaId,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'class_property',
      columns: ['hlc_physical', 'hlc_logical', 'actor_id'],
      where: 'class_id = ? AND property_schema_id = ?',
      whereArgs: [classId, schemaId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      physical: (row['hlc_physical'] as num?)?.toInt() ?? 0,
      logical: (row['hlc_logical'] as num?)?.toInt() ?? 0,
      actor: row['actor_id'] as String? ?? '',
    );
  }

  /// Upserts a binding row. Omitted fields KEEP their stored values (partial
  /// patch, port of the SQL COALESCE); [defaultValueJson] is the JSON-encoded
  /// default (null = leave untouched — JSON-null defaults ride raw maps).
  Future<void> upsertClassPropertyBinding({
    required String classId,
    required String schemaId,
    required LwwWinner incoming,
    int? sequence,
    bool? required,
    bool? readonly,
    bool? hideWhenEmpty,
    String? defaultValueJson,
  }) async {
    final db = await _database.database;
    final existing = await db.query(
      'class_property',
      where: 'class_id = ? AND property_schema_id = ?',
      whereArgs: [classId, schemaId],
      limit: 1,
    );
    final stored = existing.isEmpty ? const <String, dynamic>{} : existing.first;
    await db.insert(
      'class_property',
      {
        'class_id': classId,
        'property_schema_id': schemaId,
        'sequence': sequence ?? (stored['sequence'] as num?)?.toInt() ?? 0,
        'required':
            required == null ? stored['required'] : (required ? 1 : 0),
        'readonly':
            readonly == null ? stored['readonly'] : (readonly ? 1 : 0),
        'hide_when_empty': hideWhenEmpty == null
            ? stored['hide_when_empty']
            : (hideWhenEmpty ? 1 : 0),
        'default_value': defaultValueJson ?? stored['default_value'],
        'hlc_physical': incoming.physical,
        'hlc_logical': incoming.logical,
        'actor_id': incoming.actor,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Binding removal: plain DELETE, no tombstone (SCHEMA.md).
  Future<void> deleteClassPropertyBinding(
    String classId,
    String schemaId,
  ) async {
    final db = await _database.database;
    await db.delete(
      'class_property',
      where: 'class_id = ? AND property_schema_id = ?',
      whereArgs: [classId, schemaId],
    );
  }

  /// Effective (schema, idx) rows for [nodeId]
  /// (`effective(node, schema, idx) = authored ?? winning binding's default`).
  Future<List<EffectiveProperty>> getEffectiveProperties(String nodeId) async {
    final db = await _database.database;

    // 1. Authored rows, tombstone-suppressed with the same rule the applier
    //    enforces on write: a tombstone with >= (hlc, actor) blocks the value.
    final authoredRows = await db.query(
      'property_value',
      columns: [
        'property_schema_id',
        'value',
        'idx',
        'metadata',
        'hlc_physical',
        'hlc_logical',
        'actor_id',
      ],
      where: 'node_uuid = ?',
      whereArgs: [nodeId],
    );
    final tombstoneRows = await db.query(
      'property_value_tombstone',
      columns: [
        'property_schema_id',
        'idx',
        'hlc_physical',
        'hlc_logical',
        'actor_id',
      ],
      where: 'node_uuid = ?',
      whereArgs: [nodeId],
    );
    bool suppressed(Map<String, dynamic> row) {
      for (final tomb in tombstoneRows) {
        if (tomb['property_schema_id'] == row['property_schema_id'] &&
            tomb['idx'] == row['idx'] &&
            compareLww(
                  (
                    physical: (row['hlc_physical'] as num?)?.toInt() ?? 0,
                    logical: (row['hlc_logical'] as num?)?.toInt() ?? 0,
                    actor: row['actor_id'] as String? ?? '',
                  ),
                  (
                    physical: (tomb['hlc_physical'] as num?)?.toInt() ?? 0,
                    logical: (tomb['hlc_logical'] as num?)?.toInt() ?? 0,
                    actor: tomb['actor_id'] as String? ?? '',
                  ),
                ) <=
                0) {
          return true;
        }
      }
      return false;
    }

    // 2. The node's classes in assignment order: OR-Set add HLC ascending,
    //    ties by class id.
    // QueryResultSet is read-only: copy before sorting.
    final memberRows = (await db.query(
      'class_member_set',
      columns: ['class_id', 'hlc_physical', 'hlc_logical'],
      where: 'node_uuid = ? AND present = 1',
      whereArgs: [nodeId],
    ))
        .toList();
    memberRows.sort((a, b) {
      final pa = (a['hlc_physical'] as num?)?.toInt() ?? 0;
      final pb = (b['hlc_physical'] as num?)?.toInt() ?? 0;
      if (pa != pb) return pa - pb;
      final la = (a['hlc_logical'] as num?)?.toInt() ?? 0;
      final lb = (b['hlc_logical'] as num?)?.toInt() ?? 0;
      if (la != lb) return la - lb;
      return (a['class_id'] as String).compareTo(b['class_id'] as String);
    });

    // 3. Winning binding per schema: the first class (in assignment order)
    //    that binds the schema supplies the default AND the metadata.
    final winnerBySchema =
        <String, ({String classId, Map<String, dynamic> binding})>{};
    for (final cls in memberRows) {
      final classId = cls['class_id'] as String;
      final bindings = await db.query(
        'class_property',
        where: 'class_id = ?',
        whereArgs: [classId],
      );
      for (final binding in bindings) {
        final schemaId = binding['property_schema_id'] as String;
        winnerBySchema.putIfAbsent(
          schemaId,
          () => (classId: classId, binding: binding),
        );
      }
    }

    // 4. Schema rows for everything referenced (authored rows survive schema
    //    deletion: the row renders with schema = null).
    final schemaIds = <String>{
      for (final row in authoredRows) row['property_schema_id'] as String,
      ...winnerBySchema.keys,
    };
    final schemas = <String, EffectivePropertySchema>{};
    if (schemaIds.isNotEmpty) {
      final placeholders = schemaIds.map((_) => '?').join(',');
      final rows = await db.rawQuery(
        'SELECT uuid, name, type, multi FROM property_schema WHERE uuid IN ($placeholders)',
        schemaIds.toList(),
      );
      for (final row in rows) {
        schemas[row['uuid'] as String] = EffectivePropertySchema(
          id: row['uuid'] as String,
          name: row['name'] as String,
          type: row['type'] as String? ?? 'text',
          multi: (row['multi'] as num?)?.toInt() == 1,
        );
      }
    }

    bool? flag(dynamic value) => value == null ? null : value == 1;

    // 5. Merge: authored wins per (schema, idx); a winning binding with a
    //    default and no authored value at idx 0 derives a default row.
    final rows = <String, EffectiveProperty>{};
    for (final authored in authoredRows) {
      if (suppressed(authored)) continue;
      final schemaId = authored['property_schema_id'] as String;
      final idx = (authored['idx'] as num?)?.toInt() ?? 0;
      final winner = winnerBySchema[schemaId];
      final metadata = authored['metadata'] as String?;
      rows['$schemaId:$idx'] = EffectiveProperty(
        propertySchemaId: schemaId,
        idx: idx,
        schema: schemas[schemaId],
        value: _decodeJsonOrRaw(authored['value'] as String),
        metadata: metadata == null ? null : _decodeJsonOrRaw(metadata),
        source: 'authored',
        boundBy: winner?.classId,
        required: winner == null ? null : flag(winner.binding['required']),
        readonly: winner == null ? null : flag(winner.binding['readonly']),
        hideWhenEmpty:
            winner == null ? null : flag(winner.binding['hide_when_empty']),
        sequence: winner == null
            ? null
            : (winner.binding['sequence'] as num?)?.toInt(),
      );
    }
    for (final entry in winnerBySchema.entries) {
      final schemaId = entry.key;
      final winner = entry.value;
      final defaultRaw = winner.binding['default_value'];
      if (defaultRaw == null) continue; // bound without a default
      final key = '$schemaId:0';
      if (rows.containsKey(key)) continue; // authored idx 0 shadows default
      rows[key] = EffectiveProperty(
        propertySchemaId: schemaId,
        idx: 0,
        schema: schemas[schemaId],
        value: _decodeJsonOrRaw(defaultRaw as String),
        metadata: null,
        source: 'default',
        boundBy: winner.classId,
        required: flag(winner.binding['required']),
        readonly: flag(winner.binding['readonly']),
        hideWhenEmpty: flag(winner.binding['hide_when_empty']),
        sequence: (winner.binding['sequence'] as num?)?.toInt(),
      );
    }

    // 6. Deterministic presentation order: bound rows by binding sequence,
    //    unbound authored rows last; schema name then idx as tiebreak.
    final result = rows.values.toList();
    String nameOf(EffectiveProperty row) =>
        row.schema?.name ?? row.propertySchemaId;
    result.sort((a, b) {
      final boundDelta =
          (a.boundBy == null ? 1 : 0) - (b.boundBy == null ? 1 : 0);
      if (boundDelta != 0) return boundDelta;
      final seqA = a.sequence ?? 0x7fffffffffffffff;
      final seqB = b.sequence ?? 0x7fffffffffffffff;
      if (seqA != seqB) return seqA - seqB;
      final nameDelta = nameOf(a).compareTo(nameOf(b));
      if (nameDelta != 0) return nameDelta;
      return a.idx - b.idx;
    });
    return result;
  }

  // === Edge index (derived references; v2 store edges.ts port) ===========

  /// Rebuilds the derived `edge` rows for [sourceId] from its current
  /// content tokens and node-typed property values:
  ///
  ///  - `mention` — mention tokens (edge per instance);
  ///  - `typed_link` — typed-link word marks, top-level and inside quotes;
  ///    target_id stays NULL by design (candidateSpans are recorded,
  ///    resolution is M2 work); verb is the free string or the bound
  ///    propertySchemaId; metadata carries locator/candidateSpans + text;
  ///  - `property` — node-typed property values (`{"nodeId": ...}`), with
  ///    verb = propertySchemaId.
  ///
  /// Edge ids are deterministic (sha256 over source/type/target/verb/
  /// metadata/occurrence), so wipe -> replay converges to identical rows.
  Future<void> rebuildEdges(String sourceId, {String? at}) async {
    final db = await _database.database;
    final node = await getByUuid(sourceId);
    if (node == null) {
      // Node gone: drop everything this source ever derived.
      await db.delete('edge', where: 'source_id = ?', whereArgs: [sourceId]);
      return;
    }

    final desired = <_DesiredEdge>[];
    void walk(List<Map<String, dynamic>> tokens) {
      for (final token in tokens) {
        switch (token['type']) {
          case 'mention':
            final target = token['targetNodeId'] as String?;
            if (target != null && target.isNotEmpty) {
              desired.add(_DesiredEdge(
                targetId: target,
                type: 'mention',
              ));
            }
          case 'typed_link':
            final rawVerb = token['verb'];
            final verb = rawVerb is String
                ? rawVerb
                : rawVerb is Map<String, dynamic>
                    ? rawVerb['propertySchemaId'] as String?
                    : null;
            final metadata = <String, dynamic>{};
            final rawMetadata = token['metadata'];
            if (rawMetadata is Map<String, dynamic>) {
              metadata.addAll(rawMetadata);
            }
            final text = token['text'];
            if (text is String) metadata['text'] = text;
            desired.add(_DesiredEdge(
              targetId: null,
              type: 'typed_link',
              verb: verb,
              metadata: metadata.isEmpty ? null : jsonEncode(metadata),
            ));
          case 'quote':
            final children = token['children'];
            if (children is List) {
              walk([
                for (final child in children)
                  if (child is Map<String, dynamic>) child,
              ]);
            }
        }
      }
    }

    walk(contentTokensFromSource(node.name));

    // Node-typed property values project into the edge index.
    for (final row in await propertyValuesFor(sourceId)) {
      final value = row.value;
      if (value is Map<String, dynamic>) {
        final target = value['nodeId'];
        if (target is String && target.isNotEmpty) {
          desired.add(_DesiredEdge(
            targetId: target,
            type: 'property',
            verb: row.schemaId,
            metadata: row.metadata is Map<String, dynamic>
                ? jsonEncode(row.metadata)
                : null,
          ));
        }
      }
    }

    final desiredIds = <String>{};
    final occurrenceByKey = <String, int>{};
    final sha = Sha256();
    final batch = db.batch();
    for (final edge in desired) {
      final key = '${edge.type}\u0000${edge.targetId ?? ''}'
          '\u0000${edge.verb ?? ''}\u0000${edge.metadata ?? ''}';
      final occurrence = occurrenceByKey[key] ?? 0;
      occurrenceByKey[key] = occurrence + 1;
      final digest = await sha.hash(utf8.encode([
        sourceId,
        edge.type,
        edge.targetId ?? '',
        edge.verb ?? '',
        edge.metadata ?? '',
        '$occurrence',
      ].join('\u0000')));
      final id = digest.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      desiredIds.add(id);
      batch.insert(
        'edge',
        {
          'id': id,
          'source_id': sourceId,
          'target_id': edge.targetId,
          'type': edge.type,
          'verb': edge.verb,
          'metadata': edge.metadata,
          // Content-derived edges stamp the applying op; property edges stay
          // NULL so cross-order replays do not diverge on a timestamp.
          'created_at': edge.type == 'property' ? null : at,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    final existing = await db.query(
      'edge',
      columns: ['id'],
      where: 'source_id = ?',
      whereArgs: [sourceId],
    );
    for (final row in existing) {
      if (!desiredIds.contains(row['id'])) {
        batch.delete('edge', where: 'id = ?', whereArgs: [row['id']]);
      }
    }
    await batch.commit(noResult: true);
  }

  /// Edges pointing at [targetId] (backlinks), ordered deterministically.
  Future<List<Map<String, dynamic>>> backlinks(String targetId) async {
    final db = await _database.database;
    return db.query(
      'edge',
      where: 'target_id = ?',
      whereArgs: [targetId],
      orderBy: 'source_id, type, verb, id',
    );
  }

  /// All edges derived from [sourceId] (outgoing references).
  Future<List<Map<String, dynamic>>> references(String sourceId) async {
    final db = await _database.database;
    return db.query(
      'edge',
      where: 'source_id = ?',
      whereArgs: [sourceId],
      orderBy: 'type, verb, id',
    );
  }

  // === Content LWW tracking ===

  /// The last applied `node.updateContent` HLC for [uuid], if any.
  Future<Hlc?> getContentHlc(String uuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_content_hlc',
      where: 'node_uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Hlc(
      physical: rows.first['hlc_physical'] as int,
      logical: rows.first['hlc_logical'] as int,
    );
  }

  /// Records [hlc] as the last applied content HLC for [uuid].
  Future<void> setContentHlc(String uuid, Hlc hlc) async {
    final db = await _database.database;
    await db.insert('node_content_hlc', {
      'node_uuid': uuid,
      'hlc_physical': hlc.physical,
      'hlc_logical': hlc.logical,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Indexes a single node, replacing any existing index rows for it.
  Future<void> indexNode(Node node) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await _indexNodeInTxn(txn, node);
    });
  }

  /// Removes all rows from the local search index.
  Future<void> clearSearchIndex() async {
    final db = await _database.database;
    await db.delete('search_index');
  }

  /// Searches the local index and returns matching node UUIDs ordered by
  /// relevance (sum of matched term ranks).
  Future<List<String>> searchLocal(String query, {int limit = 20}) async {
    final terms = tokenize(query).toList();
    if (terms.isEmpty) return const [];

    final db = await _database.database;
    final placeholders = terms.map((_) => '?').join(',');
    final rows = await db.rawQuery(
      '''
      SELECT si.node_uuid, SUM(si.rank) as score
      FROM search_index si
      INNER JOIN node_cache nc ON nc.uuid = si.node_uuid
      WHERE si.term IN ($placeholders) AND nc.is_deleted = 0 AND nc.is_archived = 0
      GROUP BY si.node_uuid
      ORDER BY score DESC
      LIMIT ?
    ''',
      [...terms, limit],
    );

    return rows.map((row) => row['node_uuid'] as String).toList();
  }

  /// Rebuilds the search index from every node currently in [node_cache].
  Future<void> reindexAll() async {
    final nodes = await getAll(includeDeleted: false);
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete('search_index');
      await _indexNodesInTxn(txn, nodes);
    });
  }

  /// Whether the search index is empty while the node cache has rows, which
  /// indicates a fresh table that needs backfilling.
  Future<bool> shouldReindexSearch() async {
    final db = await _database.database;
    final indexRows = await db.rawQuery(
      'SELECT COUNT(*) as count FROM search_index',
    );
    final cacheRows = await db.rawQuery(
      'SELECT COUNT(*) as count FROM node_cache',
    );
    final indexCount = indexRows.first['count'] as int? ?? 0;
    final cacheCount = cacheRows.first['count'] as int? ?? 0;
    return indexCount == 0 && cacheCount > 0;
  }

  Future<void> _upsertNodeInTxn(DatabaseExecutor txn, Node node) async {
    await txn.insert(
      'node_cache',
      _nodeToRow(node, DateTime.now().millisecondsSinceEpoch),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Map<String, dynamic> _nodeToRow(Node node, int syncedAt) {
    return {
      'uuid': node.uuid,
      'name': node.name,
      'parent_uuid': node.parentUuid,
      'classes_uuid': jsonEncode(node.classesUuid),
      'is_page': node.isPage ? 1 : 0,
      'is_task': node.isTask ? 1 : 0,
      'is_daily': node.isDaily ? 1 : 0,
      'is_monthly': node.isMonthly ? 1 : 0,
      'is_yearly': node.isYearly ? 1 : 0,
      'is_deleted': node.isDeleted ? 1 : 0,
      'is_archived': node.isArchived ? 1 : 0,
      'sequence': node.sequence,
      'version': node.id,
      'write_date': node.writeDate,
      'payload': jsonEncode(node.toJson()),
      'synced_at': syncedAt,
      // v2 derived-state columns (see AppDatabase._migrateV16 / _migrateV19).
      'title': node.title,
      'position': node.position,
      'node_type': node.nodeType,
      'class_order': jsonEncode(node.classOrder),
      'hlc_physical': node.hlcPhysical,
      'hlc_logical': node.hlcLogical,
      'actor_id': node.actorId,
    };
  }

  Node _nodeFromRow(Map<String, dynamic> row) {
    final payload = row['payload'] as String;
    return Node.fromJson(jsonDecode(payload) as Map<String, dynamic>);
  }

  Future<void> _indexNodeInTxn(DatabaseExecutor txn, Node node) async {
    await _indexNodesInTxn(txn, [node]);
  }

  Future<void> _indexNodesInTxn(DatabaseExecutor txn, List<Node> nodes) async {
    if (nodes.isEmpty) return;

    final uuids = nodes.map((n) => n.uuid).toList();
    final placeholders = uuids.map((_) => '?').join(',');
    await txn.rawDelete(
      'DELETE FROM search_index WHERE node_uuid IN ($placeholders)',
      uuids,
    );

    final batch = txn.batch();
    for (final node in nodes) {
      if (node.isDeleted || node.isArchived) continue;
      for (final row in buildSearchIndexRows(node)) {
        batch.insert('search_index', row.toMap());
      }
    }
    await batch.commit(noResult: true);
  }

  bool _isClosedTask(Node node) {
    final value = node.properties[SystemPropertyUuids.taskStatus];
    final name = _resolveTaskStatusName(value);
    return name != null && TaskStatuses.closed.contains(name);
  }

  bool _matchesFilters(Node node, SearchFilters filters) {
    final isDatePage = node.isDaily || node.isMonthly || node.isYearly;
    switch (filters.nodeType) {
      case NodeType.page:
        if (!node.isPage || isDatePage) return false;
      case NodeType.task:
        if (!node.isTask) return false;
      case NodeType.journal:
        if (!isDatePage) return false;
      case NodeType.any:
        // Date pages are intentionally scoped to journal views; do not surface
        // them in generic "any" searches unless the user is explicitly looking
        // for a date by query text.
        if (isDatePage) return false;
    }

    if (filters.classUuids.isNotEmpty) {
      final hasAny = filters.classUuids.any(node.classesUuid.contains);
      if (!hasAny) return false;
    }

    switch (filters.taskState) {
      case TaskState.open:
        if (!node.isTask || _isClosedTask(node)) return false;
      case TaskState.completed:
        if (!node.isTask || !_isClosedTask(node)) return false;
      case TaskState.any:
        break;
    }

    if (filters.dateFrom != null || filters.dateTo != null) {
      final dateStr =
          node.properties[SystemPropertyUuids.taskDeadline] as String?;
      if (dateStr == null || dateStr.isEmpty) return false;
      final date = DateTime.tryParse(dateStr);
      if (date == null) return false;
      final from = filters.dateFrom;
      final to = filters.dateTo;
      if (from != null && date.isBefore(from)) return false;
      if (to != null && date.isAfter(to)) return false;
    }

    return true;
  }

  void _sortFiltered(List<Node> nodes, SearchFilters filters) {
    final orderFactor = filters.order == SortOrder.asc ? 1 : -1;
    switch (filters.sortBy) {
      case SortBy.name:
        nodes.sort(
          (a, b) => orderFactor * a.displayName.compareTo(b.displayName),
        );
      case SortBy.writeDate:
        nodes.sort(
          (a, b) => orderFactor * _compareDates(a.writeDate, b.writeDate),
        );
      case SortBy.createDate:
        nodes.sort(
          (a, b) => orderFactor * _compareDates(a.createDate, b.createDate),
        );
      case SortBy.dueDate:
        nodes.sort((a, b) {
          final ad = _taskDeadline(a);
          final bd = _taskDeadline(b);
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return orderFactor * ad.compareTo(bd);
        });
      case SortBy.priority:
        nodes.sort((a, b) {
          final ap = _priorityIndex(a);
          final bp = _priorityIndex(b);
          return orderFactor * (ap - bp);
        });
      case SortBy.manual:
        nodes.sort((a, b) => orderFactor * a.sequence.compareTo(b.sequence));
      case SortBy.relevance:
        // Relevance ordering is already provided by searchLocal.
        break;
    }
  }

  int _compareDates(String? a, String? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    return a.compareTo(b);
  }

  DateTime? _taskDeadline(Node node) {
    final value = node.properties[SystemPropertyUuids.taskDeadline] as String?;
    if (value == null || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  int _priorityIndex(Node node) {
    const priorities = ['Low', 'Medium', 'High', 'Urgent'];
    final value = node.properties[SystemPropertyUuids.taskPriority];
    final name = value is String ? value : null;
    return priorities.indexOf(name ?? '');
  }

  String? _resolveTaskStatusName(dynamic value) {
    if (value == null) return null;
    if (value is String) {
      for (final option in _taskStatusOptions) {
        if (option.uuid == value) return option.name;
      }
      if (TaskStatuses.all.contains(value)) return value;
    }
    return null;
  }

  Property _genericProperty(String uuid) {
    return Property(
      id: 0,
      uuid: uuid,
      name: uuid,
      type: 'text',
      isSystem: false,
    );
  }

  static final Map<String, Property> _knownPropertySchemas = {
    SystemPropertyUuids.taskStatus: Property(
      id: 0,
      uuid: SystemPropertyUuids.taskStatus,
      name: 'Status',
      type: 'selection',
      isSystem: true,
      options: _taskStatusOptions,
    ),
    SystemPropertyUuids.taskDeadline: Property(
      id: 0,
      uuid: SystemPropertyUuids.taskDeadline,
      name: 'Deadline',
      type: 'date',
      isSystem: true,
    ),
    SystemPropertyUuids.taskScheduled: Property(
      id: 0,
      uuid: SystemPropertyUuids.taskScheduled,
      name: 'Scheduled',
      type: 'date',
      isSystem: true,
    ),
    SystemPropertyUuids.taskPriority: Property(
      id: 0,
      uuid: SystemPropertyUuids.taskPriority,
      name: 'Priority',
      type: 'selection',
      isSystem: true,
      options: _taskPriorityOptions,
    ),
  };

  static final List<Property> _taskProperties = [
    _knownPropertySchemas[SystemPropertyUuids.taskStatus]!,
    _knownPropertySchemas[SystemPropertyUuids.taskDeadline]!,
    _knownPropertySchemas[SystemPropertyUuids.taskScheduled]!,
    _knownPropertySchemas[SystemPropertyUuids.taskPriority]!,
  ];

  static final List<SelectionOption> _taskStatusOptions = TaskStatuses.all
      .asMap()
      .entries
      .map(
        (e) => SelectionOption(
          id: e.key,
          uuid: const Uuid().v5(
            Namespace.url.value,
            'notees:task-status:${e.value}',
          ),
          name: e.value,
        ),
      )
      .toList();

  static final List<SelectionOption> _taskPriorityOptions =
      const ['Low', 'Medium', 'High', 'Urgent']
          .asMap()
          .entries
          .map(
            (e) => SelectionOption(
              id: e.key,
              uuid: const Uuid().v5(
                Namespace.url.value,
                'notees:task-priority:${e.value}',
              ),
              name: e.value,
            ),
          )
          .toList();

  // === Class cache helpers ===

  Node _classFromRow(Map<String, dynamic> row) {
    final name = _normalizeClassName(row['name'] as String?);
    final extendsJson = row['extends_uuid'] as String?;
    List<String> extendsUuid = const [];
    if (extendsJson != null && extendsJson.isNotEmpty) {
      try {
        extendsUuid = (jsonDecode(extendsJson) as List<dynamic>).cast<String>();
      } catch (_) {}
    }
    return Node(
      id: 0,
      uuid: row['uuid'] as String,
      name: name,
      displayName: name,
      icon: row['icon'] as String?,
      color: row['color'] as String?,
      classesUuid: const [],
      tagsUuid: const [],
      properties: const {},
      children: const [],
      createDate: row['created_at'] as String?,
      writeDate: row['updated_at'] as String?,
      extendsUuid: extendsUuid,
    );
  }

  Map<String, dynamic> _classToRow(_ClassRow cls) {
    return {
      'uuid': cls.uuid,
      'name': cls.name,
      'icon': cls.icon,
      'color': cls.color,
      'description': cls.description,
      'extends_uuid': jsonEncode(cls.extendsUuids),
      'active': cls.active ? 1 : 0,
      'created_at': cls.createdAt,
      'updated_at': cls.updatedAt,
    };
  }

  // === Property schema helpers ===

  PropertySchemaRow _propertySchemaRowFromDb(Map<String, dynamic> row) {
    List<String> classFilterUuids;
    List<Map<String, dynamic>> options;
    Map<String, dynamic>? validationRules;
    dynamic defaultValue;
    try {
      classFilterUuids =
          (jsonDecode(row['class_filter_uuids'] as String? ?? '[]')
                  as List<dynamic>)
              .cast<String>();
    } catch (_) {
      classFilterUuids = const [];
    }
    try {
      options = (jsonDecode(row['options'] as String? ?? '[]') as List<dynamic>)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      options = const [];
    }
    try {
      final raw = row['validation_rules'] as String?;
      validationRules = raw == null
          ? null
          : jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      validationRules = null;
    }
    try {
      final raw = row['default_value'] as String?;
      defaultValue = raw == null ? null : jsonDecode(raw);
    } catch (_) {
      defaultValue = row['default_value'];
    }
    return PropertySchemaRow(
      uuid: row['uuid'] as String,
      workspaceId: row['workspace_id'] as String,
      name: row['name'] as String,
      icon: row['icon'] as String?,
      type: row['type'] as String? ?? 'text',
      multi: (row['multi'] as int? ?? 0) == 1,
      isSystem: (row['is_system'] as int? ?? 0) == 1,
      scope: row['scope'] as String? ?? 'global',
      nodeUuid: row['node_uuid'] as String?,
      iconVisibility: row['icon_visibility'] as String?,
      validationRules: validationRules,
      required: (row['required'] as int? ?? 0) == 1,
      readonly: (row['readonly'] as int? ?? 0) == 1,
      hideWhenEmpty: (row['hide_when_empty'] as int? ?? 0) == 1,
      defaultValue: defaultValue,
      classFilterUuids: classFilterUuids,
      options: options,
      computed: row['computed'] as String?,
      active: (row['active'] as int? ?? 1) == 1,
      createdAt: row['created_at'] as String?,
      updatedAt: row['updated_at'] as String?,
    );
  }

  Map<String, dynamic> _propertySchemaToRow(PropertySchemaRow schema) {
    return {
      'uuid': schema.uuid,
      'workspace_id': schema.workspaceId,
      'name': schema.name,
      'icon': schema.icon,
      'type': schema.type,
      'multi': schema.multi ? 1 : 0,
      'is_system': schema.isSystem ? 1 : 0,
      'scope': schema.scope,
      'node_uuid': schema.nodeUuid,
      'icon_visibility': schema.iconVisibility,
      'validation_rules': schema.validationRules == null
          ? null
          : jsonEncode(schema.validationRules),
      'required': schema.required ? 1 : 0,
      'readonly': schema.readonly ? 1 : 0,
      'hide_when_empty': schema.hideWhenEmpty ? 1 : 0,
      'default_value': schema.defaultValue == null
          ? null
          : jsonEncode(schema.defaultValue),
      'class_filter_uuids': jsonEncode(schema.classFilterUuids),
      'options': jsonEncode(schema.options),
      'computed': schema.computed,
      'active': schema.active ? 1 : 0,
      'created_at': schema.createdAt,
      'updated_at': schema.updatedAt,
    };
  }

  Property _propertySchemaFromRow(Map<String, dynamic> row) {
    List<SelectionOption> options;
    List<String> classFilters;
    Map<String, dynamic>? validationRules;
    try {
      options =
          ((jsonDecode(row['options'] as String? ?? '[]') as List<dynamic>?) ??
                  const [])
              .map((e) => _selectionOptionFromJson(e as Map<String, dynamic>))
              .toList();
    } catch (_) {
      options = const [];
    }
    try {
      classFilters =
          (jsonDecode(row['class_filter_uuids'] as String? ?? '[]')
                  as List<dynamic>)
              .map((e) => e.toString())
              .toList();
    } catch (_) {
      classFilters = const [];
    }
    try {
      final raw = row['validation_rules'] as String?;
      validationRules = raw == null
          ? null
          : jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      validationRules = null;
    }
    return Property(
      id: 0,
      uuid: row['uuid'] as String,
      name: row['name'] as String,
      type: row['type'] as String? ?? 'text',
      icon: row['icon'] as String?,
      multi: (row['multi'] as int? ?? 0) == 1,
      isSystem: (row['is_system'] as int? ?? 0) == 1,
      scope: row['scope'] as String? ?? 'global',
      nodeUuid: row['node_uuid'] as String?,
      iconVisibility: row['icon_visibility'] as String? ?? 'hidden',
      validationRules: validationRules,
      classFilters: classFilters,
      options: options,
      createDate: row['created_at'] as String?,
      writeDate: row['updated_at'] as String?,
    );
  }

  SelectionOption _selectionOptionFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final uuid =
        (json['uuid'] as String?) ??
        (json['selection_line_uuid'] as String?) ??
        (json['id']?.toString() ?? '');
    return SelectionOption(
      id: id is int ? id : int.tryParse(id?.toString() ?? '0') ?? 0,
      uuid: uuid,
      name: (json['name'] as String?) ?? '',
      icon: json['icon'] as String?,
      color: json['color'] as String?,
      sequence: (json['sequence'] as int?) ?? (json['order'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> _classPropertyEdgeToRow(ClassPropertyEdgeRow edge) {
    return {
      'class_uuid': edge.classUuid,
      'property_uuid': edge.propertyUuid,
      'sequence': edge.sequence,
      'default_value': edge.defaultValue == null
          ? null
          : jsonEncode(edge.defaultValue),
      'hidden': edge.hidden ? 1 : 0,
      'required': edge.required == null ? null : (edge.required! ? 1 : 0),
      'readonly': edge.readonly == null ? null : (edge.readonly! ? 1 : 0),
      'hide_when_empty': edge.hideWhenEmpty == null
          ? null
          : (edge.hideWhenEmpty! ? 1 : 0),
    };
  }

  Future<void> upsertPropertySchema(PropertySchemaRow schema) async {
    final db = await _database.database;
    await db.insert(
      'property_schema',
      _propertySchemaToRow(schema),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deletePropertySchema(String uuid) async {
    final db = await _database.database;
    await db.update(
      'property_schema',
      {'active': 0},
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
  }

  Future<void> upsertClassPropertyEdge(ClassPropertyEdgeRow edge) async {
    final db = await _database.database;
    await db.insert(
      'class_property_edge',
      _classPropertyEdgeToRow(edge),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteClassPropertyEdge(
    String classUuid,
    String propertyUuid,
  ) async {
    final db = await _database.database;
    await db.delete(
      'class_property_edge',
      where: 'class_uuid = ? AND property_uuid = ?',
      whereArgs: [classUuid, propertyUuid],
    );
  }

  Future<void> reorderClassPropertyEdges(
    String classUuid,
    List<String> orderedPropertyUuids,
  ) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      for (var i = 0; i < orderedPropertyUuids.length; i++) {
        await txn.update(
          'class_property_edge',
          {'sequence': i},
          where: 'class_uuid = ? AND property_uuid = ?',
          whereArgs: [classUuid, orderedPropertyUuids[i]],
        );
      }
    });
  }

  static String _normalizeClassName(String? name) {
    if (name == null || name.trim().isEmpty) {
      return 'Untitled class';
    }
    final trimmed = name.trim();
    if (trimmed.startsWith('[')) {
      final plain = astToPlainText(trimmed);
      if (plain.isNotEmpty) return plain;
    }
    return trimmed.isEmpty ? 'Untitled class' : trimmed;
  }
}

/// Row-level LWW metadata read from a `node_cache` row (v2 derived columns).
class NodeRowMeta {
  const NodeRowMeta({
    this.nodeType,
    required this.physical,
    required this.logical,
    required this.actor,
  });

  final String? nodeType;
  final int physical;
  final int logical;
  final String actor;

  LwwWinner get winner => (physical: physical, logical: logical, actor: actor);
}

/// One live row of the derived `property_value` table.
class PropertyValueRow {
  const PropertyValueRow({
    required this.schemaId,
    required this.idx,
    required this.value,
    this.metadata,
  });

  final String schemaId;
  final int idx;
  final dynamic value;
  final dynamic metadata;
}

/// Class-derived flags (task/journal/table/asset/comment), mirroring the
/// applier's flag derivation from a node's class list.
({
  bool isTask,
  bool isDaily,
  bool isMonthly,
  bool isYearly,
  bool isTable,
  bool isAsset,
  bool isComment,
})
_deriveFlags(List<String> classIds) {
  return (
    isTask: classIds.contains(SystemClassUuids.task),
    isDaily: classIds.contains(SystemClassUuids.day),
    isMonthly: classIds.contains(SystemClassUuids.month),
    isYearly: classIds.contains(SystemClassUuids.year),
    isTable: classIds.contains(SystemClassUuids.table),
    isAsset: classIds.contains(SystemClassUuids.asset),
    isComment: classIds.contains(SystemClassUuids.comment),
  );
}

/// Bundle of everything read from a v2 server-derived snapshot database,
/// ready to be written into the local derived-state tables.
class SnapshotRestoreData {
  const SnapshotRestoreData({
    required this.nodes,
    required this.classes,
    required this.propertySchemas,
    required this.classPropertyEdges,
    required this.classMemberRows,
    required this.tagMemberRows,
    required this.propertyValueRows,
    required this.propertyTombstoneRows,
    required this.collectionMemberRows,
    required this.classExtendsEdges,
  });

  final List<Node> nodes;

  // ignore: library_private_types_in_public_api
  final List<_ClassRow> classes;
  final List<PropertySchemaRow> propertySchemas;
  final List<ClassPropertyEdgeRow> classPropertyEdges;
  final List<Map<String, dynamic>> classMemberRows;
  final List<Map<String, dynamic>> tagMemberRows;
  final List<Map<String, dynamic>> propertyValueRows;
  final List<Map<String, dynamic>> propertyTombstoneRows;
  final List<Map<String, dynamic>> collectionMemberRows;
  final List<(String, String)> classExtendsEdges;
}


/// One desired derived edge (v2 store DesiredEdge port).
class _DesiredEdge {
  const _DesiredEdge({
    required this.targetId,
    required this.type,
    this.verb,
    this.metadata,
  });

  final String? targetId;
  final String type;
  final String? verb;
  final String? metadata;
}


/// The property-schema slice the effective read model exposes.
class EffectivePropertySchema {
  const EffectivePropertySchema({
    required this.id,
    required this.name,
    required this.type,
    required this.multi,
  });

  final String id;
  final String name;
  final String type;
  final bool multi;
}

/// One effective (schema, idx) row for a node (port of the v2 store's
/// EffectiveProperty): `source` tags authored vs derived; `boundBy` is the
/// class supplying the binding metadata, or null when no current class binds
/// the schema (an authored value whose binding went away stays visible).
class EffectiveProperty {
  const EffectiveProperty({
    required this.propertySchemaId,
    required this.idx,
    required this.schema,
    required this.value,
    required this.metadata,
    required this.source,
    required this.boundBy,
    required this.required,
    required this.readonly,
    required this.hideWhenEmpty,
    required this.sequence,
  });

  final String propertySchemaId;
  final int idx;
  final EffectivePropertySchema? schema;
  final dynamic value;
  final dynamic metadata;
  final String source; // 'authored' | 'default'
  final String? boundBy;
  final bool? required;
  final bool? readonly;
  final bool? hideWhenEmpty;
  final int? sequence;
}

dynamic _decodeJsonOrRaw(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return raw;
  }
}
