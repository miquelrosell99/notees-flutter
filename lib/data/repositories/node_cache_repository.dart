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
import '../../domain/models/search_filters.dart';

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
      final db = await _database.database;
      await db.transaction((txn) async {
        await txn.delete('node_cache');
        await txn.delete('search_index');
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
        await _indexNodesInTxn(txn, nodes.where((n) => !n.isDeleted).toList());
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
        isPage: kind == 'page' || classIds.contains(SystemClassUuids.page),
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

  // === Local read queries used when the relay sync service is active ===

  /// Recently touched pages, newest first. Excludes daily journal date pages,
  /// which live in the dedicated Journals section.
  Future<List<Node>> getRecentPages({int limit = 10}) async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where: 'is_page = 1 AND is_deleted = 0 AND is_archived = 0 AND is_daily = 0',
      orderBy: "COALESCE(write_date, '') DESC, synced_at DESC",
      limit: limit,
    );
    return rows.map(_nodeFromRow).toList();
  }

  /// Top-level pages with no parent. Excludes daily journal date pages.
  Future<List<Node>> getRootPages() async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where: 'is_page = 1 AND is_deleted = 0 AND is_archived = 0 AND parent_uuid IS NULL AND is_daily = 0',
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

  /// Class/tag nodes (nodes whose class list contains the system "class" UUID).
  Future<List<Node>> getClasses() async {
    final db = await _database.database;
    final rows = await db.query(
      'node_cache',
      where: 'is_deleted = 0 AND is_archived = 0 AND classes_uuid LIKE ?',
      whereArgs: ['%${SystemClassUuids.class_}%'],
      orderBy: "COALESCE(write_date, '') DESC",
    );
    return rows.map(_nodeFromRow).toList();
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

  /// Counts non-deleted comments attached to [parentUuid].
  Future<int> countComments(String parentUuid) async {
    final db = await _database.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM node_cache '
      'WHERE parent_uuid = ? AND is_comment = 1 AND is_deleted = 0 AND is_archived = 0',
      [parentUuid],
    );
    final count = result.firstOrNull?['count'];
    return (count is int ? count : int.tryParse(count.toString()) ?? 0);
  }

  /// Deleted nodes.
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
    return node.properties.entries.map((e) {
      final schema = _knownPropertySchemas[e.key];
      return NodePropertyValue(
        property: schema ?? _genericProperty(e.key),
        values: [e.value],
      );
    }).toList();
  }

  /// Best-effort available properties for a node.
  ///
  /// For task nodes this returns the hard-coded task status/deadline/scheduled/
  /// priority schemas so the UI can toggle status and set due dates even when
  /// the server has not yet sent property-schema operations.
  Future<List<Property>> getAvailableProperties(String uuid) async {
    final node = await getByUuid(uuid);
    if (node == null) return const [];
    if (node.isTask) return _taskProperties;
    return const [];
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

  /// Favorite nodes for [workspaceId] in order.
  Future<List<Node>> getFavorites(String workspaceId, {int limit = 50}) async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT nc.payload
      FROM user_favorite uf
      INNER JOIN node_cache nc ON nc.uuid = uf.node_uuid
      WHERE uf.workspace_id = ? AND nc.is_deleted = 0 AND nc.is_archived = 0
      ORDER BY uf.position ASC, uf.updated_at DESC
      LIMIT ?
    ''', [workspaceId, limit]);
    return rows.map(_nodeFromRow).toList();
  }

  /// UUIDs of favorite nodes for [workspaceId] in order.
  Future<List<String>> getFavoriteUuids(String workspaceId) async {
    final db = await _database.database;
    final rows = await db.query(
      'user_favorite',
      columns: ['node_uuid'],
      where: 'workspace_id = ?',
      whereArgs: [workspaceId],
      orderBy: 'position ASC, updated_at DESC',
    );
    return rows.map((r) => r['node_uuid'] as String).toList();
  }

  Future<void> addFavorite(String workspaceId, String nodeUuid) async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT COALESCE(MAX(position), -1) AS pos
      FROM user_favorite
      WHERE workspace_id = ?
    ''', [workspaceId]);
    final pos = (rows.first['pos'] as int? ?? -1) + 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'user_favorite',
      {
        'workspace_id': workspaceId,
        'node_uuid': nodeUuid,
        'position': pos,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> removeFavorite(String workspaceId, String nodeUuid) async {
    final db = await _database.database;
    await db.delete(
      'user_favorite',
      where: 'workspace_id = ? AND node_uuid = ?',
      whereArgs: [workspaceId, nodeUuid],
    );
  }

  Future<void> reorderFavorites(String workspaceId, List<String> nodeUuids) async {
    final db = await _database.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.delete(
        'user_favorite',
        where: 'workspace_id = ? AND node_uuid NOT IN (${nodeUuids.map((_) => '?').join(',')})',
        whereArgs: [workspaceId, ...nodeUuids],
      );
      for (var i = 0; i < nodeUuids.length; i++) {
        await txn.insert(
          'user_favorite',
          {
            'workspace_id': workspaceId,
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
    await addFavorite(workspaceId, nodeUuid);
  }

  /// Applies a `user.favorite.remove` operation to the local derived state.
  Future<void> applyFavoriteRemove(String workspaceId, String actorId, String nodeUuid) async {
    await removeFavorite(workspaceId, nodeUuid);
  }

  /// Applies a `user.favorite.reorder` operation to the local derived state.
  Future<void> applyFavoriteReorder(
    String workspaceId,
    String actorId,
    List<String> nodeUuids,
  ) async {
    await reorderFavorites(workspaceId, nodeUuids);
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
    switch (filters.nodeType) {
      case NodeType.page:
        if (!node.isPage) return false;
      case NodeType.task:
        if (!node.isTask) return false;
      case NodeType.journal:
        if (!node.isDaily && !node.isMonthly && !node.isYearly) return false;
      case NodeType.any:
        break;
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
      name: 'Property',
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
}
