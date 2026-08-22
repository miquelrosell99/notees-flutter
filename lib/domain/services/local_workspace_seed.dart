import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../models/relay/operation_payloads.dart';
import 'sync_v2_service.dart';

/// Client-side local workspace seed for offline (serverless) mode.
///
/// Mirrors the web client's `frontend/src/core/seed.ts` and the server seed
/// in `app/core/seed.py` (`seed_workspace_relay`): emits `class.create` +
/// `node.updateContent` (class name content) for every system class, then
/// `node.create` for the Inbox and the user's personal page (scratchpad).
///
/// Ops go through the normal outbox/applier path ([SyncV2Service.emitLocal]),
/// so the local derived state matches what a server-seeded workspace would
/// produce, and the ops stay in the outbox to be pushed if a server is
/// attached later.
class LocalWorkspaceSeed {
  LocalWorkspaceSeed(this._sync);

  final SyncV2Service _sync;

  /// Class name → fixed system class UUID. Matches `SYSTEM_CLASS_UUIDS` in
  /// `frontend/src/constants/systemProperties.ts` (the obsolete `page` class
  /// is not seeded; page status derives from the node kind).
  static const Map<String, String> systemClassNames = {
    'class': SystemClassUuids.class_,
    'year': SystemClassUuids.year,
    'month': SystemClassUuids.month,
    'day': SystemClassUuids.day,
    'quote': SystemClassUuids.quote,
    'query': SystemClassUuids.query,
    'code': SystemClassUuids.code,
    'asset': SystemClassUuids.asset,
    'whiteboard': SystemClassUuids.whiteboard,
    'card': SystemClassUuids.card,
    'task': SystemClassUuids.task,
    'template': SystemClassUuids.template,
    'comment': SystemClassUuids.comment,
    'table': SystemClassUuids.table,
    'warning': SystemClassUuids.warning,
    'note': SystemClassUuids.note,
    'tip': SystemClassUuids.tip,
    'info': SystemClassUuids.info,
    'danger': SystemClassUuids.danger,
    'success': SystemClassUuids.success,
    'cloze': SystemClassUuids.cloze,
  };

  /// Seeds missing system classes and default pages, idempotently.
  ///
  /// Entries that already exist in the local store (e.g. a previously seeded
  /// or server-synced workspace) are skipped, so re-running emits nothing.
  /// Returns the number of seed operations emitted (0 when already seeded).
  Future<int> ensureLocalWorkspace({required String displayName}) async {
    var emitted = 0;

    for (final entry in systemClassNames.entries) {
      final classId = entry.value;
      if (await _sync.cache.getClassByUuid(classId) != null) continue;
      await _sync.emitLocal(
        opType: 'class.create',
        payload: OperationPayloads.classCreate(classId: classId, name: entry.key),
        affectedNodeIds: [classId],
      );
      await _sync.emitLocal(
        opType: 'node.updateContent',
        payload: OperationPayloads.nodeUpdateContent(
          nodeId: classId,
          content: AstBuilder.parseInline(entry.key),
        ),
        affectedNodeIds: [classId],
      );
      emitted += 2;
    }

    final pages = <String, String>{
      'Inbox': SystemPageUuids.inbox,
      displayName: SystemPageUuids.scratchpad,
    };
    for (final entry in pages.entries) {
      final pageId = entry.value;
      if (await _sync.cache.getByUuid(pageId) != null) continue;
      await _sync.emitLocal(
        opType: 'node.create',
        payload: OperationPayloads.nodeCreate(
          nodeId: pageId,
          kind: 'page',
          initialContent: AstBuilder.parseInline(entry.key),
        ),
        affectedNodeIds: [pageId],
      );
      emitted += 1;
    }

    return emitted;
  }
}
