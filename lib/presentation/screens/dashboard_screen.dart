import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/fleet_card.dart';
import '../widgets/quick_capture_sheet.dart';
import '../widgets/section_title.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Node> _recents = [];
  List<Node> _tasks = [];
  Node? _todayJournal;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDashboard();
  }

  Future<void> _loadDashboard() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    final repo = NodeRepository(dio: auth.dio!);

    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        repo.fetchRecentPages(limit: 5),
        repo.fetchTasks(includeComplete: false, pageSize: 5),
        repo.getOrCreateDailyJournal(DateTime.now()),
      ]);
      setState(() {
        _recents = results[0] as List<Node>;
        _tasks = results[1] as List<Node>;
        _todayJournal = results[2] as Node;
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

  void _openJournal() {
    if (_todayJournal == null) return;
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${_todayJournal!.id}');
  }

  void _openQuickNote() {
    HapticFeedback.lightImpact();
    _showQuickNoteSheet(context);
  }

  Future<void> _showQuickNoteSheet(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => QuickCaptureSheet(
        onSaved: _loadDashboard,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notees'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(Routes.settings),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadDashboard,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                  FleetCard(
                    onTap: _openJournal,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: colors.primaryContainer,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              Icons.calendar_today_outlined,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "Today's journal",
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                Text(
                                  _todayJournal?.displayName ?? 'Open daily note',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const SectionTitle(icon: Icons.access_time, label: 'Recent pages'),
                  const SizedBox(height: 8),
                  FleetCard(
                    child: _recents.isEmpty
                        ? _buildEmptyTile(context, 'No recent pages')
                        : Column(
                            children: _recents.asMap().entries.map((entry) {
                              final node = entry.value;
                              final isLast = entry.key == _recents.length - 1;
                              return Column(
                                children: [
                                  ListTile(
                                    leading: Icon(
                                      _iconForNode(node),
                                      color: colors.onSurfaceVariant,
                                    ),
                                    title: Text(node.displayName),
                                    trailing: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
                                    onTap: () => _openNode(node),
                                  ),
                                  if (!isLast) const Divider(height: 1),
                                ],
                              );
                            }).toList(),
                          ),
                  ),
                  const SizedBox(height: 28),
                  const SectionTitle(icon: Icons.check_circle_outline, label: 'Open tasks'),
                  const SizedBox(height: 8),
                  FleetCard(
                    child: _tasks.isEmpty
                        ? _buildEmptyTile(context, 'No open tasks')
                        : Column(
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
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openQuickNote,
        icon: const Icon(Icons.add),
        label: const Text('Note'),
      ),
    );
  }

  Widget _buildEmptyTile(BuildContext context, String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          message,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  IconData _iconForNode(Node node) {
    if (node.isJournal) return Icons.calendar_today_outlined;
    if (node.isTask) return Icons.check_circle_outline;
    return node.icon?.isNotEmpty == true ? Icons.description_outlined : Icons.description_outlined;
  }
}
