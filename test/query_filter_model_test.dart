import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/query/builder_facts.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_filter_model.dart';
import 'package:notees/domain/query/query_filter_query.dart';

/// The condition-builder model matrix — the pure-Dart port of the web's
/// `filterBlockModel.ts` + `filterQuery.ts` (contracts:
/// `apps/web/src/features/collection/filterBlockModel.ts`,
/// `filterQuery.ts`): the family taxonomy, the per-family operator
/// registers, the operator↔target orthogonality law, the boolean
/// single-selector ruling, the prune parity, and the add-menu register.
void main() {
  const uuidA = '11111111-1111-7111-8111-111111111111';
  const uuidB = '22222222-2222-7222-8222-222222222222';

  BuilderFacts emptyFacts() => BuilderFacts(classes: const [], boundProperties: const []);

  BuilderFacts factsWith(BuilderPropertyInfo property) => BuilderFacts(
        classes: const [],
        boundProperties: [property],
      );

  List<String> ops(String family, [Condition? condition, BuilderFacts? facts]) =>
      operatorOptions(family, condition, facts ?? emptyFacts())
          .map((option) => option.value)
          .toList();

  group('familyOf — the 20-family taxonomy', () {
    test('member conditions map to their wire family', () {
      for (final family in MemberFamilies.all) {
        final condition = MemberCondition(
          family: family,
          op: 'in',
          target: const IdsTarget(ids: [uuidA]),
        );
        expect(familyOf(condition), family == MemberFamilies.class_ ? 'class' : family);
      }
    });

    test('class family reads as "class"; name joins content', () {
      expect(
        familyOf(MemberCondition(family: 'class', op: 'in', target: const IdsTarget(ids: [uuidA]))),
        'class',
      );
      expect(familyOf(const NameCondition(op: 'eq', value: 'x')), 'content');
      expect(familyOf(const ContentCondition(op: 'contains', value: 'x')), 'content');
    });

    test('date field picks created/edited; nodeField fields pick theirs', () {
      expect(
        familyOf(const DateCondition(field: 'created', op: 'gt', timestamp: '2026-01-01')),
        'created',
      );
      expect(
        familyOf(const DateCondition(field: 'updated', op: 'gt', timestamp: '2026-01-01')),
        'edited',
      );
      expect(
        familyOf(const NodeFieldCondition(field: 'isClass', op: 'eq', value: 'true')),
        'type',
      );
      expect(
        familyOf(const NodeFieldCondition(field: 'isEmbedded', op: 'eq', value: 'false')),
        'placement',
      );
      expect(
        familyOf(const NodeFieldCondition(field: 'coverAsset', op: 'exists')),
        'cover',
      );
      expect(
        familyOf(const NodeFieldCondition(field: 'bannerAsset', op: 'exists')),
        'banner',
      );
      expect(
        familyOf(const NodeFieldCondition(field: 'aliasedNode', op: 'exists')),
        'alias',
      );
    });
  });

  group('blockView', () {
    test('a plain condition reads unnegated; a not-wrapped condition negated', () {
      const condition = ContentCondition(op: 'contains', value: 'x');
      final plain = blockView(condition);
      expect(plain, isNotNull);
      expect(plain!.negated, isFalse);
      expect(identical(plain.condition, condition), isTrue);
      final wrapped = blockView(const Not(child: condition));
      expect(wrapped, isNotNull);
      expect(wrapped!.negated, isTrue);
    });

    test('groups and not-around-group are never blocks', () {
      const group = Group(logic: 'and', children: []);
      expect(blockView(group), isNull);
      expect(blockView(const Not(child: group)), isNull);
    });
  });

  group('operatorOptions — the per-family registers', () {
    test('class carries the multi-value set', () {
      expect(ops('class'), [
        'is',
        'is-not',
        'contains',
        'not-contains',
        'set',
        'not-set',
      ]);
    });

    test('content carries the text set; a name row drops the edge/fts arms', () {
      expect(ops('content'), [
        'is',
        'is-not',
        'contains',
        'not-contains',
        'starts',
        'ends',
        'fts',
        'set',
        'not-set',
      ]);
      expect(ops('content', const NameCondition(op: 'eq', value: 'x')), [
        'is',
        'is-not',
        'contains',
        'not-contains',
        'set',
        'not-set',
      ]);
    });

    test('member families carry their registers', () {
      expect(ops('tags'), ['is', 'is-not', 'set', 'not-set']);
      expect(ops('links'), ['is', 'is-not', 'set', 'not-set']);
      expect(ops('referencePath'), ['is-any-of', 'is-not-any-of']);
      expect(ops('parent'), ['is', 'is-not', 'set', 'not-set']);
      expect(ops('child'), ['contains-any-of', 'not-contains-any-of', 'set', 'not-set']);
      expect(ops('childPath'), ['contains', 'not-contains', 'set', 'not-set']);
      expect(ops('page'), ['is', 'is-not', 'set', 'not-set']);
      expect(ops('parentPath'), ['includes', 'not-includes', 'set', 'not-set']);
      expect(ops('root'), ['is', 'is-not']);
    });

    test('type and placement carry NO operator column (the boolean ruling)', () {
      expect(ops('type'), isEmpty);
      expect(ops('placement'), isEmpty);
    });

    test('wire fields carry only the set bits', () {
      for (final family in ['cover', 'banner', 'alias']) {
        expect(ops(family), ['exists', 'not-exists']);
      }
    });

    test('dates carry the comparison set without set bits', () {
      for (final family in ['created', 'edited']) {
        expect(ops(family), [
          'is',
          'is-not',
          'gt',
          'gte',
          'lt',
          'lte',
          'between',
          'within',
        ]);
      }
    });

    test('property adapts to the selected schema type', () {
      BuilderPropertyInfo schema(String type) => BuilderPropertyInfo(
            id: uuidA,
            name: 'p',
            type: type,
          );
      const condition = PropertyCondition(schemaId: uuidA, op: 'eq', value: 'x');
      expect(ops('property', condition, factsWith(schema('text'))), [
        'eq',
        'neq',
        'contains',
        'not-contains',
        'set',
        'not-set',
      ]);
      expect(ops('property', condition, factsWith(schema('number'))), [
        'eq',
        'neq',
        'gt',
        'gte',
        'lt',
        'lte',
        'between',
        'contains',
        'not-contains',
        'set',
        'not-set',
      ]);
      expect(ops('property', condition, factsWith(schema('datetime'))), [
        'eq',
        'neq',
        'gt',
        'gte',
        'lt',
        'lte',
        'between',
        'within',
        'set',
        'not-set',
      ]);
      expect(ops('property', condition, factsWith(schema('select'))), [
        'eq',
        'neq',
        'set',
        'not-set',
      ]);
      // The boolean register folds the truth value into the value column:
      // only the set bits ride the operator column.
      expect(ops('property', condition, factsWith(schema('boolean'))), [
        'set',
        'not-set',
      ]);
      expect(ops('property', condition, factsWith(schema('object'))), [
        'eq',
        'neq',
        'set',
        'not-set',
      ]);
      // Unknown/broken schema falls back to the text set.
      expect(ops('property', null, factsWith(schema('text'))), [
        'eq',
        'neq',
        'contains',
        'not-contains',
        'set',
        'not-set',
      ]);
    });
  });

  group('operatorOf — the operator column read (+ negation)', () {
    test('membership reads the canonical label; not-in reads the negative', () {
      final inCondition = MemberCondition(
        family: 'class',
        op: 'in',
        target: const IdsTarget(ids: [uuidA]),
      );
      expect(operatorOf(inCondition, false), 'contains');
      final notIn = MemberCondition(
        family: 'class',
        op: 'not-in',
        target: const IdsTarget(ids: [uuidA]),
      );
      expect(operatorOf(notIn, false), 'not-contains');
      // A negated membership row renders the POSITIVE label again (the
      // not-wrap is the sugar — flipping the label would double-negate).
      expect(operatorOf(notIn, true), 'contains');
      expect(operatorOf(inCondition, true), 'not-contains');
    });

    test('the set bits read set/not-set, swapped under negation', () {
      expect(
        operatorOf(MemberCondition.exists(family: 'tags', op: 'exists'), false),
        'set',
      );
      expect(
        operatorOf(MemberCondition.exists(family: 'tags', op: 'exists'), true),
        'not-set',
      );
      expect(
        operatorOf(MemberCondition.exists(family: 'tags', op: 'not-exists'), false),
        'not-set',
      );
      expect(
        operatorOf(MemberCondition.exists(family: 'tags', op: 'not-exists'), true),
        'set',
      );
    });

    test('legacy exact reads is/is-not', () {
      final exact = MemberCondition(
        family: 'class',
        op: 'exact',
        target: const IdsTarget(ids: [uuidA]),
      );
      expect(operatorOf(exact, false), 'is');
      expect(operatorOf(exact, true), 'is-not');
    });

    test('text ops read their labels; negatives ride the not-wrap', () {
      expect(
        operatorOf(const ContentCondition(op: 'eq', value: 'x'), false),
        'is',
      );
      expect(
        operatorOf(const ContentCondition(op: 'eq', value: 'x'), true),
        'is-not',
      );
      expect(
        operatorOf(const ContentCondition(op: 'contains', value: 'x'), true),
        'not-contains',
      );
      expect(
        operatorOf(const ContentCondition(op: 'starts', value: 'x'), true),
        'starts',
      );
      expect(
        operatorOf(const ContentCondition(op: 'fts', value: 'x'), true),
        'fts',
      );
      expect(
        operatorOf(const ContentCondition(op: 'exists'), false),
        'set',
      );
      expect(
        operatorOf(const ContentCondition(op: 'exists'), true),
        'not-set',
      );
    });

    test('property: boolean folds to the set axis; scalars read the polarity', () {
      const boolEq = PropertyCondition(schemaId: uuidA, op: 'eq', value: true);
      expect(operatorOf(boolEq, false), 'set');
      expect(operatorOf(boolEq, true), 'not-set');
      const scalarEq = PropertyCondition(schemaId: uuidA, op: 'eq', value: 'x');
      expect(operatorOf(scalarEq, false), 'eq');
      expect(operatorOf(scalarEq, true), 'neq');
      const contains = PropertyCondition(schemaId: uuidA, op: 'contains', value: 'x');
      expect(operatorOf(contains, true), 'not-contains');
      expect(
        operatorOf(const PropertyCondition(schemaId: uuidA, op: 'between', from: 1, to: 2), false),
        'between',
      );
      expect(
        operatorOf(const PropertyCondition(schemaId: uuidA, op: 'within', period: 'today'), false),
        'within',
      );
    });

    test('dates: eq reads is/is-not; neq is the folded negative', () {
      const eq = DateCondition(field: 'created', op: 'eq', timestamp: '2026-01-01');
      expect(operatorOf(eq, false), 'is');
      expect(operatorOf(eq, true), 'is-not');
      const neq = DateCondition(field: 'created', op: 'neq', timestamp: '2026-01-01');
      expect(operatorOf(neq, false), 'is-not');
      expect(operatorOf(neq, true), 'is');
      expect(
        operatorOf(const DateCondition(field: 'created', op: 'gt', timestamp: '2026-01-01'), true),
        'gt',
      );
    });

    test('nodeField booleans read the polarity only; wire fields the set bits', () {
      const isClass = NodeFieldCondition(field: 'isClass', op: 'eq', value: 'true');
      expect(operatorOf(isClass, false), 'is');
      expect(operatorOf(isClass, true), 'is-not');
      const cover = NodeFieldCondition(field: 'coverAsset', op: 'exists');
      expect(operatorOf(cover, false), 'exists');
      expect(operatorOf(cover, true), 'not-exists');
    });
  });

  group('applyOperator — the orthogonality law', () {
    test('a member flip carries the target verbatim (ids mode)', () {
      final condition = MemberCondition(
        family: 'class',
        op: 'in',
        target: const IdsTarget(ids: [uuidA, uuidB]),
      );
      final flipped = applyOperator(condition, 'not-contains');
      expect(flipped, isA<MemberCondition>());
      final next = flipped as MemberCondition;
      expect(next.op, 'not-in');
      expect(next.target, isA<IdsTarget>());
      expect((next.target! as IdsTarget).ids, [uuidA, uuidB]);
    });

    test('a member flip carries the nested query target verbatim (query mode)', () {
      const nested = Group(
        logic: 'and',
        children: [ContentCondition(op: 'contains', value: 'x')],
      );
      final condition = MemberCondition(
        family: 'links',
        op: 'in',
        target: const QueryTarget(root: nested),
      );
      final flipped = applyOperator(condition, 'is-not') as MemberCondition;
      expect(flipped.op, 'not-in');
      expect(flipped.target, isA<QueryTarget>());
      expect((flipped.target! as QueryTarget).root, nested);
    });

    test('a member flip carries the self marker verbatim (self mode)', () {
      final condition = MemberCondition(
        family: 'page',
        op: 'not-in',
        target: const SelfTarget(),
      );
      final flipped = applyOperator(condition, 'is') as MemberCondition;
      expect(flipped.op, 'in');
      expect(flipped.target, isA<SelfTarget>());
    });

    test('the set bits re-materialize exists/not-exists with NO target', () {
      final condition = MemberCondition(
        family: 'tags',
        op: 'in',
        target: const IdsTarget(ids: [uuidA]),
      );
      final set = applyOperator(condition, 'set') as MemberCondition;
      expect(set.op, 'exists');
      expect(set.target, isNull);
      final notSet = applyOperator(condition, 'not-set') as MemberCondition;
      expect(notSet.op, 'not-exists');
      expect(notSet.target, isNull);
      // Flipping a set row back re-materializes an `in` over an empty pick.
      final restored = applyOperator(set, 'is') as MemberCondition;
      expect(restored.op, 'in');
      expect(restored.target, isA<IdsTarget>());
      expect((restored.target! as IdsTarget).ids, isEmpty);
      // A not-exists row restores to not-in (the polarity survives the set
      // round-trip).
      final restoredNeg = applyOperator(notSet, 'is-not') as MemberCondition;
      expect(restoredNeg.op, 'not-in');
    });

    test('text morphs carry the value; negatives wrap in not', () {
      const condition = ContentCondition(op: 'contains', value: 'hello');
      final isOp = applyOperator(condition, 'is') as ContentCondition;
      expect(isOp.op, 'eq');
      expect(isOp.value, 'hello');
      final isNot = applyOperator(condition, 'is-not');
      expect(isNot, isA<Not>());
      expect((isNot as Not).child, isA<ContentCondition>());
      expect((isNot.child as ContentCondition).op, 'eq');
      final starts = applyOperator(condition, 'starts') as ContentCondition;
      expect(starts.op, 'starts');
      expect(starts.value, 'hello');
      final set = applyOperator(condition, 'set') as ContentCondition;
      expect(set.op, 'exists');
      expect(set.value, isNull);
      final notSet = applyOperator(condition, 'not-set') as Not;
      expect((notSet.child as ContentCondition).op, 'exists');
    });

    test('a name row keeps the edge/fts arms verbatim (content-only ops)', () {
      const name = NameCondition(op: 'eq', value: 'title');
      expect(identical(applyOperator(name, 'starts'), name), isTrue);
      expect(identical(applyOperator(name, 'ends'), name), isTrue);
      expect(identical(applyOperator(name, 'fts'), name), isTrue);
      // The register still offers the arms the name morph implements.
      final isNot = applyOperator(name, 'is-not') as Not;
      expect((isNot.child as NameCondition).op, 'eq');
    });

    test('date morphs carry the timestamp into comparisons and the range', () {
      const condition = DateCondition(field: 'created', op: 'gt', timestamp: '2026-01-02');
      final isOp = applyOperator(condition, 'is') as DateCondition;
      expect(isOp.op, 'eq');
      expect(isOp.timestamp, '2026-01-02');
      final isNot = applyOperator(condition, 'is-not') as Not;
      expect((isNot.child as DateCondition).op, 'eq');
      final between = applyOperator(condition, 'between') as DateCondition;
      expect(between.op, 'between');
      expect(between.from, '2026-01-02');
      expect(between.to, '2026-01-02');
      final within = applyOperator(condition, 'within') as DateCondition;
      expect(within.op, 'within');
      expect(within.period, 'today');
      // The vacuous set bits keep the condition verbatim.
      expect(identical(applyOperator(condition, 'set'), condition), isTrue);
    });

    test('property morphs carry the value across; between keeps the bounds', () {
      const condition = PropertyCondition(schemaId: uuidA, op: 'eq', value: '5');
      final gt = applyOperator(condition, 'gt') as PropertyCondition;
      expect(gt.op, 'gt');
      expect(gt.value, '5');
      final neq = applyOperator(condition, 'neq') as PropertyCondition;
      expect(neq.op, 'neq');
      expect(neq.value, '5');
      final notContains = applyOperator(condition, 'not-contains') as Not;
      expect((notContains.child as PropertyCondition).op, 'contains');
      final between = applyOperator(condition, 'between') as PropertyCondition;
      expect(between.from, '5');
      expect(between.to, '5');
      final set = applyOperator(condition, 'set') as PropertyCondition;
      expect(set.op, 'exists');
      final notSet = applyOperator(condition, 'not-set') as Not;
      expect((notSet.child as PropertyCondition).op, 'exists');
      final trueRow = applyOperator(condition, 'is-true') as PropertyCondition;
      expect(trueRow.op, 'eq');
      expect(trueRow.value, isTrue);
    });

    test('applyBooleanValue re-materializes the positive eq row', () {
      const exists = PropertyCondition(schemaId: uuidA, op: 'exists');
      final trueRow = applyBooleanValue(exists, true);
      expect(trueRow.op, 'eq');
      expect(trueRow.value, isTrue);
      final falseRow = applyBooleanValue(
        const PropertyCondition(schemaId: uuidA, op: 'eq', value: true),
        false,
      );
      expect(falseRow.op, 'eq');
      expect(falseRow.value, isFalse);
    });

    test('nodeField booleans: the operator touches ONLY the polarity', () {
      const isClass = NodeFieldCondition(field: 'isClass', op: 'eq', value: 'true');
      expect(identical(applyOperator(isClass, 'is'), isClass), isTrue);
      final isNot = applyOperator(isClass, 'is-not') as Not;
      expect(identical(isNot.child, isClass), isTrue);
      // The value axis never moves under an operator choice.
      const isPage = NodeFieldCondition(field: 'isEmbedded', op: 'eq', value: 'false');
      final wrappedPage = applyOperator(isPage, 'is-not') as Not;
      expect((wrappedPage.child as NodeFieldCondition).value, 'false');
    });

    test('wire fields wrap on the negative set bit', () {
      const cover = NodeFieldCondition(field: 'coverAsset', op: 'exists');
      expect(identical(applyOperator(cover, 'exists'), cover), isTrue);
      final notExists = applyOperator(cover, 'not-exists') as Not;
      expect(identical(notExists.child, cover), isTrue);
    });
  });

  group('prune — draft → composed group parity', () {
    FilterQuery draft(QueryAstChild child) =>
        FilterQuery(group: Group(logic: 'and', children: [child]));

    test('half-typed rows drop: blank content, empty ids pick, blank schema, blank timestamp', () {
      expect(
        filterQueryToGroup(draft(const ContentCondition(op: 'contains', value: '  '))),
        isNull,
      );
      expect(
        filterQueryToGroup(
          draft(MemberCondition(family: 'class', op: 'in', target: const IdsTarget(ids: []))),
        ),
        isNull,
      );
      expect(
        filterQueryToGroup(draft(const PropertyCondition(schemaId: '', op: 'eq', value: 'x'))),
        isNull,
      );
      expect(
        filterQueryToGroup(
          draft(const DateCondition(field: 'created', op: 'gt', timestamp: '')),
        ),
        isNull,
      );
    });

    test('fully-specified rows survive: set bits, self target, node fields, date within', () {
      final setRow = MemberCondition.exists(family: 'tags', op: 'exists');
      final selfRow = MemberCondition(
        family: 'page',
        op: 'in',
        target: const SelfTarget(),
      );
      const typeRow = NodeFieldCondition(field: 'isClass', op: 'eq', value: 'true');
      const within = DateCondition(field: 'created', op: 'within', period: 'today');
      final group = filterQueryToGroup(
        FilterQuery(group: Group(logic: 'or', children: [setRow, selfRow, typeRow, within])),
      );
      expect(group, isNotNull);
      expect(group!.logic, 'or');
      expect(group.children, hasLength(4));
    });

    test('property between drops on a missing bound; valued ranges survive', () {
      expect(
        filterQueryToGroup(
          draft(const PropertyCondition(schemaId: uuidA, op: 'between', from: 1)),
        ),
        isNull,
      );
      final ok = filterQueryToGroup(
        draft(const PropertyCondition(schemaId: uuidA, op: 'between', from: 1, to: 9)),
      );
      expect(ok, isNotNull);
    });

    test('date between drops on a blank bound', () {
      expect(
        filterQueryToGroup(
          draft(const DateCondition(field: 'created', op: 'between', from: '2026-01-01', to: '')),
        ),
        isNull,
      );
    });

    test('nested groups recurse; emptied ones drop; not drops with its child', () {
      final nested = Group(
        logic: 'and',
        children: [
          const ContentCondition(op: 'contains', value: ''),
          const NodeFieldCondition(field: 'isClass', op: 'eq', value: 'true'),
        ],
      );
      final composed = filterQueryToGroup(
        draft(Not(child: Group(logic: 'and', children: [nested]))),
      );
      expect(composed, isNotNull);
      final not = composed!.children.single as Not;
      final outer = not.child as Group;
      final inner = outer.children.single as Group;
      expect(inner.children.single, isA<NodeFieldCondition>());

      expect(
        filterQueryToGroup(draft(const Not(child: ContentCondition(op: 'contains', value: '')))),
        isNull,
      );
      expect(filterQueryToGroup(draft(const Group(logic: 'and', children: []))), isNull);
    });

    test('a query target drops when its nested group pruned to empty', () {
      final emptyTarget = MemberCondition(
        family: 'links',
        op: 'in',
        target: const QueryTarget(root: Group(logic: 'and', children: [])),
      );
      expect(filterQueryToGroup(draft(emptyTarget)), isNull);
      final valuedTarget = MemberCondition(
        family: 'links',
        op: 'in',
        target: const QueryTarget(
          root: Group(
            logic: 'and',
            children: [ContentCondition(op: 'contains', value: 'x')],
          ),
        ),
      );
      final composed = filterQueryToGroup(draft(valuedTarget));
      expect(composed, isNotNull);
      expect((composed!.children.single as MemberCondition).target, isA<QueryTarget>());
    });

    test('the root keeps its logic and a surviving child list', () {
      final composed = filterQueryToGroup(
        FilterQuery(
          group: Group(
            logic: 'or',
            children: const [
              ContentCondition(op: 'contains', value: ''),
              ContentCondition(op: 'contains', value: 'x'),
            ],
          ),
        ),
      );
      expect(composed!.logic, 'or');
      expect(composed.children, hasLength(1));
    });
  });

  group('createCondition — the half-typed defaults', () {
    test('class rides the multi-value membership register', () {
      final condition = createCondition('class') as MemberCondition;
      expect(condition.family, 'class');
      expect(condition.op, 'in');
      expect(condition.target, isA<IdsTarget>());
      expect((condition.target! as IdsTarget).ids, isEmpty);
    });

    test('type and placement seed the boolean rows', () {
      final type = createCondition('type') as NodeFieldCondition;
      expect(type.field, 'isClass');
      expect(type.value, 'true');
      final placement = createCondition('placement') as NodeFieldCondition;
      expect(placement.field, 'isEmbedded');
      expect(placement.value, 'false');
    });

    test('content/property seed blank half-typed rows', () {
      final content = createCondition('content') as ContentCondition;
      expect(content.op, 'contains');
      expect(content.value, '');
      final property = createCondition('property') as PropertyCondition;
      expect(property.schemaId, '');
      expect(property.op, 'eq');
    });

    test('every node-target family binds the ids list by default', () {
      for (final family in [
        'tags',
        'links',
        'referencePath',
        'parent',
        'child',
        'childPath',
        'page',
        'parentPath',
        'root',
      ]) {
        final condition = createCondition(family) as MemberCondition;
        expect(condition.family, family, reason: family);
        expect(condition.op, 'in');
        expect(condition.target, isA<IdsTarget>());
      }
    });

    test('wire fields seed the positive set bit; dates seed an open row', () {
      expect((createCondition('cover') as NodeFieldCondition).op, 'exists');
      expect((createCondition('banner') as NodeFieldCondition).op, 'exists');
      expect((createCondition('alias') as NodeFieldCondition).op, 'exists');
      final created = createCondition('created') as DateCondition;
      expect(created.field, 'created');
      expect(created.op, 'after');
      expect(created.timestamp, '');
      final edited = createCondition('edited') as DateCondition;
      expect(edited.field, 'updated');
    });

    test('unknown kinds fail loud', () {
      expect(() => createCondition('nope'), throwsArgumentError);
    });
  });

  group('the add-menu register', () {
    test('carries the families plus the three constructors, groups last', () {
      expect(filterKindOptions, hasLength(22));
      final values = filterKindOptions.map((option) => option.value).toList();
      expect(values.take(ConditionKinds.all.length), ConditionKinds.all);
      expect(values.skip(ConditionKinds.all.length), [
        'group-and',
        'group-or',
        'not',
      ]);
    });

    test('familyOptions excludes the constructors; labels cover every family', () {
      expect(familyOptions, hasLength(ConditionKinds.all.length));
      expect(familyLabels.keys.toSet(), ConditionKinds.all.toSet());
      expect(familyLabels['class'], 'Class');
      expect(familyLabels['placement'], 'Structural role');
      expect(familyLabels['referencePath'], 'Link path');
    });

    test('withAddedEntry appends per the entry kind', () {
      const root = Group(logic: 'and', children: []);
      final andGroup = withAddedEntry(root, 'group-and');
      expect(andGroup.children.single, isA<Group>());
      expect((andGroup.children.single as Group).logic, 'and');
      final orGroup = withAddedEntry(root, 'group-or');
      expect((orGroup.children.single as Group).logic, 'or');
      final not = withAddedEntry(root, 'not');
      expect(not.children.single, isA<Not>());
      expect((not.children.single as Not).child, isA<Group>());
      final condition = withAddedEntry(root, 'content');
      expect(condition.children.single, isA<ContentCondition>());
    });
  });

  group('the draft state', () {
    test('draftOrFactoryAst composes the draft; empty drafts ride the factory', () {
      final composed = draftOrFactoryAst(
        FilterQuery(
          group: Group(
            logic: 'and',
            children: [const ContentCondition(op: 'contains', value: 'x')],
          ),
        ),
      );
      expect(composed.root.children, hasLength(1));
      expect(composed.scope, isA<EntireWorkspaceScope>());
      expect(identical(draftOrFactoryAst(emptyFilterQuery), factoryQueryAst), isTrue);
    });

    test('isFilterInactive and quickTextOf', () {
      expect(isFilterInactive(emptyFilterQuery), isTrue);
      expect(
        isFilterInactive(
          FilterQuery(text: '  ', group: const Group(logic: 'and', children: [])),
        ),
        isTrue,
      );
      expect(
        isFilterInactive(
          FilterQuery(
            group: Group(
              logic: 'and',
              children: [const ContentCondition(op: 'contains', value: 'x')],
            ),
          ),
        ),
        isFalse,
      );
      expect(quickTextOf(FilterQuery(text: '  hello ', group: emptyFilterQuery.group)), 'hello');
    });
  });

  group('BuilderFacts — the picker-source read model', () {
    test('name maps derive from the rows; propertyById resolves', () {
      final facts = BuilderFacts(
        classes: const [BuilderClassInfo(id: uuidA, name: 'Book')],
        boundProperties: const [
          BuilderPropertyInfo(id: uuidB, name: 'Pages', type: 'number'),
        ],
      );
      expect(facts.classNames[uuidA], 'Book');
      expect(facts.propertyNames[uuidB], 'Pages');
      expect(facts.propertyById(uuidB)?.type, 'number');
      expect(facts.propertyById('nope'), isNull);
    });
  });
}
