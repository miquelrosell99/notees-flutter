import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/models/search_filters.dart';

void main() {
  group('SearchFilters', () {
    final todayDate = DateTime(2026, 8, 9);

    test('serializes task segment filters', () {
      final today = SearchFilters(
        nodeType: NodeType.task,
        taskState: TaskState.open,
        dateFrom: todayDate,
        dateTo: todayDate,
        sortBy: SortBy.dueDate,
      );
      final json = today.toJson();
      expect(json['is_task'], true);
      expect(json['task_state'], 'open');
      expect(json['date_from'], _format(todayDate));
      expect(json['date_to'], _format(todayDate));
      expect(json['sort_by'], 'due_date');
    });

    test('serializes completed segment filters', () {
      const completed = SearchFilters(
        nodeType: NodeType.task,
        taskState: TaskState.completed,
        sortBy: SortBy.priority,
      );
      final json = completed.toJson();
      expect(json['is_task'], true);
      expect(json['task_state'], 'completed');
      expect(json['sort_by'], 'priority');
    });

    test('removes null values from JSON', () {
      const empty = SearchFilters();
      final json = empty.toJson();
      expect(json.containsKey('is_page'), false);
      expect(json.containsKey('is_task'), false);
      expect(json.containsKey('is_daily'), false);
      expect(json.containsKey('date_from'), false);
      expect(json.containsKey('date_to'), false);
    });

    test('SortBy labels are descriptive', () {
      expect(SortBy.dueDate.label, 'Due date');
      expect(SortBy.priority.label, 'Priority');
      expect(SortBy.manual.label, 'Manual order');
    });
  });
}

String _format(DateTime date) => '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
