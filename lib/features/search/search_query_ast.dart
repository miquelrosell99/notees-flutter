import '../../core/constants/system.dart';
import '../../domain/query/query_ast.dart';
import '../../domain/models/search_filters.dart';

/// The search AST builder — the pure headless half of the slice-1 search
/// surface (the GTK `ast_for_search_text`/`search_wire` pattern): the
/// search feature's structured filters translate to the canonical query-AST
/// v2 model and execute LOCALLY over the derived store (the web
/// `packages/query` local-execution architecture; offline search works,
/// online search no longer depends on the server endpoint).
///
/// The mapping (keeps today's UI verbatim):
///  - `query` → `content contains` (substring semantics — the search-box
///    expectation; the `fts` prefix-AND op surprises in a plain box);
///  - [SearchKind.page] → the `pages` scope; [SearchKind.task] → `member
///    class in ids [task]`; [SearchKind.journal] → `member class in ids
///    [year, month, day]`;
///  - `classUuids` → `member class in ids` (closure-aware);
///  - `taskState` rides the taskStatus property at its FIXED seeded option
///    ids (the stored value is an option id, never a name — the web's
///    toggle parity: a completed task may still carry the class, so both
///    pins stay property reads): open = the task class AND NOT
///    (Done | Cancelled); completed = Done | Cancelled. The open pin reads
///    through the effective-values model (the task family's Pending
///    default derives for a classed node, so the negation is two-valued);
///  - the date range → the `created` date condition (both bounds →
///    between, one bound → gte/lte);
///  - sort: `name`/`createDate` map to the AST sort fields; `writeDate`,
///    `relevance` and the task-only fields ride the compiler's
///    deterministic id tiebreak instead (no AST field exists for them).
QueryAst searchFiltersToQueryAst(SearchFilters filters) {
  final children = <QueryAstChild>[];

  final query = filters.query.trim();
  if (query.isNotEmpty) {
    children.add(ContentCondition(op: ContentOps.contains, value: query));
  }

  Scope scope = const EntireWorkspaceScope();
  switch (filters.nodeType) {
    case SearchKind.any:
      break;
    case SearchKind.page:
      scope = const PagesScope();
    case SearchKind.task:
      children.add(
        MemberCondition(
          family: MemberFamilies.class_,
          op: 'in',
          target: IdsTarget(ids: [SystemClassUuids.task]),
        ),
      );
    case SearchKind.journal:
      children.add(
        MemberCondition(
          family: MemberFamilies.class_,
          op: 'in',
          target: const IdsTarget(ids: [
            SystemClassUuids.year,
            SystemClassUuids.month,
            SystemClassUuids.day,
          ]),
        ),
      );
  }

  if (filters.classUuids.isNotEmpty) {
    children.add(
      MemberCondition(
        family: MemberFamilies.class_,
        op: 'in',
        target: IdsTarget(ids: filters.classUuids),
      ),
    );
  }

  if (filters.taskState != TaskState.any) {
    // The task-state pins imply the task class (the legacy filter read
    // isTask too, and a status without the class is the dissolved state).
    children.add(
      MemberCondition(
        family: MemberFamilies.class_,
        op: 'in',
        target: IdsTarget(ids: [SystemClassUuids.task]),
      ),
    );
    PropertyCondition statusPin(String op) => PropertyCondition(
          schemaId: SystemPropertyUuids.taskStatus,
          op: op,
          value: TaskFamilyOptionUuids.done,
        );
    if (filters.taskState == TaskState.completed) {
      children.add(
        Group(
          logic: 'or',
          children: [
            PropertyCondition(
              schemaId: SystemPropertyUuids.taskStatus,
              op: PropertyOps.eq,
              value: TaskFamilyOptionUuids.done,
            ),
            PropertyCondition(
              schemaId: SystemPropertyUuids.taskStatus,
              op: PropertyOps.eq,
              value: TaskFamilyOptionUuids.cancelled,
            ),
          ],
        ),
      );
    } else {
      children.add(
        Not(
          child: Group(
            logic: 'or',
            children: [
              statusPin(PropertyOps.eq),
              PropertyCondition(
                schemaId: SystemPropertyUuids.taskStatus,
                op: PropertyOps.eq,
                value: TaskFamilyOptionUuids.cancelled,
              ),
            ],
          ),
        ),
      );
    }
  }

  final from = filters.dateFrom;
  final to = filters.dateTo;
  if (from != null && to != null) {
    children.add(
      DateCondition(
        field: 'created',
        op: DateOps.between,
        from: _day(from),
        to: _day(to),
      ),
    );
  } else if (from != null) {
    children.add(
      DateCondition(field: 'created', op: DateOps.gte, timestamp: _day(from)),
    );
  } else if (to != null) {
    children.add(
      DateCondition(field: 'created', op: DateOps.lte, timestamp: _day(to)),
    );
  }

  List<SortSpec>? sort;
  switch (filters.sortBy) {
    case SortBy.name:
      sort = [SortSpec(field: SortFields.name, dir: filters.order.value)];
    case SortBy.createDate:
      sort = [SortSpec(field: SortFields.createdAt, dir: filters.order.value)];
    case SortBy.relevance:
    case SortBy.writeDate:
    case SortBy.dueDate:
    case SortBy.priority:
    case SortBy.manual:
      sort = null; // the id tiebreak owns the order
  }

  return QueryAst(
    scope: scope,
    root: Group(logic: 'and', children: children),
    sort: sort,
  );
}

/// Builds the canonical search AST for a plain search-box string:
/// `content contains <text>` over the entire workspace (the GTK
/// `ast_for_search_text` parity). Throws [ArgumentError] on empty text —
/// the caller's entry clears/ignores empty input.
QueryAst astForSearchText(String text) {
  final value = text.trim();
  if (value.isEmpty) {
    throw ArgumentError.value(text, 'text', 'search text must be non-empty');
  }
  return QueryAst(
    scope: const EntireWorkspaceScope(),
    root: Group(
      logic: 'and',
      children: [ContentCondition(op: ContentOps.contains, value: value)],
    ),
  );
}

String _day(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
