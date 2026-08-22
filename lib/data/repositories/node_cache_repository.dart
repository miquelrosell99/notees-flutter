import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/system.dart';
import '../../core/utils/ast_stringifier.dart';
import '../../core/utils/search_index_builder.dart';
import '../../data/local/app_database.dart';
import '../../data/models/linked_reference.dart';
import '../../data/models/node.dart';
import '../../data/models/page_content.dart';
import '../../data/models/property.dart';
import '../../domain/models/relay/hlc.dart';
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

  static const _lastSyncKey = 'sync_v1_last_sync';

  Future<String?> getLastSync() async {
    final db = await _database.database;
    final rows = await db.query('sync_state', where: 'key = ?', whereArgs: [_lastSyncKey]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setLastSync(String? value) async {
    final db = await _database.database;
    if (value == null) {
      await db.delete('sync_state', where: 'key = ?', whereArgs: [_lastSyncKey]);
      return;
    }
    await db.insert(
      'sync_state',
      {'key': _lastSyncKey, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
    await db.rawDelete('DELETE FROM node_cache WHERE uuid IN ($placeholders)', uuids);
  }

  /// Hard-deletes [uuid] and all of its derived rows, matching the server's
  /// `node.delete` / `node.permanentDelete` semantics: the operation log has
  /// no soft-delete in the derived node table — archival (`is_archived`) is
  /// the recoverable concept.
  Future<void> hardDelete(String uuid) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete('node_cache', where: 'uuid = ?', whereArgs: [uuid]);
      await txn.delete('search_index', where: 'node_uuid = ?', whereArgs: [uuid]);
      await txn.delete('user_favorite', where: 'node_uuid = ?', whereArgs: [uuid]);
      await txn.delete('task_completion', where: 'node_uuid = ?', whereArgs: [uuid]);
      await txn.delete('task_recurrence', where: 'node_uuid = ?', whereArgs: [uuid]);
      await txn.delete('node_content_hlc', where: 'node_uuid = ?', whereArgs: [uuid]);
    });
  }

  Future<Node?> getByUuid(String uuid) async {
    final db = await _database.database;
    final rows = await db.query('node_cache', where: 'uuid = ?', whereArgs: [uuid]);
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
    await db.delete('node_cache');
  }

  /// Restores the local node cache from a server-derived snapshot byte payload.
  ///
  /// The snapshot is a SQLite database file containing the server's derived
  /// `node`, `property_value`, and `node_child_order` tables. This method opens
  /// it in a temp file, reads the relevant rows, and rebuilds `node_cache`.
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
      final nodes = await readNodesFromSnapshotDatabase(snapshotDb, workspaceId);
      final classes = await _readClassesFromSnapshotDatabase(snapshotDb, workspaceId);
      final propertySchemas = await _readPropertySchemasFromSnapshotDatabase(snapshotDb, workspaceId);
      final classPropertyEdges = await _readClassPropertyEdgesFromSnapshotDatabase(snapshotDb, workspaceId);
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
        final now = DateTime.now().millisecondsSinceEpoch;
        final nodeBatch = txn.batch();
        for (final node in nodes) {
          nodeBatch.insert(
            'node_cache',
            _nodeToRow(node, now),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await nodeBatch.commit(noResult: true);
        await _indexNodesInTxn(txn, nodes.where((n) => !n.isDeleted).toList());
        final classBatch = txn.batch();
        for (final cls in classes) {
          classBatch.insert(
            'class_cache',
            _classToRow(cls),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await classBatch.commit(noResult: true);
        final propertyBatch = txn.batch();
        for (final schema in propertySchemas) {
          propertyBatch.insert(
            'property_schema',
            _propertySchemaToRow(schema),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await propertyBatch.commit(noResult: true);
        final edgeBatch = txn.batch();
        for (final edge in classPropertyEdges) {
          edgeBatch.insert(
            'class_property_edge',
            _classPropertyEdgeToRow(edge),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await edgeBatch.commit(noResult: true);
      });
    } finally {
      await snapshotDb?.close();
      try {
        await tempFile.delete();
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }

  /// Reads [Node] objects from a server-derived snapshot database.
  ///
  /// Exposed for testing; most callers should use [restoreFromSnapshot].
  Future<List<Node>> readNodesFromSnapshotDatabase(Database db, String workspaceId) async {
    final nodeRows = await db.query(
      'node',
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
    );
    if (nodeRows.isEmpty) return const [];

    final nodeIds = nodeRows.map((r) => r['id'] as String).toList();
    final placeholders = nodeIds.map((_) => '?').join(',');

    // Read property values for these nodes.
    final propertiesByNode = <String, Map<String, dynamic>>{};
    final propRows = await db.rawQuery(
      'SELECT node_id, property_schema_id, value, idx FROM property_value '
      'WHERE node_id IN ($placeholders) ORDER BY idx ASC',
      nodeIds,
    );
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
      (propertiesByNode[nodeId] ??= {})[schemaId] = decoded;
    }

    // Read child order positions.
    final sequenceByNode = <String, double>{};
    final orderRows = await db.rawQuery(
      'SELECT child_id, position FROM node_child_order WHERE child_id IN ($placeholders)',
      nodeIds,
    );
    for (final row in orderRows) {
      final childId = row['child_id'] as String;
      final position = row['position'] as String?;
      sequenceByNode[childId] = double.tryParse(position ?? '') ?? 0.0;
    }

    return nodeRows.map((row) {
      final uuid = row['id'] as String;
      final kind = row['kind'] as String?;
      final classIdsJson = row['class_ids'] as String?;
      final classIds = (jsonDecode(classIdsJson ?? '[]') as List<dynamic>).cast<String>();
      final contentJson = row['content'] as String?;
      final content = (jsonDecode(contentJson ?? '[]') as List<dynamic>).cast<Map<String, dynamic>>();
      final name = jsonEncode(content);

      return Node(
        id: 0,
        uuid: uuid,
        name: name,
        displayName: astToPlainText(name),
        icon: row['icon'] as String?,
        color: row['color'] as String?,
        parentUuid: row['parent_id'] as String?,
        sequence: sequenceByNode[uuid] ?? 0.0,
        isPage: kind == 'page',
        isTask: classIds.contains(SystemClassUuids.task),
        isDaily: classIds.contains(SystemClassUuids.day),
        isMonthly: classIds.contains(SystemClassUuids.month),
        isYearly: classIds.contains(SystemClassUuids.year),
        isTable: classIds.contains(SystemClassUuids.table),
        isAsset: classIds.contains(SystemClassUuids.asset),
        isComment: classIds.contains(SystemClassUuids.comment),
        isDeleted: false,
        isArchived: (row['active'] as int? ?? 1) == 0,
        classesUuid: classIds,
        properties: propertiesByNode[uuid] ?? const {},
        createDate: row['created_at'] as String?,
        writeDate: row['updated_at'] as String?,
      );
    }).toList();
  }

  /// Reads class rows from a server-derived snapshot database.
  Future<List<_ClassRow>> _readClassesFromSnapshotDatabase(Database db, String workspaceId) async {
    final rows = await db.query(
      'class',
      where: 'workspace_id = ? AND active = 1',
      whereArgs: [workspaceId],
      orderBy: 'name ASC',
    );
    return rows.map((row) {
      final extendsRaw = row['extends_class_ids'] as String?;
      List<String> extendsUuids;
      try {
        extendsUuids = (jsonDecode(extendsRaw ?? '[]') as List<dynamic>).cast<String>();
      } catch (_) {
        extendsUuids = const [];
      }
      return _ClassRow(
        uuid: row['id'] as String,
        name: _normalizeClassName(row['name'] as String?),
        icon: row['icon'] as String?,
        color: row['color'] as String?,
        description: row['description'] as String?,
        extendsUuids: extendsUuids,
        active: (row['active'] as int? ?? 1) == 1,
        createdAt: row['created_at'] as String?,
        updatedAt: row['updated_at'] as String?,
      );
    }).toList();
  }

  /// Reads property-schema rows from a server-derived snapshot database.
  Future<List<PropertySchemaRow>> _readPropertySchemasFromSnapshotDatabase(Database db, String workspaceId) async {
    final rows = await db.query(
      'property_schema',
      where: 'workspace_id = ? AND active = 1',
      whereArgs: [workspaceId],
    );
    return rows.map((row) {
      List<String> classFilterUuids;
      List<Map<String, dynamic>> options;
      Map<String, dynamic>? validationRules;
      dynamic defaultValue;
      try {
        classFilterUuids = (jsonDecode(row['class_filter_uuids'] as String? ?? '[]') as List<dynamic>).cast<String>();
      } catch (_) {
        classFilterUuids = const [];
      }
      try {
        options = (jsonDecode(row['options'] as String? ?? '[]') as List<dynamic>).cast<Map<String, dynamic>>();
      } catch (_) {
        options = const [];
      }
      try {
        final raw = row['validation_rules'] as String?;
        validationRules = raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
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
        uuid: row['id'] as String,
        workspaceId: row['workspace_id'] as String,
        name: row['name'] as String,
        icon: row['icon'] as String?,
        type: row['type'] as String? ?? 'text',
        multi: (row['multi'] as int? ?? 0) == 1,
        isSystem: (row['is_system'] as int? ?? 0) == 1,
        scope: row['scope'] as String? ?? 'global',
        nodeUuid: row['node_id'] as String?,
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
    }).toList();
  }

  /// Reads class-property-edge rows from a server-derived snapshot database.
  Future<List<ClassPropertyEdgeRow>> _readClassPropertyEdgesFromSnapshotDatabase(Database db, String workspaceId) async {
    final rows = await db.query(
      'class_property_edge',
      where: 'class_id IN (SELECT id FROM class WHERE workspace_id = ? AND active = 1)',
      whereArgs: [workspaceId],
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
        hidden: (row['hidden'] as int? ?? 0) == 1,
        required: row['required'] == null ? null : (row['required'] as int) == 1,
        readonly: row['readonly'] == null ? null : (row['readonly'] as int) == 1,
        hideWhenEmpty: row['hide_when_empty'] == null ? null : (row['hide_when_empty'] as int) == 1,
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
      where: 'is_page = 1 AND is_deleted = 0 AND is_archived = 0 AND is_daily = 0 AND is_monthly = 0 AND is_yearly = 0',
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
      where: 'is_page = 1 AND is_deleted = 0 AND is_archived = 0 AND parent_uuid IS NULL AND is_daily = 0 AND is_monthly = 0 AND is_yearly = 0',
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
    const hidden = <String>{
      SystemClassUuids.class_,
      SystemClassUuids.page,
    };
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
    await db.insert(
      'class_cache',
      {
        'uuid': uuid,
        'name': _normalizeClassName(name),
        'icon': icon,
        'color': color,
        'description': description,
        'extends_uuid': jsonEncode(extendsUuids ?? const <String>[]),
        'active': active ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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

  /// Direct children of [parentUuid].
  Future<List<Node>> getChildren(String parentUuid) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where: 'parent_uuid = ? AND is_deleted = 0 AND is_archived = 0',
      whereArgs: [parentUuid],
      orderBy: 'sequence ASC, synced_at DESC',
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
    );
    return PageContent(node: pageNode, linkedReferences: const []);
  }

  /// Properties currently stored on [uuid].
  Future<List<NodePropertyValue>> getNodeProperties(String uuid) async {
    final node = await getByUuid(uuid);
    if (node == null) return const [];
    final entries = <NodePropertyValue>[];
    for (final entry in node.properties.entries) {
      final schema = await getPropertySchema(entry.key);
      entries.add(NodePropertyValue(
        property: schema ?? _knownPropertySchemas[entry.key] ?? _genericProperty(entry.key),
        values: [entry.value],
      ));
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
  Future<List<Property>> getPropertySchemasForClasses(List<String> classUuids) async {
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
      final rows = await db.query('node_cache', columns: ['uuid'], where: 'is_deleted = 0 AND is_archived = 0');
      candidateUuids = rows.map((r) => r['uuid'] as String).toList();
    }

    final nodes = await getByUuids(candidateUuids);
    final filtered = nodes.where((n) => _matchesFilters(n, filters)).toList();
    _sortFiltered(filtered, filters);

    final start = (filters.page - 1) * filters.limit;
    if (start >= filtered.length) return const [];
    return filtered.sublist(start, (start + filters.limit).clamp(0, filtered.length));
  }

  // === Local search index ===

  // === Favorites ===

  // Favorites are keyed per actor, matching the server-side
  // `user_favorite(actor_id, node_id, workspace_id)` keying. A null [actorId]
  // means "no authenticated user is wired into sync yet" and reads/writes
  // fall back to workspace-scoped behavior (single-user installs).

  /// Favorite nodes for [workspaceId] in order.
  Future<List<Node>> getFavorites(String workspaceId, {int limit = 50, String? actorId}) async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT nc.payload
      FROM user_favorite uf
      INNER JOIN node_cache nc ON nc.uuid = uf.node_uuid
      WHERE uf.workspace_id = ? ${actorId != null ? 'AND uf.actor_id = ?' : ''}
        AND nc.is_deleted = 0 AND nc.is_archived = 0
      ORDER BY uf.position ASC, uf.updated_at DESC
      LIMIT ?
    ''', [workspaceId, ?actorId, limit]);
    return rows.map(_nodeFromRow).toList();
  }

  /// UUIDs of favorite nodes for [workspaceId] in order.
  Future<List<String>> getFavoriteUuids(String workspaceId, {String? actorId}) async {
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

  Future<void> addFavorite(String workspaceId, String nodeUuid, {String? actorId}) async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT COALESCE(MAX(position), -1) AS pos
      FROM user_favorite
      WHERE workspace_id = ? AND actor_id = ?
    ''', [workspaceId, actorId ?? '']);
    final pos = (rows.first['pos'] as int? ?? -1) + 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'user_favorite',
      {
        'workspace_id': workspaceId,
        'actor_id': actorId ?? '',
        'node_uuid': nodeUuid,
        'position': pos,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> removeFavorite(String workspaceId, String nodeUuid, {String? actorId}) async {
    final db = await _database.database;
    await db.delete(
      'user_favorite',
      where: actorId != null
          ? 'workspace_id = ? AND actor_id = ? AND node_uuid = ?'
          : 'workspace_id = ? AND node_uuid = ?',
      whereArgs: [workspaceId, ?actorId, nodeUuid],
    );
  }

  Future<void> reorderFavorites(String workspaceId, List<String> nodeUuids, {String? actorId}) async {
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
        where: 'workspace_id = ? AND actor_id = ? AND node_uuid NOT IN (${nodeUuids.map((_) => '?').join(',')})',
        whereArgs: [workspaceId, actor, ...nodeUuids],
      );
      for (var i = 0; i < nodeUuids.length; i++) {
        await txn.insert(
          'user_favorite',
          {
            'workspace_id': workspaceId,
            'actor_id': actor,
            'node_uuid': nodeUuids[i],
            'position': i,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Applies a `user.favorite.add` operation to the local derived state.
  Future<void> applyFavoriteAdd(String workspaceId, String actorId, String nodeUuid) async {
    await addFavorite(workspaceId, nodeUuid, actorId: actorId);
  }

  /// Applies a `user.favorite.remove` operation to the local derived state.
  Future<void> applyFavoriteRemove(String workspaceId, String actorId, String nodeUuid) async {
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
    await db.insert(
      'task_completion',
      {
        'completion_id': completionId,
        'node_uuid': nodeUuid,
        'completed_at': completedAt,
        'scheduled_date': scheduledDate,
        'deadline_date': deadlineDate,
        'status': status,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Deletes a task completion from the local derived state.
  Future<void> deleteTaskCompletion(String nodeUuid, String completionId) async {
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
    await db.insert(
      'node_content_hlc',
      {
        'node_uuid': uuid,
        'hlc_physical': hlc.physical,
        'hlc_logical': hlc.logical,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
    final rows = await db.rawQuery('''
      SELECT si.node_uuid, SUM(si.rank) as score
      FROM search_index si
      INNER JOIN node_cache nc ON nc.uuid = si.node_uuid
      WHERE si.term IN ($placeholders) AND nc.is_deleted = 0 AND nc.is_archived = 0
      GROUP BY si.node_uuid
      ORDER BY score DESC
      LIMIT ?
    ''', [...terms, limit]);

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
    final indexRows = await db.rawQuery('SELECT COUNT(*) as count FROM search_index');
    final cacheRows = await db.rawQuery('SELECT COUNT(*) as count FROM node_cache');
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
      final dateStr = node.properties[SystemPropertyUuids.taskDeadline] as String?;
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
        nodes.sort((a, b) => orderFactor * a.displayName.compareTo(b.displayName));
      case SortBy.writeDate:
        nodes.sort((a, b) => orderFactor * _compareDates(a.writeDate, b.writeDate));
      case SortBy.createDate:
        nodes.sort((a, b) => orderFactor * _compareDates(a.createDate, b.createDate));
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
      .map((e) => SelectionOption(
            id: e.key,
            uuid: const Uuid().v5(Namespace.url.value, 'notees:task-status:${e.value}'),
            name: e.value,
          ))
      .toList();

  static final List<SelectionOption> _taskPriorityOptions = const [
    'Low',
    'Medium',
    'High',
    'Urgent',
  ]
      .asMap()
      .entries
      .map((e) => SelectionOption(
            id: e.key,
            uuid: const Uuid().v5(Namespace.url.value, 'notees:task-priority:${e.value}'),
            name: e.value,
          ))
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
      classFilterUuids = (jsonDecode(row['class_filter_uuids'] as String? ?? '[]') as List<dynamic>).cast<String>();
    } catch (_) {
      classFilterUuids = const [];
    }
    try {
      options = (jsonDecode(row['options'] as String? ?? '[]') as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) {
      options = const [];
    }
    try {
      final raw = row['validation_rules'] as String?;
      validationRules = raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
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
      'validation_rules': schema.validationRules == null ? null : jsonEncode(schema.validationRules),
      'required': schema.required ? 1 : 0,
      'readonly': schema.readonly ? 1 : 0,
      'hide_when_empty': schema.hideWhenEmpty ? 1 : 0,
      'default_value': schema.defaultValue == null ? null : jsonEncode(schema.defaultValue),
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
      options = ((jsonDecode(row['options'] as String? ?? '[]') as List<dynamic>?) ?? const [])
          .map((e) => _selectionOptionFromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      options = const [];
    }
    try {
      classFilters = (jsonDecode(row['class_filter_uuids'] as String? ?? '[]') as List<dynamic>)
          .map((e) => e.toString())
          .toList();
    } catch (_) {
      classFilters = const [];
    }
    try {
      final raw = row['validation_rules'] as String?;
      validationRules = raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
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
    final uuid = (json['uuid'] as String?) ??
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
      'default_value': edge.defaultValue == null ? null : jsonEncode(edge.defaultValue),
      'hidden': edge.hidden ? 1 : 0,
      'required': edge.required == null ? null : (edge.required! ? 1 : 0),
      'readonly': edge.readonly == null ? null : (edge.readonly! ? 1 : 0),
      'hide_when_empty': edge.hideWhenEmpty == null ? null : (edge.hideWhenEmpty! ? 1 : 0),
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

  Future<void> deleteClassPropertyEdge(String classUuid, String propertyUuid) async {
    final db = await _database.database;
    await db.delete(
      'class_property_edge',
      where: 'class_uuid = ? AND property_uuid = ?',
      whereArgs: [classUuid, propertyUuid],
    );
  }

  Future<void> reorderClassPropertyEdges(String classUuid, List<String> orderedPropertyUuids) async {
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
