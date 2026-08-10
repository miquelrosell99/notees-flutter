/// Immutable model for structured node search filters used by the mobile app.
class SearchFilters {
  const SearchFilters({
    this.query = '',
    this.nodeType = NodeType.any,
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
  final NodeType nodeType;
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
      nodeType == NodeType.any &&
      classUuids.isEmpty &&
      taskState == TaskState.any &&
      dateFrom == null &&
      dateTo == null;

  SearchFilters copyWith({
    String? query,
    NodeType? nodeType,
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
      'is_page': nodeType == NodeType.page ? true : null,
      'is_task': nodeType == NodeType.task ? true : null,
      'is_daily': nodeType == NodeType.journal ? true : null,
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

enum NodeType {
  any('All'),
  page('Pages'),
  task('Tasks'),
  journal('Journals');

  const NodeType(this.label);
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
