import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/ast_builder.dart';
import '../../data/repositories/node_repository.dart';
import '../models/editor_block_snapshot.dart';
import 'sync_v2_service.dart';

/// Persists a page edit by updating the title, batch-updating existing blocks,
/// creating new blocks level-by-level, and deleting removed blocks.
class EditorSaveService {
  EditorSaveService({
    required this.dio,
    this.syncService,
  });

  final Dio dio;
  final SyncV2Service? syncService;

  Future<void> savePage({
    required String pageUuid,
    required String title,
    required List<EditorBlockSnapshot> roots,
    required List<String> deletedUuids,
  }) async {
    if (syncService != null) {
      await _savePageViaOutbox(
        pageUuid: pageUuid,
        title: title,
        roots: roots,
        deletedUuids: deletedUuids,
      );
      return;
    }

    final repo = NodeRepository(dio: dio, syncService: syncService);

    final titleAst = AstBuilder.serialize(AstBuilder.parseInline(title));
    await repo.updateNode(pageUuid, name: titleAst);

    final updates = <Map<String, dynamic>>[];
    _collectUpdates(roots, pageUuid, updates, parentUuid: null);
    if (updates.isNotEmpty) {
      await repo.batchUpdateNodes(updates);
    }

    await _createNewNodesLevelByLevel(repo, pageUuid, roots);

    for (final uuid in deletedUuids) {
      await repo.deleteNode(uuid);
    }
  }

  Future<void> _savePageViaOutbox({
    required String pageUuid,
    required String title,
    required List<EditorBlockSnapshot> roots,
    required List<String> deletedUuids,
  }) async {
    final service = syncService!;

    // Update page title.
    await service.enqueue(
      type: 'update_content',
      nodeUuid: pageUuid,
      contentAst: AstBuilder.parseInline(title),
    );

    // Update existing blocks and create new blocks.
    final (preparedRoots, newUuids) = _assignUuids(roots);
    await _enqueueBlockOps(
      service,
      preparedRoots,
      pageUuid,
      newUuids: newUuids,
      parentUuid: null,
    );

    // Delete removed blocks.
    for (final uuid in deletedUuids) {
      await service.enqueue(type: 'delete', nodeUuid: uuid);
    }

    await service.flush();
  }

  /// Returns a deep copy of [roots] where every block with an empty UUID gets
  /// a freshly generated UUIDv7, plus a set of those newly generated UUIDs.
  (List<EditorBlockSnapshot>, Set<String>) _assignUuids(List<EditorBlockSnapshot> roots) {
    final newUuids = <String>{};
    EditorBlockSnapshot assign(EditorBlockSnapshot node) {
      if (node.uuid.isEmpty) {
        final uuid = const Uuid().v7();
        newUuids.add(uuid);
        return EditorBlockSnapshot(
          uuid: uuid,
          text: node.text,
          parentUuid: node.parentUuid,
          children: node.children.map(assign).toList(),
        );
      }
      return EditorBlockSnapshot(
        uuid: node.uuid,
        text: node.text,
        parentUuid: node.parentUuid,
        children: node.children.map(assign).toList(),
      );
    }

    return (roots.map(assign).toList(), newUuids);
  }

  Future<void> _enqueueBlockOps(
    SyncV2Service service,
    List<EditorBlockSnapshot> nodes,
    String pageUuid, {
    required Set<String> newUuids,
    required String? parentUuid,
  }) async {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final effectiveParent = parentUuid ?? pageUuid;
      if (node.uuid.isEmpty) continue; // Should not happen after _assignUuids.

      if (newUuids.contains(node.uuid)) {
        await service.enqueue(
          type: 'create',
          nodeUuid: node.uuid,
          parentUuid: effectiveParent,
          contentAst: AstBuilder.parseInline(node.text),
        );
      } else {
        await service.enqueue(
          type: 'update_content',
          nodeUuid: node.uuid,
          contentAst: AstBuilder.parseInline(node.text),
        );
        if (node.parentUuid != null && node.parentUuid != effectiveParent) {
          await service.enqueue(
            type: 'move',
            nodeUuid: node.uuid,
            parentUuid: effectiveParent,
          );
        }
      }

      await _enqueueBlockOps(service, node.children, pageUuid, newUuids: newUuids, parentUuid: node.uuid);
    }
  }

  void _collectUpdates(
    List<EditorBlockSnapshot> nodes,
    String pageUuid,
    List<Map<String, dynamic>> updates, {
    required String? parentUuid,
  }) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node.uuid.isNotEmpty) {
        updates.add({
          'uuid': node.uuid,
          'name': AstBuilder.serialize(AstBuilder.parseInline(node.text)),
          'sequence': i.toDouble(),
          'parent_uuid': parentUuid ?? pageUuid,
        });
      }

      _collectUpdates(
        node.children,
        pageUuid,
        updates,
        parentUuid: node.uuid.isNotEmpty ? node.uuid : parentUuid,
      );
    }
  }

  Future<void> _createNewNodesLevelByLevel(
    NodeRepository repo,
    String pageUuid,
    List<EditorBlockSnapshot> roots,
  ) async {
    final uuidMap = <EditorBlockSnapshot, String>{};

    var currentLevel = roots.where((n) => n.uuid.isEmpty).toList();
    while (currentLevel.isNotEmpty) {
      final nextLevel = <EditorBlockSnapshot>[];
      final creates = <Map<String, dynamic>>[];

      for (final node in currentLevel) {
        final parent = _parentOf(node, roots);
        final parentUuid = parent == null
            ? pageUuid
            : (uuidMap[parent] ?? pageUuid);
        final siblings = parent?.children ?? roots;
        final index = siblings.indexOf(node);

        creates.add({
          'parent_uuid': parentUuid,
          'name': AstBuilder.serialize(AstBuilder.parseInline(node.text)),
          'sequence': index.toDouble(),
        });
      }

      final results = await repo.batchCreateNodes(creates);
      for (var i = 0; i < currentLevel.length; i++) {
        final node = currentLevel[i];
        if (i < results.length) {
          uuidMap[node] = results[i].uuid;
        }
        nextLevel.addAll(node.children.where((c) => c.uuid.isEmpty));
      }

      currentLevel = nextLevel;
    }
  }

  EditorBlockSnapshot? _parentOf(
    EditorBlockSnapshot target,
    List<EditorBlockSnapshot> roots,
  ) {
    for (final root in roots) {
      if (root.children.contains(target)) return root;
      final found = _parentOf(target, root.children);
      if (found != null) return found;
    }
    return null;
  }
}
