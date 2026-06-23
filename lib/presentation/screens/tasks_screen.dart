import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../data/models/node.dart';
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
    context.push('${Routes.editor}/${node.id}');
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
                    leading: Icon(
                      Icons.radio_button_unchecked,
                      color: colors.primary,
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
