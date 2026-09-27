/// Typed errors for the relay-v2 derived-state appliers, ported from
/// `v2/packages/store/src/errors.ts`. Appliers fail loud: constraint
/// violations, move-guard breaches, extends cycles, and unsupported wire
/// carriers surface as dedicated types instead of silent drops, so the sync
/// service can quarantine with a typed reason and rolls back by not
/// consuming the envelope id.
class StoreError implements Exception {
  const StoreError(this.message, [this.opType]);

  final String message;
  final String? opType;

  @override
  String toString() =>
      'StoreError${opType != null ? '($opType)' : ''}: $message';
}

/// Envelope or payload failed protocol validation before application.
class EnvelopeValidationError extends StoreError {
  const EnvelopeValidationError(super.message, [super.opType]);
}

/// A placement CHECK rejected a write (bullet-proof schema): a block can
/// never be parentless; a class is always tree-external.
class CheckConstraintError extends StoreError {
  const CheckConstraintError(super.message, [this.constraint, super.opType]);

  final String? constraint;
}

/// Cross-row tree guard: a class node can never be a parent, and a node may
/// never move under itself or its own descendant.
class MoveGuardError extends StoreError {
  const MoveGuardError(super.message, [super.opType]);
}

/// class.setExtends would introduce a cycle in the extends chain (self-parent
/// or multi-hop).
class CycleError extends StoreError {
  const CycleError(super.message, [super.opType]);
}

/// object.update arrived with the canonical CRDT wire carrier
/// (contentDeltaB64) but no readable contentAst mirror. The Yjs port is M1+
/// work; until it lands this carrier cannot be interpreted, so the applier
/// fails loud rather than dropping a write silently.
class UnsupportedCarrierError extends StoreError {
  const UnsupportedCarrierError(super.message, [super.opType]);
}

/// Referenced row (node/parent/class) does not exist in the derived state.
class NodeNotFoundError extends StoreError {
  const NodeNotFoundError(super.message, [super.opType]);
}
