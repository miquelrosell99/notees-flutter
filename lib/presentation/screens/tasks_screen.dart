import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../data/models/node.dart';
import '../../data/models/property.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/fleet_card.dart';

/// Dedicated open tasks list.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  List<Node> _tasks = [];
  bool _loading = true;
  String? _error;

  static const _taskStatusUuid = '00000000-0000-0000-0003-000000000001';
  static const _closedStatuses = {'Done', 'Cancelled'};

  @override
  void initState() {
    super.initState();
    _loadTasks();
  }

  Future<void> _loadTasks() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!);
      final tasks = await repo.fetchTasks(includeComplete: false, pageSize: 100);
      setState(() {
        _tasks = tasks;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  void _openNode(Node node) {
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${node.uuid}');
  }

  Future<void> _createTask() async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('New task'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Task name'),
            onSubmitted: (value) => Navigator.of(ctx).pop(value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );

    if (name == null || name.isEmpty) return;
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!);
      await repo.createTask(name);
      await _loadTasks();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleTaskCompletion(Node task) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final repo = NodeRepository(dio: auth.dio!);
    try {
      final properties = await repo.fetchNodeProperties(task.uuid);
      final statusValue = properties.cast<NodePropertyValue?>().firstWhere(
            (p) => p?.property.uuid == _taskStatusUuid,
            orElse: () => null,
          );

      if (statusValue == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Task status property not found')),
          );
        }
        return;
      }

      final currentOptionUuid = statusValue.values.isNotEmpty
          ? statusValue.values.first as String?
          : null;
      final currentOption = statusValue.property.options.firstWhere(
        (o) => o.uuid == currentOptionUuid,
        orElse: () => statusValue.property.options.first,
      );
      final isClosed = _closedStatuses.contains(currentOption.name);
      final targetName = isClosed ? 'Pending' : 'Done';
      final targetOption = statusValue.property.options.firstWhere(
        (o) => o.name == targetName,
        orElse: () => throw StateError('Option "$targetName" not found'),
      );

      await repo.setNodeProperty(task.uuid, statusValue.property.uuid, targetOption.uuid);
      await _loadTasks();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update task: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tasks'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadTasks,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(colors),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createTask,
        tooltip: 'Create task',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildContent(ColorScheme colors) {
    if (_error != null) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(_error!, style: TextStyle(color: colors.error)),
          ),
        ],
      );
    }

    if (_tasks.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(child: Text('No open tasks')),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FleetCard(
          child: Column(
            children: _tasks.asMap().entries.map((entry) {
              final task = entry.value;
              final isLast = entry.key == _tasks.length - 1;
              return Column(
                children: [
                  ListTile(
                    leading: IconButton(
                      icon: Icon(
                        Icons.radio_button_unchecked,
                        color: colors.primary,
                      ),
                      tooltip: 'Toggle completion',
                      onPressed: () => _toggleTaskCompletion(task),
                    ),
                    title: Text(task.displayName),
                    trailing: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
                    onTap: () => _openNode(task),
                  ),
                  if (!isLast) const Divider(height: 1),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}
