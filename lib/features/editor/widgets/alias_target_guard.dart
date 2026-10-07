import '../../../data/models/node.dart';

/// Client-side write guard for the `aliasedNodeId` field (SCHEMA.md "Node
/// aliases" — the web's `aliasedNodeTargetError`): the target must render
/// as a PAGE (the pickers offer pages only; this guard is the
/// enforcement), must not be the carrier itself (a self-alias is a
/// write-time cycle — the applier would fail it loud), and must not
/// already BE an alias (picking one would silently repoint its chain).
/// Returns the visible error message, or null when the pick is writable.
/// Nothing else validates — raw op writers are not policed, and the
/// applier's cycle check remains the final authority.
String? aliasTargetError(Node picked, {required String carrierUuid}) {
  if (!picked.isPage) return 'The aliased node must be a page.';
  if (picked.uuid == carrierUuid) return 'A page cannot alias itself.';
  if (picked.aliasedNodeId != null) return 'That page is already an alias.';
  return null;
}
