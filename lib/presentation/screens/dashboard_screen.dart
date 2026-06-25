import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/localization/material_localizations_override.dart';
import '../../core/routing/router.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
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
  Set<String> _favoriteUuids = {};
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
        repo.fetchFavoriteUuids(),
      ]);
      setState(() {
        _favorites = results[0] as List<Node>;
        _recents = results[1] as List<Node>;
        _todayJournal = results[2] as Node;
        _favoriteUuids = (results[3] as List<String>).toSet();
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
    context.push('${Routes.editor}/${node.uuid}');
  }

  Future<void> _toggleFavorite(Node node) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final isFavorite = _favoriteUuids.contains(node.uuid);
    setState(() {
      if (isFavorite) {
        _favoriteUuids.remove(node.uuid);
        _favorites.removeWhere((n) => n.uuid == node.uuid);
      } else {
        _favoriteUuids.add(node.uuid);
      }
    });

    try {
      final repo = NodeRepository(dio: auth.dio!);
      if (isFavorite) {
        await repo.removeFavorite(node.uuid);
      } else {
        await repo.addFavorite(node.uuid);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (isFavorite) {
            _favoriteUuids.add(node.uuid);
            _favorites.add(node);
          } else {
            _favoriteUuids.remove(node.uuid);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update favorite: $e')),
        );
      }
    }
  }

  void _openJournal({Node? journal}) {
    final target = journal ?? _todayJournal;
    if (target == null) return;
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${target.uuid}');
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
      builder: (ctx) {
        final settings = ctx.read<SettingsProvider>();
        return SafeArea(
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
              Localizations.override(
                context: ctx,
                delegates: [
                  GlobalMaterialLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  FirstDayOfWeekLocalizationsDelegate(settings.firstDayOfWeek),
                ],
                child: CalendarDatePicker(
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
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
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
    final settings = context.watch<SettingsProvider>();
    final todayLabel = formatDateWithSettings(DateTime.now(), settings.dateFormat);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Notees'),
            Text(
              todayLabel,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
          ],
        ),
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
            tooltip: 'Settings',
            onPressed: () => context.push(Routes.settings),
          ),
          _AdvancedViewsMenu(
            onSelected: (route) => context.push(route),
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
                  if (settings.showSidebarFavorites && _favorites.isNotEmpty) ...[
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
                                trailing: _favoriteTrailing(node),
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
                  if (settings.showSidebarRecents) ...[
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
                                      trailing: _favoriteTrailing(node),
                                      onTap: () => _openNode(node),
                                    ),
                                    if (!isLast) const Divider(height: 1),
                                  ],
                                );
                              }).toList(),
                            ),
                    ),
                  ],
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

  Widget _favoriteTrailing(Node node) {
    final colors = Theme.of(context).colorScheme;
    final isFavorite = _favoriteUuids.contains(node.uuid);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            isFavorite ? Icons.star : Icons.star_border,
            color: isFavorite ? colors.primary : colors.onSurfaceVariant,
          ),
          tooltip: isFavorite ? 'Remove favorite' : 'Add favorite',
          onPressed: () => _toggleFavorite(node),
        ),
        Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
      ],
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

/// Popup menu that opens the advanced React-based views.
class _AdvancedViewsMenu extends StatelessWidget {
  const _AdvancedViewsMenu({required this.onSelected});

  final ValueChanged<String> onSelected;

  static const _items = <({_AdvancedView view, String route})>[
    (view: _AdvancedView.graph, route: Routes.graph),
    (view: _AdvancedView.timeline, route: Routes.timeline),
    (view: _AdvancedView.gantt, route: Routes.gantt),
    (view: _AdvancedView.chart, route: Routes.chart),
    (view: _AdvancedView.pivot, route: Routes.pivot),
    (view: _AdvancedView.whiteboard, route: Routes.whiteboard),
    (view: _AdvancedView.query, route: Routes.query),
  ];

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Advanced views',
      icon: const Icon(Icons.more_vert),
      onSelected: (route) {
        HapticFeedback.lightImpact();
        onSelected(route);
      },
      itemBuilder: (context) => _items
          .map(
            (item) => PopupMenuItem<String>(
              value: item.route,
              child: ListTile(
                leading: Icon(item.view.icon),
                title: Text(item.view.label),
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ),
          )
          .toList(),
    );
  }
}

enum _AdvancedView {
  graph(label: 'Graph', icon: Icons.hub_outlined),
  whiteboard(label: 'Whiteboard', icon: Icons.draw_outlined),
  timeline(label: 'Timeline', icon: Icons.timeline_outlined),
  gantt(label: 'Gantt', icon: Icons.view_week_outlined),
  chart(label: 'Chart', icon: Icons.bar_chart_outlined),
  pivot(label: 'Pivot', icon: Icons.pivot_table_chart_outlined),
  query(label: 'Query builder', icon: Icons.account_tree_outlined);

  const _AdvancedView({required this.label, required this.icon});

  final String label;
  final IconData icon;
}
