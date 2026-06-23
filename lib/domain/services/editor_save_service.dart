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
    required int pageId,
    required String title,
    required List<EditorBlockSnapshot> roots,
    required List<int> deletedIds,
  }) async {
    final repo = NodeRepository(dio: dio);

    final titleAst = AstBuilder.serialize(AstBuilder.parseInline(title));
    await repo.updateNode(pageId, name: titleAst);

    final updates = <Map<String, dynamic>>[];
    _collectUpdates(roots, pageId, updates, parentId: null);
    if (updates.isNotEmpty) {
      await repo.batchUpdateNodes(updates);
    }

    await _createNewNodesLevelByLevel(repo, pageId, roots);

    for (final id in deletedIds) {
      await repo.deleteNode(id);
    }
  }

  void _collectUpdates(
    List<EditorBlockSnapshot> nodes,
    int pageId,
    List<Map<String, dynamic>> updates, {
    required int? parentId,
  }) {
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node.id > 0) {
        updates.add({
          'id': node.id,
          'name': AstBuilder.serialize(AstBuilder.parseInline(node.text)),
          'sequence': i.toDouble(),
          'parent_id': parentId ?? pageId,
        });
      }

      _collectUpdates(
        node.children,
        pageId,
        updates,
        parentId: node.id > 0 ? node.id : parentId,
      );
    }
  }

  Future<void> _createNewNodesLevelByLevel(
    NodeRepository repo,
    int pageId,
    List<EditorBlockSnapshot> roots,
  ) async {
    final idMap = <EditorBlockSnapshot, int>{};

    var currentLevel = roots.where((n) => n.id == 0).toList();
    while (currentLevel.isNotEmpty) {
      final nextLevel = <EditorBlockSnapshot>[];
      final creates = <Map<String, dynamic>>[];

      for (final node in currentLevel) {
        final parent = _parentOf(node, roots);
        final parentId = parent == null
            ? pageId
            : (idMap[parent] ?? pageId);
        final siblings = parent?.children ?? roots;
        final index = siblings.indexOf(node);

        creates.add({
          'parent_id': parentId,
          'name': AstBuilder.serialize(AstBuilder.parseInline(node.text)),
          'sequence': index.toDouble(),
        });
      }

      final results = await repo.batchCreateNodes(creates);
      for (var i = 0; i < currentLevel.length; i++) {
        final node = currentLevel[i];
        if (i < results.length) {
          idMap[node] = results[i].id;
        }
        nextLevel.addAll(node.children.where((c) => c.id == 0));
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
