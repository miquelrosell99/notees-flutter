/// The condition model of the filter block builder — a faithful Dart port
/// of the web's `apps/web/src/features/collection/filterBlockModel.ts`: the
/// Odoo register ([family][operator][value][target mode]) as pure functions
/// over the v2 draft query AST: the family a condition belongs to, the
/// operator column's options per family (adapting to the selected property
/// schema), the operator's current value (+ its negation), and the
/// operator-application morphs (the picked ids / values / timestamps carry
/// across them).
///
/// v2 shape: the operator column maps onto the member family's orthogonal
/// axes — a membership label flips ONLY `condition.op` between "in" and
/// "not-in" (the target rides verbatim — the mode axis is never touched by
/// an operator choice); the set bits re-materialize the condition as
/// `op: "exists"` / `op: "not-exists"` (no target at all). NOT-wraps remain
/// only where the register sugar predates the wire ops: the content/
/// property/date negatives, the isClass/isEmbedded polarity (the boolean
/// value is the independent other axis), and the wire-field "is not set".
library;

import 'builder_facts.dart';
import 'query_ast.dart';
import 'query_filter_query.dart';

// --- the block -----------------------------------------------------------------

/// A block's view of a child: a single condition, or a NOT wrapping one (the
/// content/property/date negatives, the isClass/isEmbedded polarity, and the
/// wire-field "is not set" are sugar over a not-wrap, so the draft AST
/// carries them verbatim and the row renders them as an operator choice).
/// NOT-around-a-GROUP stays a group wrapper, never a block.
({bool negated, Condition condition})? blockView(QueryAstChild child) {
  if (child is Not) {
    final inner = child.child;
    if (inner is Group) return null;
    if (inner is Condition) return (negated: true, condition: inner);
    return null;
  }
  if (child is Group) return null;
  if (child is Condition) return (negated: false, condition: child);
  return null;
}

/// The family a condition belongs to (the block TYPE column's value). The
/// v2 member condition maps to its wire family; `name` joins `content` (the
/// title register — the builder never authors it, but DSL-parsed ASTs can
/// carry it in).
String familyOf(Condition condition) {
  switch (condition) {
    case MemberCondition():
      return condition.family == MemberFamilies.class_
          ? ConditionKinds.class_
          : condition.family;
    case ContentCondition():
    case NameCondition():
      return ConditionKinds.content;
    case PropertyCondition():
      return ConditionKinds.property;
    case DateCondition():
      return condition.field == 'created'
          ? ConditionKinds.created
          : ConditionKinds.edited;
    case NodeFieldCondition():
      return switch (condition.field) {
        NodeFieldFields.coverAsset => ConditionKinds.cover,
        NodeFieldFields.bannerAsset => ConditionKinds.banner,
        NodeFieldFields.aliasedNode => ConditionKinds.alias,
        NodeFieldFields.isClass => ConditionKinds.type,
        _ => ConditionKinds.placement,
      };
  }
}

/// One operator-column option (value + label).
class OperatorOption {
  const OperatorOption(this.value, this.label);

  final String value;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is OperatorOption && other.value == value && other.label == label;

  @override
  int get hashCode => Object.hash(value, label);

  @override
  String toString() => 'OperatorOption($value, $label)';
}

/// The membership register per member family: the operator column's
/// positive and negative labels and whether the family offers the set bits.
/// Both positive labels map onto the SAME v2 op ("in" — v2 has no
/// single/list split on the wire); the canonical label is what
/// [operatorOf] reads back (the other is an offered alias that keeps the
/// condition verbatim).
class MemberRegister {
  const MemberRegister({
    required this.positives,
    required this.canonical,
    required this.negatives,
    required this.set,
  });

  final List<String> positives;
  final String canonical;
  final List<String> negatives;

  /// Whether the family offers the set bits (is set / is not set).
  final bool set;
}

const MemberRegister _classRegister = MemberRegister(
  positives: ['is', 'contains'],
  canonical: 'contains',
  negatives: ['not-contains', 'is-not'],
  set: true,
);

/// The membership register keyed by member family (the web's MEMBER_REGISTER).
MemberRegister memberRegisterOf(String family) => switch (family) {
      MemberFamilies.class_ => _classRegister,
      MemberFamilies.tags => const MemberRegister(
          positives: ['is'],
          canonical: 'is',
          negatives: ['is-not'],
          set: true,
        ),
      MemberFamilies.links => const MemberRegister(
          positives: ['is'],
          canonical: 'is',
          negatives: ['is-not'],
          set: true,
        ),
      MemberFamilies.referencePath => const MemberRegister(
          positives: ['is-any-of'],
          canonical: 'is-any-of',
          negatives: ['is-not-any-of'],
          set: false,
        ),
      MemberFamilies.parent => const MemberRegister(
          positives: ['is'],
          canonical: 'is',
          negatives: ['is-not'],
          set: true,
        ),
      MemberFamilies.child => const MemberRegister(
          positives: ['contains-any-of'],
          canonical: 'contains-any-of',
          negatives: ['not-contains-any-of'],
          set: true,
        ),
      MemberFamilies.childPath => const MemberRegister(
          positives: ['contains'],
          canonical: 'contains',
          negatives: ['not-contains'],
          set: true,
        ),
      MemberFamilies.page => const MemberRegister(
          positives: ['is'],
          canonical: 'is',
          negatives: ['is-not'],
          set: true,
        ),
      MemberFamilies.parentPath => const MemberRegister(
          positives: ['includes'],
          canonical: 'includes',
          negatives: ['not-includes'],
          set: true,
        ),
      _ => const MemberRegister(
          // root
          positives: ['is'],
          canonical: 'is',
          negatives: ['is-not'],
          set: false,
        ),
    };

/// The operator column's options per family (the Odoo operator sets). The
/// property family's list adapts to the SELECTED schema's type; the edited
/// family carries no set pair (created_at/updated_at are written at create
/// time — the options would lie).
List<OperatorOption> operatorOptions(
  String family,
  Condition? condition,
  BuilderFacts facts,
) {
  switch (family) {
    case ConditionKinds.class_:
      // The class set: BOTH class operators ride the extends-aware closure
      // membership — "is fuente" matches a node classed book when book
      // extends fuente. is / is not and contains / does not contain are the
      // SAME v2 wire op ("in" over the picked ids); is set / is not set test
      // the set's emptiness. (Exact set equality — the class member's
      // "exact" op — is legacy-wire-only: stored ASTs still parse/evaluate
      // it, the UI no longer binds it.)
      return const [
        OperatorOption('is', 'is'),
        OperatorOption('is-not', 'is not'),
        OperatorOption('contains', 'contains'),
        OperatorOption('not-contains', 'does not contain'),
        OperatorOption('set', 'is set'),
        OperatorOption('not-set', 'is not set'),
      ];
    case ConditionKinds.content:
      if (condition is NameCondition) {
        // A name row (the title register — enters via DSL parse / Raw-AST
        // paste): only the ops the name morph implements. starts/ends/fts
        // are content-only arms — offering them on a title row was a dead
        // choice (applyTextOperator silently kept the condition).
        return const [
          OperatorOption('is', 'is'),
          OperatorOption('is-not', 'is not'),
          OperatorOption('contains', 'contains'),
          OperatorOption('not-contains', 'does not contain'),
          OperatorOption('set', 'is set'),
          OperatorOption('not-set', 'is not set'),
        ];
      }
      // The text operator set: exact/equality, substring, edge-anchored,
      // full-text, and the emptiness bit.
      return const [
        OperatorOption('is', 'is'),
        OperatorOption('is-not', 'is not'),
        OperatorOption('contains', 'contains'),
        OperatorOption('not-contains', 'does not contain'),
        OperatorOption('starts', 'starts with'),
        OperatorOption('ends', 'ends with'),
        OperatorOption('fts', 'full-text'),
        OperatorOption('set', 'is set'),
        OperatorOption('not-set', 'is not set'),
      ];
    case ConditionKinds.tags:
    case ConditionKinds.links:
      // The link/tag families (the multi-value register): contains/does not
      // contain bind the LIST (ANY-of membership over the picked nodes).
      return const [
        OperatorOption('is', 'contains'),
        OperatorOption('is-not', 'does not contain'),
        OperatorOption('set', 'is set'),
        OperatorOption('not-set', 'is not set'),
      ];
    case ConditionKinds.referencePath:
      // The link-path rollup (containment folded in) over the picked nodes /
      // the subquery's matches / the host.
      return const [
        OperatorOption('is-any-of', 'contains'),
        OperatorOption('is-not-any-of', 'does not contain'),
      ];
    case ConditionKinds.parent:
      // The DIRECT PARENT is one node — is/is not bind the picked list (the
      // single-slot value control carries 0/1 elements), is set/is not set
      // the has-a-parent bit.
      return const [
        OperatorOption('is', 'is'),
        OperatorOption('is-not', 'is not'),
        OperatorOption('set', 'is set'),
        OperatorOption('not-set', 'is not set'),
      ];
    case ConditionKinds.child:
      // A DIRECT child is one of the picked nodes.
      return const [
        OperatorOption('contains-any-of', 'contains'),
        OperatorOption('not-contains-any-of', 'does not contain'),
        OperatorOption('set', 'is set'),
        OperatorOption('not-set', 'is not set'),
      ];
    case ConditionKinds.childPath:
      // The subtree contains any of the picked nodes anywhere down their
      // tree (the "contains" wording).
      return const [
        OperatorOption('contains', 'contains'),
        OperatorOption('not-contains', 'does not contain'),
        OperatorOption('set', 'is set'),
        OperatorOption('not-set', 'is not set'),
      ];
    case ConditionKinds.type:
    case ConditionKinds.placement:
      // The boolean rows ride a SINGLE value selector (the owner's register
      // ruling): the wire booleans are non-nullable, so is/is-not is
      // redundant with the value ("is not block" ≡ "is page"). No operator
      // column — the builder skips the dropdown when the list is empty.
      // Negatives stay reachable via group-level Exclude (NOT) and Raw AST.
      return const [];
    case ConditionKinds.page:
      // The CONTAINING PAGE is one node — is/is not bind the picked list,
      // is set/is not set the lives-inside-a-page bit.
      return const [
        OperatorOption('is', 'is'),
        OperatorOption('is-not', 'is not'),
        OperatorOption('set', 'is set'),
        OperatorOption('not-set', 'is not set'),
      ];
    case ConditionKinds.parentPath:
      // The ancestor chain contains any of the picked nodes (or the
      // subquery's matches / the host page).
      return const [
        OperatorOption('includes', 'contains'),
        OperatorOption('not-includes', 'does not contain'),
        OperatorOption('set', 'is set'),
        OperatorOption('not-set', 'is not set'),
      ];
    case ConditionKinds.root:
      // The workspace-root ancestor is one node — is/is not bind the picked
      // list. The set bit is vacuous — every node's root exists (a
      // parentless row is its own root).
      return const [
        OperatorOption('is', 'is'),
        OperatorOption('is-not', 'is not'),
      ];
    case ConditionKinds.property:
      return propertyOperatorOptions(condition, facts);
    case ConditionKinds.cover:
    case ConditionKinds.banner:
    case ConditionKinds.alias:
      return const [
        OperatorOption('exists', 'is set'),
        OperatorOption('not-exists', 'is not set'),
      ];
    case ConditionKinds.created:
    case ConditionKinds.edited:
      // The date operator set (Odoo's date list): day-granular equality, the
      // instant comparisons, the inclusive range, the relative period. The
      // set bits are deliberately absent — created_at/updated_at are written
      // at create time, so every row reads "set" (a lying control).
      return const [
        OperatorOption('is', 'is'),
        OperatorOption('is-not', 'is not'),
        OperatorOption('gt', '>'),
        OperatorOption('gte', '≥'),
        OperatorOption('lt', '<'),
        OperatorOption('lte', '≤'),
        OperatorOption('between', 'is between'),
        OperatorOption('within', 'is within'),
      ];
    default:
      return const [];
  }
}

/// The property family's operator list, adapted to the selected schema's
/// type.
List<OperatorOption> propertyOperatorOptions(
  Condition? condition,
  BuilderFacts facts,
) {
  final schemaId = condition is PropertyCondition ? condition.schemaId : '';
  final schema = facts.propertyById(schemaId);
  const set = [
    OperatorOption('set', 'is set'),
    OperatorOption('not-set', 'is not set'),
  ];
  switch (schema?.type) {
    case 'number':
    case 'integer':
      // Odoo's numeric list: =/!=/>/>=/</<=, the range, the substring ops.
      return const [
        OperatorOption('eq', '='),
        OperatorOption('neq', '≠'),
        OperatorOption('gt', '>'),
        OperatorOption('gte', '≥'),
        OperatorOption('lt', '<'),
        OperatorOption('lte', '≤'),
        OperatorOption('between', 'is between'),
        OperatorOption('contains', 'contains'),
        OperatorOption('not-contains', 'does not contain'),
        ...set,
      ];
    case 'datetime':
      // The date list: the comparisons, the range, the relative period.
      return const [
        OperatorOption('eq', '='),
        OperatorOption('neq', '≠'),
        OperatorOption('gt', '>'),
        OperatorOption('gte', '≥'),
        OperatorOption('lt', '<'),
        OperatorOption('lte', '≤'),
        OperatorOption('between', 'is between'),
        OperatorOption('within', 'is within'),
        ...set,
      ];
    case 'select':
      return const [
        OperatorOption('eq', 'is'),
        OperatorOption('neq', 'is not'),
        ...set,
      ];
    case 'boolean':
      // The value column is the true/false predicate; the operator column
      // carries ONLY the set bits (is-true ≡ is set + true — the ruling's
      // fold). The is-true/is-false morphs survive on applyOperator for
      // Raw-AST round-trips, unoffered here.
      return set;
    case 'object':
      // Node-typed: the value control is the anchored node picker.
      return const [
        OperatorOption('eq', 'is'),
        OperatorOption('neq', 'is not'),
        ...set,
      ];
    default:
      // Text and the rest: the text set.
      return const [
        OperatorOption('eq', 'is'),
        OperatorOption('neq', 'is not'),
        OperatorOption('contains', 'contains'),
        OperatorOption('not-contains', 'does not contain'),
        ...set,
      ];
  }
}

/// The operator column's current value for a condition (+ its negation).
String operatorOf(Condition condition, bool negated) {
  switch (condition) {
    case MemberCondition():
      final register = memberRegisterOf(condition.family);
      final op = condition.op;
      if (op == 'exact') {
        // Legacy-wire-only (exact set equality): rows still render their "is".
        return negated ? 'is-not' : 'is';
      }
      if (op == 'exists') return negated ? 'not-set' : 'set';
      if (op == 'not-exists') return negated ? 'set' : 'not-set';
      // in / not-in read the family's canonical membership label (the
      // single/list register collapsed onto the one wire op).
      return op == 'not-in'
          ? negated
              ? register.canonical
              : register.negatives.first
          : negated
              ? register.negatives.first
              : register.canonical;
    case ContentCondition():
    case NameCondition():
      final op = condition is ContentCondition
          ? condition.op
          : (condition as NameCondition).op;
      if (op == 'exists') return negated ? 'not-set' : 'set';
      if (op == 'fts') return 'fts';
      if (op == 'eq') return negated ? 'is-not' : 'is';
      if (op == 'starts') return 'starts';
      if (op == 'ends') return 'ends';
      return negated ? 'not-contains' : 'contains';
    case PropertyCondition():
      final op = condition.op;
      if (op == 'exists') return negated ? 'not-set' : 'set';
      if (op == 'between') return 'between';
      if (op == 'within') return 'within';
      // The boolean register folds the truth value into the VALUE column
      // (is-true ≡ set + true): the operator column reads the set axis only.
      if (op == 'eq' && condition.value is bool) {
        return negated ? 'not-set' : 'set';
      }
      // The scalar arms read the polarity too: a not-wrapped eq/contains
      // row renders its negative label (the content family's contract).
      if (op == 'eq') return negated ? 'neq' : 'eq';
      if (op == 'contains') return negated ? 'not-contains' : 'contains';
      return op;
    case DateCondition():
      final op = condition.op;
      if (op == 'eq') return negated ? 'is-not' : 'is';
      if (op == 'neq') return negated ? 'is' : 'is-not';
      return op;
    case NodeFieldCondition():
      if (condition.field == NodeFieldFields.isClass ||
          condition.field == NodeFieldFields.isEmbedded) {
        // The boolean axis rides the VALUE; polarity rides the not-wrap —
        // the operator column reads (and applies) ONLY the polarity, like
        // the content/property/date negatives and the set-bit arm below.
        return negated ? 'is-not' : 'is';
      }
      return negated ? 'not-exists' : 'exists';
  }
}

// --- the operator-application morphs ------------------------------------------

/// The member morph — the orthogonality law: an operator choice touches ONLY
/// the op axis. Positive labels → `op: "in"`, negative labels →
/// `op: "not-in"`, each carrying the target VERBATIM (an ids list, a nested
/// query, or the self marker — the mode survives every flip). The set bits
/// re-materialize the condition as `exists` / `not-exists` (the set shapes
/// carry no target); flipping back to a membership label re-materializes an
/// `in` over an empty ids pick.
QueryAstChild _applyMemberOperator(MemberCondition condition, String op) {
  final register = memberRegisterOf(condition.family);
  final carriedTarget = condition.target;
  final target = carriedTarget ?? const IdsTarget(ids: []);
  final inOp = condition.op == 'not-exists' ? 'not-in' : 'in';
  if (register.positives.contains(op)) {
    return MemberCondition(family: condition.family, op: inOp, target: target);
  }
  if (register.negatives.contains(op)) {
    return MemberCondition(
      family: condition.family,
      op: 'not-in',
      target: target,
    );
  }
  if (op == 'set') {
    return MemberCondition.exists(family: condition.family, op: 'exists');
  }
  if (op == 'not-set') {
    return MemberCondition.exists(family: condition.family, op: 'not-exists');
  }
  return condition;
}

/// The content/name morph: the text operator set + the emptiness bit.
QueryAstChild _applyTextOperator(Condition condition, String op) {
  final carried = switch (condition) {
    ContentCondition() => condition.value ?? '',
    NameCondition() => condition.value ?? '',
    _ => '',
  };
  Not neg(Condition next) => Not(child: next);
  Condition text(String textOp, String value) {
    if (condition is ContentCondition) {
      return ContentCondition(op: textOp, value: value);
    }
    // The title register carries only eq/neq/contains/exists — the edge/fts
    // arms are guarded into "contains" here (unreachable for name rows).
    return NameCondition(
      op: textOp == 'eq' ? 'eq' : 'contains',
      value: value,
    );
  }

  switch (op) {
    case 'is':
      return text('eq', carried);
    case 'is-not':
      return neg(text('eq', carried));
    case 'contains':
      return text('contains', carried);
    case 'not-contains':
      return neg(text('contains', carried));
    case 'starts':
      return condition is ContentCondition
          ? text('starts', carried)
          : condition;
    case 'ends':
      return condition is ContentCondition ? text('ends', carried) : condition;
    case 'fts':
      return condition is ContentCondition ? text('fts', carried) : condition;
    case 'set':
      if (condition is ContentCondition) {
        return const ContentCondition(op: 'exists');
      }
      return const NameCondition(op: 'exists');
    case 'not-set':
      if (condition is ContentCondition) {
        return neg(const ContentCondition(op: 'exists'));
      }
      return neg(const NameCondition(op: 'exists'));
    default:
      return condition;
  }
}

/// The date morph (created / edited): the field rides the condition (the
/// family only names WHICH date column); comparisons carry the timestamp,
/// the range carries it into `from`. The set bits are vacuous —
/// created_at/updated_at are written at create time — and keep the
/// condition.
QueryAstChild _applyDateOperator(DateCondition condition, String op) {
  final carried = condition.timestamp ?? condition.from ?? '';
  Not neg(Condition next) => Not(child: next);
  DateCondition cmp(String dateOp, String timestamp) => DateCondition(
        field: condition.field,
        op: dateOp,
        timestamp: timestamp,
      );
  switch (op) {
    case 'is':
      return cmp('eq', carried);
    case 'is-not':
      return neg(cmp('eq', carried));
    case 'gt':
    case 'gte':
    case 'lt':
    case 'lte':
      return cmp(op, carried);
    case 'after':
      return DateCondition(field: condition.field, op: 'after', timestamp: carried);
    case 'before':
      return DateCondition(field: condition.field, op: 'before', timestamp: carried);
    case 'between':
      return DateCondition(
        field: condition.field,
        op: 'between',
        from: carried,
        to: condition.to ?? carried,
      );
    case 'within':
      return DateCondition(
        field: condition.field,
        op: 'within',
        period: condition.period ?? 'today',
      );
    case 'set':
    case 'not-set':
      // The date set bits are vacuous: created_at/updated_at are written at
      // create time, so every row reads "set" — no honest control to offer.
      return condition;
    default:
      return condition;
  }
}

/// The property morph: the op carries the value across; between keeps the
/// bounds (an eq value carries into the range); within keeps the period.
QueryAstChild _applyPropertyOperator(PropertyCondition condition, String op) {
  final schemaId = condition.schemaId;
  final carried = condition.value;
  Not neg(Condition next) => Not(child: next);
  PropertyCondition value(String propertyOp, Object? v) => PropertyCondition(
        schemaId: schemaId,
        op: propertyOp,
        value: v,
      );
  switch (op) {
    case 'eq':
      return value('eq', carried);
    case 'neq':
      return value('neq', carried);
    case 'contains':
      return value('contains', carried);
    case 'not-contains':
      return neg(value('contains', carried));
    case 'gt':
    case 'gte':
    case 'lt':
    case 'lte':
      return value(op, carried);
    case 'is-true':
      return value('eq', true);
    case 'is-false':
      return value('eq', false);
    case 'between':
      // The bounds ride the re-pick: an eq value carries into the range
      // (the date arm's contract); a between row keeps both bounds verbatim.
      final from = condition.value ?? condition.from;
      return PropertyCondition(
        schemaId: schemaId,
        op: 'between',
        from: from,
        to: condition.to ?? condition.value,
      );
    case 'within':
      return PropertyCondition(
        schemaId: schemaId,
        op: 'within',
        period: condition.period ?? 'today',
      );
    case 'set':
      return PropertyCondition(schemaId: schemaId, op: 'exists');
    case 'not-set':
      return neg(PropertyCondition(schemaId: schemaId, op: 'exists'));
    default:
      return condition;
  }
}

/// The boolean property row's value-selector morph (the ruling's set+value
/// fold): picking true/false re-materializes the positive eq row — from an
/// `exists` row as much as from an eq row. The value IS the predicate; the
/// row-level not-wrap re-applies when the row renders negated (Exclude).
PropertyCondition applyBooleanValue(PropertyCondition condition, bool value) =>
    PropertyCondition(schemaId: condition.schemaId, op: 'eq', value: value);

/// Apply an operator choice to a block's condition, returning the new child
/// (not-wrapped where the register sugars the negative that way — the
/// content/property/date families, the isClass/isEmbedded polarity, and the
/// wire fields). The member families flip the wire op instead (in ⇄ not-in
/// with the target verbatim; the set bits re-materialize exists/not-exists).
/// The orthogonality law: an operator choice NEVER touches the family's
/// value payload (picked ids / text / value / boolean / bounds / timestamps
/// ride across the morphs).
QueryAstChild applyOperator(Condition condition, String op) {
  switch (condition) {
    case MemberCondition():
      return _applyMemberOperator(condition, op);
    case ContentCondition():
    case NameCondition():
      return _applyTextOperator(condition, op);
    case DateCondition():
      return _applyDateOperator(condition, op);
    case PropertyCondition():
      return _applyPropertyOperator(condition, op);
    case NodeFieldCondition():
      if (condition.field == NodeFieldFields.isClass ||
          condition.field == NodeFieldFields.isEmbedded) {
        // The orthogonality law: the operator choice touches ONLY the
        // polarity — "is-not" wraps (the group-level not sugar, like the
        // cover/banner/alias arm below), "is" returns the positive row. The
        // boolean VALUE is the independent other axis and never moves here.
        return op == 'is-not' ? Not(child: condition) : condition;
      }
      return op == 'not-exists' ? Not(child: condition) : condition;
  }
}

// --- the family register --------------------------------------------------------

/// The add-menu register minus the group/not constructors (the web's
/// FAMILY_OPTIONS source filter) — the single source of truth stays
/// [filterKindOptions] in `query_filter_query.dart`.
final List<FilterKindOption> familyKindOptions = filterKindOptions
    .where(
      (option) =>
          option.value != AddMenuKinds.groupAnd &&
          option.value != AddMenuKinds.groupOr &&
          option.value != AddMenuKinds.not,
    )
    .toList(growable: false);

/// The family options as (value, label) pairs — the row TYPE column's label
/// table.
final List<({String value, String label})> familyOptions = [
  for (final option in familyKindOptions)
    (value: option.value, label: option.label),
];

/// The family label table (the web's FAMILY_LABELS).
final Map<String, String> familyLabels = {
  for (final option in familyOptions) option.value: option.label,
};

/// Append one add-menu entry to a group — the group constructors insert a
/// group with the mode pre-set ("All of"/"Any of"), NOT wraps a fresh empty
/// group, the condition kinds append a half-typed default (createCondition).
/// Shared by the root builder and the nested group footers (the web's
/// withAddedEntry).
Group withAddedEntry(Group group, String entry) {
  if (entry == AddMenuKinds.groupAnd || entry == AddMenuKinds.groupOr) {
    return Group(
      logic: group.logic,
      children: [
        ...group.children,
        Group(
          logic: entry == AddMenuKinds.groupAnd ? 'and' : 'or',
          children: const [],
        ),
      ],
    );
  }
  if (entry == AddMenuKinds.not) {
    return Group(
      logic: group.logic,
      children: [
        ...group.children,
        Not(
          child: const Group(logic: 'and', children: []),
        ),
      ],
    );
  }
  return Group(
    logic: group.logic,
    children: [...group.children, createCondition(entry)],
  );
}
