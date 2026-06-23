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
  List<Node> _favorites = [];
  List<Node> _recents = [];
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
        repo.fetchFavorites(limit: 50),
        repo.fetchRecentPages(limit: 5),
        repo.getOrCreateDailyJournal(DateTime.now()),
      ]);
      setState(() {
        _favorites = results[0] as List<Node>;
        _recents = results[1] as List<Node>;
        _todayJournal = results[2] as Node;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<Node> _getOrCreateJournal(DateTime date) async {
    final auth = context.read<AuthProvider>();
    final repo = NodeRepository(dio: auth.dio!);
    return repo.getOrCreateDailyJournal(date);
  }

  void _openNode(Node node) {
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${node.id}');
  }

  void _openJournal({Node? journal}) {
    final target = journal ?? _todayJournal;
    if (target == null) return;
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${target.id}');
  }

  void _openCalendar() {
    HapticFeedback.lightImpact();
    final now = DateTime.now();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Jump to journal',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            CalendarDatePicker(
              initialDate: now,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
              onDateChanged: (date) async {
                Navigator.of(ctx).pop();
                setState(() => _loading = true);
                try {
                  final journal = await _getOrCreateJournal(date);
                  _openJournal(journal: journal);
                } catch (e) {
                  setState(() => _error = e.toString());
                } finally {
                  setState(() => _loading = false);
                }
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
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
            icon: const Icon(Icons.calendar_today_outlined),
            tooltip: 'Jump to journal',
            onPressed: _openCalendar,
          ),
          IconButton(
            icon: const Icon(Icons.edit_calendar_outlined),
            tooltip: "Today's journal",
            onPressed: _openJournal,
          ),
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
                  if (_favorites.isNotEmpty) ...[
                    const SectionTitle(icon: Icons.star_outline, label: 'Favorites'),
                    const SizedBox(height: 8),
                    FleetCard(
                      child: Column(
                        children: _favorites.asMap().entries.map((entry) {
                          final node = entry.value;
                          final isLast = entry.key == _favorites.length - 1;
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
                  ],
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
