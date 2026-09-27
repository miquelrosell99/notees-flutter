import 'package:uuid/uuid.dart';

import '../../core/utils/ast_builder.dart';
import '../models/editor_block_snapshot.dart';
import './sync_v2_service.dart';

/// Persists a page edit by updating the title and enqueueing sync operations
/// for existing, new, and deleted blocks.
class EditorSaveService {
  EditorSaveService({
    required this.syncService,
  });

  final SyncV2Service syncService;

  Future<void> savePage({
    required String pageUuid,
    required String title,
    required List<EditorBlockSnapshot> roots,
    required List<String> deletedUuids,
  }) async {
    // Update the page title: v2 carries it in the scalar `name` slot
    // (object.update name:), separate from the content token stream.
    await syncService.enqueue(
      type: 'update_node',
      nodeUuid: pageUuid,
      name: title,
    );

    // Update existing blocks and create new blocks.
    final (preparedRoots, newUuids) = _assignUuids(roots);
    await _enqueueBlockOps(
      syncService,
      preparedRoots,
      pageUuid,
      newUuids: newUuids,
      parentUuid: null,
    );

    // Delete removed blocks.
    for (final uuid in deletedUuids) {
      await syncService.enqueue(type: 'delete', nodeUuid: uuid);
    }

    await syncService.flush();
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

      // Emit the sibling position so the server's `node_child_order` reflects
      // the editor order (new children previously all defaulted to '0').
      if (newUuids.contains(node.uuid)) {
        await service.enqueue(
          type: 'create',
          nodeUuid: node.uuid,
          parentUuid: effectiveParent,
          newIndex: i,
          contentAst: AstBuilder.parseInline(node.text),
        );
      } else {
        await service.enqueue(
          type: 'update_content',
          nodeUuid: node.uuid,
          contentAst: AstBuilder.parseInline(node.text),
        );
        if (node.parentUuid != null && node.parentUuid != effectiveParent) {
          // v2 move orders siblings by parentId + afterId (the previous
          // sibling is the anchor the editor already knows).
          final afterUuid = i > 0 ? nodes[i - 1].uuid : null;
          await service.enqueue(
            type: 'move',
            nodeUuid: node.uuid,
            parentUuid: effectiveParent,
            afterUuid: afterUuid,
          );
        }
      }

      await _enqueueBlockOps(service, node.children, pageUuid, newUuids: newUuids, parentUuid: node.uuid);
    }
  }
}
