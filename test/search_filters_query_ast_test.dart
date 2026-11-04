import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/domain/models/search_filters.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/features/search/search_query_ast.dart';

/// The SearchFilters → QueryAst translation pins: every SearchKind, the
/// task-state pins at the fixed seeded option ids, the class list, the date
/// range, and the sort mapping.
void main() {
  group('searchFiltersToQueryAst', () {
    test('an empty filter set is the entire workspace with no conditions',
        () {
      final ast = searchFiltersToQueryAst(const SearchFilters());
      expect(ast.scope, isA<EntireWorkspaceScope>());
      expect(ast.root.children, isEmpty);
      expect(ast.sort, isNull);
    });

    test('the query text rides content contains', () {
      final ast = searchFiltersToQueryAst(
        const SearchFilters(query: '  hello world  '),
      );
      final condition = ast.root.children.single as ContentCondition;
      expect(condition.op, ContentOps.contains);
      expect(condition.value, 'hello world');
    });

    test('SearchKind.page is the pages scope', () {
      final ast = searchFiltersToQueryAst(
        const SearchFilters(nodeType: SearchKind.page),
      );
      expect(ast.scope, isA<PagesScope>());
      expect(ast.root.children, isEmpty);
    });

    test('SearchKind.task pins the task class membership', () {
      final ast = searchFiltersToQueryAst(
        const SearchFilters(nodeType: SearchKind.task),
      );
      final member = ast.root.children.single as MemberCondition;
      expect(member.family, MemberFamilies.class_);
      expect((member.target! as IdsTarget).ids, [SystemClassUuids.task]);
    });

    test('SearchKind.journal pins the date-chain classes', () {
      final ast = searchFiltersToQueryAst(
        const SearchFilters(nodeType: SearchKind.journal),
      );
      final member = ast.root.children.single as MemberCondition;
      expect((member.target! as IdsTarget).ids, [
        SystemClassUuids.year,
        SystemClassUuids.month,
        SystemClassUuids.day,
      ]);
    });

    test('the class list rides member class in ids', () {
      const classId = '0192a000-0000-7000-8000-000000000099';
      final ast = searchFiltersToQueryAst(
        const SearchFilters(classUuids: [classId]),
      );
      final member = ast.root.children.single as MemberCondition;
      expect((member.target! as IdsTarget).ids, [classId]);
    });

    test('taskState completed is the Done/Cancelled option-id pins', () {
      final ast = searchFiltersToQueryAst(
        const SearchFilters(taskState: TaskState.completed),
      );
      expect(ast.root.children, hasLength(2));
      final member = ast.root.children[0] as MemberCondition;
      expect((member.target! as IdsTarget).ids, [SystemClassUuids.task]);
      final group = ast.root.children[1] as Group;
      expect(group.logic, 'or');
      final pins = group.children.cast<PropertyCondition>();
      expect(pins.map((p) => p.value), [
        TaskFamilyOptionUuids.done,
        TaskFamilyOptionUuids.cancelled,
      ]);
      expect(pins.map((p) => p.schemaId).toSet(),
          {SystemPropertyUuids.taskStatus});
    });

    test('taskState open is the task class AND NOT (Done | Cancelled)', () {
      final ast = searchFiltersToQueryAst(
        const SearchFilters(taskState: TaskState.open),
      );
      expect(ast.root.children, hasLength(2));
      final negation = ast.root.children[1] as Not;
      final group = negation.child as Group;
      expect(group.logic, 'or');
      final pins = group.children.cast<PropertyCondition>();
      expect(pins.map((p) => p.value), [
        TaskFamilyOptionUuids.done,
        TaskFamilyOptionUuids.cancelled,
      ]);
    });

    test('the date range maps to the created date condition', () {
      final from = DateTime(2026, 11, 1);
      final to = DateTime(2026, 11, 30, 18, 45);
      final ast = searchFiltersToQueryAst(
        SearchFilters(dateFrom: from, dateTo: to),
      );
      final condition = ast.root.children.single as DateCondition;
      expect(condition.field, 'created');
      expect(condition.op, DateOps.between);
      expect(condition.from, '2026-11-01');
      expect(condition.to, '2026-11-30');
    });

    test('a single date bound maps to gte/lte', () {
      final fromOnly = searchFiltersToQueryAst(
        SearchFilters(dateFrom: DateTime(2026, 11, 1)),
      );
      expect((fromOnly.root.children.single as DateCondition).op, DateOps.gte);
      final toOnly = searchFiltersToQueryAst(
        SearchFilters(dateTo: DateTime(2026, 11, 30)),
      );
      expect((toOnly.root.children.single as DateCondition).op, DateOps.lte);
    });

    test('sort maps name/createDate; relevance rides the id tiebreak', () {
      final byName = searchFiltersToQueryAst(
        const SearchFilters(sortBy: SortBy.name, order: SortOrder.asc),
      );
      expect(byName.sort!.single.field, SortFields.name);
      expect(byName.sort!.single.dir, 'asc');
      final byCreated = searchFiltersToQueryAst(
        const SearchFilters(sortBy: SortBy.createDate, order: SortOrder.desc),
      );
      expect(byCreated.sort!.single.field, SortFields.createdAt);
      final byRelevance = searchFiltersToQueryAst(
        const SearchFilters(sortBy: SortBy.relevance),
      );
      expect(byRelevance.sort, isNull);
      final byUpdated = searchFiltersToQueryAst(
        const SearchFilters(sortBy: SortBy.writeDate),
      );
      expect(byUpdated.sort, isNull);
    });

    test('the translation always yields a version-2 AST', () {
      final ast = searchFiltersToQueryAst(
        const SearchFilters(
          query: 'x',
          nodeType: SearchKind.task,
          classUuids: ['0192a000-0000-7000-8000-000000000099'],
          taskState: TaskState.open,
        ),
      );
      expect(ast.toJson()['version'], 2);
      // And it strict-parses back from its own wire form.
      expect(QueryAst.parse(ast.toJson()).toJson(), ast.toJson());
    });
  });

  group('astForSearchText', () {
    test('builds the canonical search AST', () {
      final ast = astForSearchText('grand canyon');
      expect(ast.scope, isA<EntireWorkspaceScope>());
      final condition = ast.root.children.single as ContentCondition;
      expect(condition.op, ContentOps.contains);
      expect(condition.value, 'grand canyon');
    });

    test('trims whitespace; empty text has no honest reading', () {
      expect((astForSearchText('  needle ').root.children.single
              as ContentCondition)
          .value,
          'needle');
      expect(() => astForSearchText('   '), throwsArgumentError);
    });
  });
}
