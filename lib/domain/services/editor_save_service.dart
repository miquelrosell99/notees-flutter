import 'package:dio/dio.dart';

import '../../core/utils/ast_builder.dart';
import '../../data/repositories/node_repository.dart';
import '../models/editor_block_snapshot.dart';

/// Persists a page edit by updating the title, batch-updating existing blocks,
/// creating new blocks level-by-level, and deleting removed blocks.
class EditorSaveService {
  EditorSaveService({required this.dio});

  final Dio dio;

  Future<void> savePage({
    required String pageUuid,
    required String title,
    required List<EditorBlockSnapshot> roots,
    required List<String> deletedUuids,
  }) async {
    final repo = NodeRepository(dio: dio);

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
