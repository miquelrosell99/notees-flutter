/// Immutable model for structured node search filters used by the mobile app.
class SearchFilters {
  const SearchFilters({
    this.query = '',
    this.nodeType = SearchKind.any,
    this.classUuids = const [],
    this.taskState = TaskState.any,
    this.dateFrom,
    this.dateTo,
    this.sortBy = SortBy.relevance,
    this.order = SortOrder.desc,
    this.limit = 50,
    this.page = 1,
  });

  final String query;
  final SearchKind nodeType;
  final List<String> classUuids;
  final TaskState taskState;
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final SortBy sortBy;
  final SortOrder order;
  final int limit;
  final int page;

  bool get isEmpty =>
      query.isEmpty &&
      nodeType == SearchKind.any &&
      classUuids.isEmpty &&
      taskState == TaskState.any &&
      dateFrom == null &&
      dateTo == null;

  SearchFilters copyWith({
    String? query,
    SearchKind? nodeType,
    List<String>? classUuids,
    TaskState? taskState,
    DateTime? dateFrom,
    DateTime? dateTo,
    SortBy? sortBy,
    SortOrder? order,
    int? limit,
    int? page,
  }) {
    return SearchFilters(
      query: query ?? this.query,
      nodeType: nodeType ?? this.nodeType,
      classUuids: classUuids ?? this.classUuids,
      taskState: taskState ?? this.taskState,
      dateFrom: dateFrom ?? this.dateFrom,
      dateTo: dateTo ?? this.dateTo,
      sortBy: sortBy ?? this.sortBy,
      order: order ?? this.order,
      limit: limit ?? this.limit,
      page: page ?? this.page,
    );
  }

  /// Serializes to the backend `SearchFilterRequest` JSON shape.
  Map<String, dynamic> toJson() {
    return {
      'query': query,
      'is_page': nodeType == SearchKind.page ? true : null,
      'is_task': nodeType == SearchKind.task ? true : null,
      'is_daily': nodeType == SearchKind.journal ? true : null,
      'class_uuids': classUuids,
      'task_state': taskState.value,
      'date_from': dateFrom?.toIso8601String().split('T').first,
      'date_to': dateTo?.toIso8601String().split('T').first,
      'sort_by': sortBy.value,
      'order': order.value,
      'limit': limit,
      'page': page,
    }..removeWhere((key, value) => value == null);
  }
}

/// UI-only search segment (renamed from `NodeType` in the Revision-11
/// lockstep: `node type` is no longer a model concept — the render state
/// is `is_class` + `present_as_main`; this enum only scopes the search UI).
enum SearchKind {
  any('All'),
  page('Pages'),
  task('Tasks'),
  journal('Journals');

  const SearchKind(this.label);
  final String label;
}

enum TaskState {
  any('any'),
  open('open'),
  completed('completed');

  const TaskState(this.value);
  final String value;
}

enum SortBy {
  relevance('relevance'),
  writeDate('write_date'),
  createDate('create_date'),
  name('name'),
  // The following values are sent to the backend, but the current backend
  // search endpoint only documents relevance/write_date/create_date/name.
  // When the backend ignores them, TasksScreen falls back to client-side
  // sorting so the UI still works.
  dueDate('due_date'),
  priority('priority'),
  manual('manual');

  const SortBy(this.value);
  final String value;

  String get label {
    switch (this) {
      case SortBy.relevance:
        return 'Relevance';
      case SortBy.writeDate:
        return 'Updated';
      case SortBy.createDate:
        return 'Created';
      case SortBy.name:
        return 'Name';
      case SortBy.dueDate:
        return 'Due date';
      case SortBy.priority:
        return 'Priority';
      case SortBy.manual:
        return 'Manual order';
    }
  }
}

enum SortOrder {
  asc('asc'),
  desc('desc');

  const SortOrder(this.value);
  final String value;

  String get label => this == SortOrder.asc ? 'Ascending' : 'Descending';
}
