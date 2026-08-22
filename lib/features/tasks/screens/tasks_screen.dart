import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/system.dart';
import '../../../core/routing/router.dart';
import '../../../data/models/node.dart';
import '../../../data/models/property.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../domain/models/search_filters.dart';
import '../../../domain/services/recurrence_expansion.dart';
import '../../../native/reminder_service.dart';
import '../../../native/widget_service.dart';
import '../../auth/providers/auth_provider.dart';
import '../../../shared/views/_view_helpers.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/fleet_card.dart';
import '../widgets/task_creation_sheet.dart';
import '../widgets/task_row.dart';

/// Task list segments.
enum TaskSegment {
  today,
  upcoming,
  someday,
  all,
  undated,
  completed;

  String get label {
    switch (this) {
      case TaskSegment.today:
        return 'Today';
      case TaskSegment.upcoming:
        return 'Upcoming';
      case TaskSegment.someday:
        return 'Someday';
      case TaskSegment.all:
        return 'All';
      case TaskSegment.undated:
        return 'Undated';
      case TaskSegment.completed:
        return 'Completed';
    }
  }
}

/// Due-date buckets used to group the Upcoming segment.
enum _TaskBucket {
  overdue('Overdue'),
  today('Today'),
  tomorrow('Tomorrow'),
  thisWeek('This week'),
  later('Later'),
  noDate('No date');

  const _TaskBucket(this.label);

  final String label;
}

/// Dedicated task list with segments, sorting, swipe actions,
/// multi-select batch operations, and a quick-detail bottom sheet.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  List<Node> _tasks = [];
  bool _loading = true;
  String? _error;

  TaskSegment _segment = TaskSegment.today;
  SortBy _sortBy = SortBy.dueDate;
  bool _focusMode = false;

  bool _selectionMode = false;
  final Set<String> _selected = <String>{};
  final Set<String> _failedToggles = <String>{};

  static const _closedStatuses = TaskStatuses.closed;

  @override
  void initState() {
    super.initState();
    _loadTasks();
  }

  NodeRepository _repo(BuildContext context) {
    final auth = context.read<AuthProvider>();
    return NodeRepository(dio: auth.dio!, syncService: auth.syncService);
  }

  Future<void> _loadTasks({bool silent = false}) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    if (mounted && !silent) setState(() => _loading = true);
    try {
      final repo = _repo(context);
      final segment = _focusMode ? TaskSegment.today : _segment;
      final filters = _filtersFor(segment);
      final fetched = await repo.searchWithFilters(filters);
      var processed = switch (segment) {
        TaskSegment.someday || TaskSegment.undated =>
          fetched.where((t) => _taskDueDate(t) == null).toList(),
        _ => List<Node>.from(fetched),
      };
      _applyClientSort(processed);
      if (mounted) {
        setState(() {
          _tasks = processed;
          _error = null;
        });
      }
      if (segment == TaskSegment.today) {
        await WidgetService.saveTodayTasks(processed);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  SearchFilters _filtersFor(TaskSegment segment) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    const limit = 500;
    switch (segment) {
      case TaskSegment.today:
        return SearchFilters(
          nodeType: NodeType.task,
          taskState: TaskState.open,
          dateFrom: today,
          dateTo: today,
          sortBy: _sortBy,
          limit: limit,
        );
      case TaskSegment.upcoming:
      case TaskSegment.someday:
      case TaskSegment.all:
      case TaskSegment.undated:
        // Fetch all open tasks. Upcoming groups into due-date buckets
        // client-side; someday/undated drop dated tasks client-side because
        // SearchFilters only expresses date ranges.
        return SearchFilters(
          nodeType: NodeType.task,
          taskState: TaskState.open,
          sortBy: _sortBy,
          limit: limit,
        );
      case TaskSegment.completed:
        return SearchFilters(
          nodeType: NodeType.task,
          taskState: TaskState.completed,
          sortBy: _sortBy,
          limit: limit,
        );
    }
  }

  void _applyClientSort(List<Node> tasks) {
    switch (_sortBy) {
      case SortBy.dueDate:
        tasks.sort((a, b) {
          final da = _taskDueDate(a);
          final db = _taskDueDate(b);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return da.compareTo(db);
        });
      case SortBy.priority:
        tasks.sort((a, b) => _priorityRank(a).compareTo(_priorityRank(b)));
      case SortBy.manual:
        tasks.sort((a, b) => a.sequence.compareTo(b.sequence));
      case SortBy.createDate:
        tasks.sort((a, b) {
          final da = extractDate(a.createDate);
          final db = extractDate(b.createDate);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da);
        });
      case SortBy.writeDate:
        tasks.sort((a, b) {
          final da = extractDate(a.writeDate);
          final db = extractDate(b.writeDate);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da);
        });
      case SortBy.name:
        tasks.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      case SortBy.relevance:
      // Keep the backend order.
    }
  }

  DateTime? _taskDueDate(Node node) {
    return extractDate(node.properties[SystemPropertyUuids.taskDeadline]) ??
        extractDate(node.properties['due_date']) ??
        extractDate(node.properties['deadline']);
  }

  String? _taskPriorityValue(Node node) {
    final raw = node.properties[SystemPropertyUuids.taskPriority] ??
        node.properties['priority'];
    if (raw == null) return null;
    final formatted = formatPropertyValue(raw);
    return formatted == '-' ? null : formatted;
  }

  String? _taskNotes(Node node) {
    final raw = node.properties[SystemPropertyUuids.description] ??
        node.properties['description'];
    if (raw == null) return null;
    final formatted = formatPropertyValue(raw);
    return formatted == '-' ? null : formatted;
  }

  String? _taskReminder(Node node) {
    final raw = node.properties[SystemPropertyUuids.taskScheduled] ??
        node.properties['reminder'] ??
        node.properties['scheduled'];
    if (raw == null) return null;
    final formatted = formatPropertyValue(raw);
    return formatted == '-' ? null : formatted;
  }

  String? _parentUuid(Node node) {
    return node.pageUuid ?? node.parentUuid;
  }

  int _priorityRank(Node node) {
    final value = _taskPriorityValue(node);
    if (value == null) return 999;
    final lower = value.toLowerCase();
    if (lower.contains('critical') || lower.contains('urgent') || lower.contains('high')) {
      return 0;
    }
    if (lower.contains('medium') || lower.contains('normal')) return 1;
    if (lower.contains('low')) return 2;
    return 3;
  }

  void _openNode(Node node) {
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${node.uuid}');
  }

  void _showTaskDetail(Node task) {
    HapticFeedback.lightImpact();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          final due = _taskDueDate(task);
          final priority = _taskPriorityValue(task);
          final notes = _taskNotes(task);
          final reminder = _taskReminder(task);
          final parentUuid = _parentUuid(task);
          final tagsCount = task.tagsUuid.length;

          return SafeArea(
            child: Container(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                children: [
                  _buildSheetHandle(colors),
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      children: [
                        Text(
                          task.displayName,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (notes != null && notes.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            notes,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        if (due != null)
                          _buildDetailTile(
                            icon: MdiIcons.calendar,
                            label: 'Due date',
                            value: _formatDate(due),
                          ),
                        if (priority != null)
                          _buildDetailTile(
                            icon: MdiIcons.flag,
                            label: 'Priority',
                            value: priority,
                          ),
                        if (reminder != null)
                          _buildDetailTile(
                            icon: MdiIcons.bell,
                            label: 'Reminder',
                            value: reminder,
                          ),
                        _buildDetailTile(
                          icon: MdiIcons.tagOutline,
                          label: 'Tags',
                          value: tagsCount == 0 ? 'No tags' : '$tagsCount tag${tagsCount == 1 ? '' : 's'}',
                        ),
                        if (parentUuid != null && parentUuid.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(MdiIcons.fileDocumentOutline, color: colors.primary),
                            title: const Text('Parent page'),
                            trailing: Icon(MdiIcons.chevronRight, color: colors.onSurfaceVariant),
                            onTap: () {
                              HapticFeedback.lightImpact();
                              Navigator.of(context).pop();
                              context.push('${Routes.editor}/$parentUuid');
                            },
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            Navigator.of(context).pop();
                            _openNode(task);
                          },
                          icon: Icon(MdiIcons.openInApp),
                          label: const Text('Open in editor'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDetailTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: colors.primary),
      title: Text(label, style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12)),
      subtitle: Text(value, style: const TextStyle(fontSize: 16)),
    );
  }

  Future<void> _createTask() async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    final result = await showModalBottomSheet<TaskCreationResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TaskCreationSheet(
        onPickDueDate: () => _pickDate(title: 'Due date'),
      ),
    );

    if (result == null) return;
    if (!mounted) return;
    if (auth.dio == null) return;

    final repo = _repo(context);
    try {
      final task = await repo.createTask(result.name);
      final due = result.dueDate;
      if (due != null) {
        await repo.setNodeProperty(
          task.uuid,
          SystemPropertyUuids.taskDeadline,
          _formatDate(due),
        );
        await _scheduleReminderIfOpen(task.copyWithDueDate(due));
      }
      if (mounted) await _loadTasks(silent: true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<bool> _toggleTaskCompletion(Node task) async {
    HapticFeedback.selectionClick();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return false;

    final repo = _repo(context);
    try {
      final properties = await repo.fetchNodeProperties(task.uuid);
      final statusValue = properties.cast<NodePropertyValue?>().firstWhere(
            (p) => p?.property.uuid == SystemPropertyUuids.taskStatus,
            orElse: () => null,
          );

      if (statusValue == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Task status property not found')),
          );
        }
        return false;
      }

      var statusProperty = statusValue.property;
      if (statusProperty.options.isEmpty) {
        final available = await repo.fetchAvailableProperties(task.uuid);
        for (final p in available) {
          if (p.uuid == statusProperty.uuid) {
            statusProperty = p;
            break;
          }
        }
      }
      if (statusProperty.options.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Task status options not found')),
          );
        }
        return false;
      }

      final currentOption = statusValue.values.isNotEmpty
          ? _currentOption(statusValue.values.first, statusProperty.options)
          : null;
      final isClosed = currentOption != null && _closedStatuses.contains(currentOption.name);
      final targetName = isClosed ? 'Pending' : 'Done';
      final targetOption = statusProperty.options.firstWhere(
        (o) => o.name == targetName,
        orElse: () => throw StateError('Option "$targetName" not found'),
      );

      await repo.setNodeProperty(task.uuid, statusProperty.uuid, targetOption.uuid);

      if (TaskStatuses.closed.contains(targetOption.name)) {
        await repo.recordTaskCompletion(task.uuid);
      } else {
        final completionId = await repo.getMostRecentTaskCompletionId(task.uuid);
        if (completionId != null) {
          await repo.deleteTaskCompletion(task.uuid, completionId);
        }
      }

      if (TaskStatuses.closed.contains(targetOption.name)) {
        await _rescheduleReminderAfterCompletion(repo, task);
      } else {
        await _scheduleReminderIfOpen(task);
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update task: $e')),
        );
      }
      return false;
    }
  }

  /// Persists a completion toggle in the background. On failure the toggle
  /// is recorded in [_failedToggles] (so the row is not removed) and the
  /// list is silently reloaded to reconcile with the local cache.
  Future<bool> _onTaskCompletionToggled(Node task) async {
    _failedToggles.remove(task.uuid);
    final success = await _toggleTaskCompletion(task);
    if (mounted && !success) {
      _failedToggles.add(task.uuid);
      unawaited(_loadTasks(silent: true));
    }
    return success;
  }

  /// Removes a task from the current list without a full reload; called by
  /// [TaskRow] once its completion animation has finished.
  void _removeTaskLocally(String taskUuid) {
    if (!mounted) return;
    if (_failedToggles.remove(taskUuid)) {
      // The persist failed; keep the row so it can revert visually.
      return;
    }
    setState(() => _tasks.removeWhere((t) => t.uuid == taskUuid));
    if (_focusMode || _segment == TaskSegment.today) {
      unawaited(WidgetService.saveTodayTasks(_tasks));
    }
  }

  SelectionOption? _currentOption(dynamic value, List<SelectionOption> options) {
    final uuid = switch (value) {
      String s => s,
      Map<String, dynamic> m => m['selection_line_uuid'] as String?,
      _ => null,
    };
    if (uuid == null || uuid.isEmpty) return null;
    for (final o in options) {
      if (o.uuid == uuid) return o;
    }
    return null;
  }

  Future<void> _deleteTask(Node task) async {
    HapticFeedback.mediumImpact();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final repo = _repo(context);
    try {
      await repo.deleteNode(task.uuid);
      await _cancelReminder(task.uuid);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Task moved to trash'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                HapticFeedback.lightImpact();
                try {
                  await repo.restoreNode(task.uuid);
                  await _scheduleReminderIfOpen(task);
                  if (mounted) await _loadTasks();
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not restore task: $e')),
                    );
                  }
                }
              },
            ),
          ),
        );
        await _loadTasks();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete task: $e')),
        );
      }
    }
  }

  Future<void> _snoozeTask(Node task) async {
    final picked = await _pickDate(title: 'Change due date');
    if (picked == null) return;
    await _setTaskDueDate(task, picked);
  }

  Future<void> _setTaskDueDate(Node task, DateTime date) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final repo = _repo(context);
    try {
      await repo.setNodeProperty(
        task.uuid,
        SystemPropertyUuids.taskDeadline,
        _formatDate(date),
      );
      await _scheduleReminderIfOpen(task.copyWithDueDate(date));
      if (mounted) await _loadTasks();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update due date: $e')),
        );
      }
    }
  }

  Future<void> _scheduleReminderIfOpen(Node task) async {
    final due = _taskDueDate(task);
    if (due == null) return;

    // Only schedule for tasks that are not already closed.
    final repo = _repo(context);
    final properties = await repo.fetchNodeProperties(task.uuid);
    final statusValue = properties.cast<NodePropertyValue?>().firstWhere(
          (p) => p?.property.uuid == SystemPropertyUuids.taskStatus,
          orElse: () => null,
        );
    if (statusValue != null) {
      final options = statusValue.property.options;
      final currentUuid = statusValue.values.isNotEmpty
          ? _selectionUuid(statusValue.values.first)
          : null;
      final currentOption = options.cast<SelectionOption?>().firstWhere(
            (o) => o?.uuid == currentUuid,
            orElse: () => null,
          );
      if (currentOption != null && TaskStatuses.closed.contains(currentOption.name)) {
        return;
      }
    }

    final ruleJson = await repo.getTaskRecurrence(task.uuid);
    final rule = ruleJson == null ? null : RecurrenceRule.fromJson(ruleJson);
    if (rule == null || !rule.active) {
      await ReminderService.instance.scheduleTaskReminder(
        task.uuid,
        task.displayName,
        due,
      );
      return;
    }

    // Recurring task: expand the rule into the next occurrence dates and
    // schedule a reminder for each upcoming one.
    final completedCount = await repo.getTaskCompletionCount(task.uuid);
    final occurrences = occurrenceSeries(
      rule,
      due,
      count: ReminderService.maxOccurrenceReminders,
      completedCount: completedCount,
    );
    await ReminderService.instance.scheduleRecurringTaskReminders(
      task.uuid,
      task.displayName,
      occurrences,
    );
  }

  /// On completion a recurring task reschedules to the next occurrence
  /// instead of clearing the reminder outright.
  Future<void> _rescheduleReminderAfterCompletion(
    NodeRepository repo,
    Node task,
  ) async {
    final ruleJson = await repo.getTaskRecurrence(task.uuid);
    final rule = ruleJson == null ? null : RecurrenceRule.fromJson(ruleJson);
    if (rule == null || !rule.active) {
      await _cancelReminder(task.uuid);
      return;
    }

    final due = _taskDueDate(task) ?? DateTime.now();
    // Skip occurrences that are already in the past (e.g. completing an
    // overdue task) so the reminder fires in the future.
    var seed = nextOccurrence(rule, due);
    final now = DateTime.now();
    while (seed != null && seed.isBefore(now)) {
      seed = nextOccurrence(rule, seed);
    }

    final completedCount = await repo.getTaskCompletionCount(task.uuid);
    if (seed == null || hasEnded(rule, completedCount, seed)) {
      await _cancelReminder(task.uuid);
      return;
    }

    final occurrences = occurrenceSeries(
      rule,
      seed,
      count: ReminderService.maxOccurrenceReminders,
      completedCount: completedCount,
    );
    await ReminderService.instance.scheduleRecurringTaskReminders(
      task.uuid,
      task.displayName,
      occurrences,
    );
  }

  String? _selectionUuid(dynamic value) {
    return switch (value) {
      String s => s,
      Map<String, dynamic> m => m['selection_line_uuid'] as String?,
      _ => null,
    };
  }

  Future<void> _cancelReminder(String taskUuid) async {
    await ReminderService.instance.cancelTaskReminder(taskUuid);
  }

  Future<DateTime?> _pickDate({required String title}) async {
    final now = DateTime.now();
    DateTime? selected;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colors = Theme.of(context).colorScheme;
        return SafeArea(
          child: Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSheetHandle(colors),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                CalendarDatePicker(
                  initialDate: now,
                  firstDate: DateTime(now.year - 5),
                  lastDate: DateTime(now.year + 5),
                  onDateChanged: (date) {
                    selected = date;
                    Navigator.of(context).pop();
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
    return selected;
  }

  void _enterSelectionMode(Node task) {
    HapticFeedback.lightImpact();
    setState(() {
      _selectionMode = true;
      _selected.add(task.uuid);
    });
  }

  void _toggleSelection(Node task) {
    HapticFeedback.lightImpact();
    setState(() {
      if (_selected.contains(task.uuid)) {
        _selected.remove(task.uuid);
      } else {
        _selected.add(task.uuid);
      }
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _clearSelection() {
    HapticFeedback.lightImpact();
    setState(() {
      _selected.clear();
      _selectionMode = false;
    });
  }

  Future<void> _batchSetDueDate() async {
    if (_selected.isEmpty) return;
    final picked = await _pickDate(title: 'Set due date');
    if (picked == null) return;
    if (!mounted) return;

    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    final repo = _repo(context);

    try {
      final taskByUuid = <String, Node>{};
      for (final task in _tasks) {
        taskByUuid[task.uuid] = task;
      }
      for (final uuid in _selected) {
        await repo.setNodeProperty(uuid, SystemPropertyUuids.taskDeadline, _formatDate(picked));
        final task = taskByUuid[uuid];
        if (task != null) {
          await _scheduleReminderIfOpen(task.copyWithDueDate(picked));
        }
      }
      if (!mounted) return;
      _clearSelection();
      if (mounted) await _loadTasks();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not set due date: $e')),
        );
      }
    }
  }

  Future<void> _batchAddTag() async {
    if (_selected.isEmpty) return;
    final tag = await _showTagPicker();
    if (tag == null) return;
    if (!mounted) return;

    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    final repo = _repo(context);

    try {
      for (final uuid in _selected) {
        await repo.addTag(uuid, tag.uuid);
      }
      if (!mounted) return;
      _clearSelection();
      if (mounted) await _loadTasks();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add tag: $e')),
        );
      }
    }
  }

  Future<void> _batchComplete() async {
    if (_selected.isEmpty) return;
    final tasks = _tasks.where((t) => _selected.contains(t.uuid)).toList();
    _clearSelection();
    for (final task in tasks) {
      await _toggleTaskCompletion(task);
    }
    if (mounted) await _loadTasks(silent: true);
  }

  Future<void> _batchDelete() async {
    if (_selected.isEmpty) return;
    HapticFeedback.mediumImpact();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    final repo = _repo(context);

    final uuids = _selected.toList();
    _clearSelection();
    try {
      for (final uuid in uuids) {
        await repo.deleteNode(uuid);
        await _cancelReminder(uuid);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tasks moved to trash')),
        );
        await _loadTasks();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete tasks: $e')),
        );
      }
    }
  }

  Future<Node?> _showTagPicker() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return null;
    final repo = _repo(context);

    List<Node> tags;
    try {
      tags = await repo.fetchClasses();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load tags: $e')),
        );
      }
      return null;
    }

    if (!mounted) return null;
    return showModalBottomSheet<Node>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colors = Theme.of(context).colorScheme;
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                ),
                child: Column(
                  children: [
                    _buildSheetHandle(colors),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                      child: Text(
                        'Select a tag',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    Expanded(
                      child: tags.isEmpty
                          ? const Center(child: Text('No tags found'))
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: tags.length,
                              itemBuilder: (context, index) {
                                final tag = tags[index];
                                return ListTile(
                                  leading: Icon(MdiIcons.tagOutline, color: colors.primary),
                                  title: Text(tag.displayName),
                                  onTap: () {
                                    HapticFeedback.lightImpact();
                                    Navigator.of(context).pop(tag);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showSortSheet() async {
    final picked = await showModalBottomSheet<SortBy>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colors = Theme.of(context).colorScheme;
        return SafeArea(
          child: Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSheetHandle(colors),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Text(
                    'Sort by',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                ...SortBy.values.map((sort) {
                  final selected = sort == _sortBy;
                  return ListTile(
                    leading: Icon(
                      selected ? MdiIcons.checkCircle : MdiIcons.circleOutline,
                      color: selected ? colors.primary : colors.onSurfaceVariant,
                    ),
                    title: Text(sort.label),
                    onTap: () {
                      HapticFeedback.lightImpact();
                      Navigator.of(context).pop(sort);
                    },
                  );
                }),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    if (picked != null && picked != _sortBy) {
      setState(() => _sortBy = picked);
      await _loadTasks();
    }
  }

  Widget _buildSheetHandle(ColorScheme colors) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 8),
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: colors.onSurfaceVariant.withAlpha((0.35 * 255).round()),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_focusMode ? 'Today\'s focus' : 'Tasks'),
        actions: [
          IconButton(
            icon: Icon(_focusMode ? MdiIcons.target : MdiIcons.targetAccount),
            tooltip: _focusMode ? 'Exit focus mode' : 'Focus mode',
            color: _focusMode ? colors.primary : null,
            onPressed: () {
              HapticFeedback.lightImpact();
              setState(() {
                _focusMode = !_focusMode;
                if (_focusMode) _segment = TaskSegment.today;
              });
              _loadTasks();
            },
          ),
          IconButton(
            icon: Icon(MdiIcons.sortVariant),
            tooltip: 'Sort',
            onPressed: _showSortSheet,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadTasks,
        child: Column(
          children: [
            if (!_focusMode) _buildSegmentSelector(colors),
            Expanded(child: _buildContent(colors)),
          ],
        ),
      ),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton(
              onPressed: _createTask,
              tooltip: 'Create task',
              child: Icon(MdiIcons.plus),
            ),
      bottomNavigationBar: _selectionMode ? _buildSelectionBar(colors) : null,
    );
  }

  Widget _buildSegmentSelector(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: SegmentedButton<TaskSegment>(
        segments: TaskSegment.values
            .map(
              (s) => ButtonSegment<TaskSegment>(
                value: s,
                label: Text(s.label),
              ),
            )
            .toList(),
        selected: {_segment},
        onSelectionChanged: (selected) {
          HapticFeedback.lightImpact();
          setState(() => _segment = selected.first);
          _loadTasks();
        },
      ),
    );
  }

  Widget _buildContent(ColorScheme colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          EmptyState(
            icon: MdiIcons.alertCircleOutline,
            title: 'Could not load tasks',
            subtitle: _error,
          ),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: _loadTasks,
              icon: Icon(MdiIcons.refresh),
              label: const Text('Retry'),
            ),
          ),
        ],
      );
    }

    if (_tasks.isEmpty) {
      final message = _focusMode
          ? 'No tasks for today'
          : switch (_segment) {
              TaskSegment.all => 'No tasks',
              TaskSegment.undated => 'No undated tasks',
              _ => 'No ${_segment.label.toLowerCase()} tasks',
            };
      return ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Text(
                  message,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _createTask,
                  icon: Icon(MdiIcons.plus),
                  label: const Text('Create task'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: _segment == TaskSegment.upcoming && !_focusMode
          ? _buildGroupedUpcoming()
          : [_buildTaskCard(_tasks)],
    );
  }

  Widget _buildTaskCard(List<Node> tasks) {
    return FleetCard(
      child: Column(
        children: [
          for (var i = 0; i < tasks.length; i++) ...[
            _buildTaskRow(tasks[i]),
            if (i < tasks.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildGroupedUpcoming() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final byBucket = <_TaskBucket, List<Node>>{};
    for (final task in _tasks) {
      byBucket.putIfAbsent(_bucketFor(_taskDueDate(task), today), () => []).add(task);
    }
    final children = <Widget>[];
    for (final bucket in _TaskBucket.values) {
      final tasks = byBucket[bucket];
      if (tasks == null || tasks.isEmpty) continue;
      children.add(_buildSectionHeader(bucket.label, tasks.length));
      children.add(_buildTaskCard(tasks));
    }
    return children;
  }

  _TaskBucket _bucketFor(DateTime? due, DateTime today) {
    if (due == null) return _TaskBucket.noDate;
    final day = DateTime(due.year, due.month, due.day);
    final diff = day.difference(today).inDays;
    if (diff < 0) return _TaskBucket.overdue;
    if (diff == 0) return _TaskBucket.today;
    if (diff == 1) return _TaskBucket.tomorrow;
    if (diff <= 7) return _TaskBucket.thisWeek;
    return _TaskBucket.later;
  }

  Widget _buildSectionHeader(String label, int count) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskRow(Node task) {
    final colors = Theme.of(context).colorScheme;
    final completed = _segment == TaskSegment.completed;

    Widget content = TaskRow(
      title: task.displayName,
      completed: completed,
      dueDate: _taskDueDate(task),
      selectionMode: _selectionMode,
      selected: _selected.contains(task.uuid),
      onToggleComplete:
          _selectionMode ? null : () => _onTaskCompletionToggled(task),
      onAnimatedOut:
          _selectionMode ? null : () => _removeTaskLocally(task.uuid),
      onToggleSelected: () => _toggleSelection(task),
      onTap: _selectionMode ? () => _toggleSelection(task) : () => _showTaskDetail(task),
      onLongPress: _selectionMode ? null : () => _enterSelectionMode(task),
      onShowDetails: _selectionMode ? null : () => _showTaskDetail(task),
    );

    if (_selectionMode) return content;

    return Dismissible(
      key: ValueKey(task.uuid),
      direction: DismissDirection.horizontal,
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await _snoozeTask(task);
          return false;
        } else {
          await _deleteTask(task);
          return false;
        }
      },
      background: Container(
        color: colors.primaryContainer,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: Icon(MdiIcons.calendarClock, color: colors.onPrimaryContainer),
      ),
      secondaryBackground: Container(
        color: colors.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(MdiIcons.delete, color: colors.onErrorContainer),
      ),
      child: content,
    );
  }

  Widget _buildSelectionBar(ColorScheme colors) {
    return BottomAppBar(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Text('${_selected.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Text('selected'),
            const Spacer(),
            IconButton(
              icon: Icon(MdiIcons.calendar, color: colors.primary),
              tooltip: 'Set due date',
              onPressed: _batchSetDueDate,
            ),
            IconButton(
              icon: Icon(MdiIcons.tagPlus, color: colors.primary),
              tooltip: 'Add tag',
              onPressed: _batchAddTag,
            ),
            IconButton(
              icon: Icon(MdiIcons.checkCircle, color: colors.primary),
              tooltip: 'Complete',
              onPressed: _batchComplete,
            ),
            IconButton(
              icon: Icon(MdiIcons.delete, color: colors.error),
              tooltip: 'Delete',
              onPressed: _batchDelete,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Clear selection',
              onPressed: _clearSelection,
            ),
          ],
        ),
      ),
    );
  }
}
