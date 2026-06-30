import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/localization/material_localizations_override.dart';
import '../../core/routing/router.dart';
import '../../core/utils/color_presets.dart';
import '../../core/utils/view_mode_store.dart';
import '../../data/models/node.dart';
import '../../data/models/page_content.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../views/inbox_card_view.dart';
import '../views/node_view_mode.dart';
import '../widgets/empty_state.dart';
import '../widgets/fleet_card.dart';
import '../widgets/node_picker.dart';
import '../widgets/quick_capture_sheet.dart';
import '../widgets/view_mode_sheet.dart';

/// The Home tab is the workspace Inbox.
///
/// It shows uncaptured blocks in a Google Keep–style card grid by default.
/// Notes created via quick capture land here; users can open, move, or delete
/// them, and relocate them from the web app later.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Node> _inboxBlocks = [];
  Node? _todayJournal;
  Map<String, String> _classNames = {};
  bool _loading = true;
  String? _error;
  NodeViewMode _viewMode = NodeViewMode.card;
  final _viewModeStore = ViewModeStore();

  @override
  void initState() {
    super.initState();
    _loadDashboard();
    _loadViewMode();
  }

  Future<void> _loadViewMode() async {
    final mode = await _viewModeStore.getMode('inbox', NodeViewMode.card);
    if (mounted) setState(() => _viewMode = mode);
  }

  Future<void> _setViewMode(NodeViewMode mode) async {
    await _viewModeStore.setMode('inbox', mode);
    if (mounted) setState(() => _viewMode = mode);
  }

  Future<void> _loadDashboard() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);

    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        repo.fetchInboxContent(),
        repo.getOrCreateDailyJournal(DateTime.now()),
        repo.fetchClasses(),
      ]);
      final inboxContent = results[0] as PageContent;
      final classes = results[2] as List<Node>;
      if (mounted) {
        setState(() {
          _inboxBlocks = inboxContent.node.children;
          _todayJournal = results[1] as Node;
          _classNames = {for (final c in classes) c.uuid: c.displayName};
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Node> _getOrCreateJournal(DateTime date) async {
    final auth = context.read<AuthProvider>();
    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    return repo.getOrCreateDailyJournal(date);
  }

  void _openNode(Node node) {
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${node.uuid}');
  }

  Future<void> _moveBlock(Node block) async {
    final auth = context.read<AuthProvider>();
    final destination = await NodePicker.show(context, mode: NodePickerMode.page);
    if (destination == null) return;
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.moveNode(nodeUuid: block.uuid, parentUuid: destination.uuid);
      if (mounted) await _loadDashboard();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not move block: $e')),
        );
      }
    }
  }

  Future<void> _archiveBlock(Node block) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.archiveNode(block.uuid);
      if (mounted) await _loadDashboard();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not archive block: $e')),
        );
      }
    }
  }

  Future<void> _unarchiveBlock(Node block) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.unarchiveNode(block.uuid);
      if (mounted) await _loadDashboard();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not restore note: $e')),
        );
      }
    }
  }

  Future<void> _deleteBlock(Node block) async {
    final auth = context.read<AuthProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text('This note will be moved to trash.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.deleteNode(block.uuid);
      if (mounted) await _loadDashboard();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete block: $e')),
        );
      }
    }
  }

  Future<void> _restoreBlock(Node block) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.restoreNode(block.uuid);
      if (mounted) await _loadDashboard();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not restore note: $e')),
        );
      }
    }
  }

  Future<void> _changeColor(Node block) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final color = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => _ColorPickerSheet(selectedColor: block.color),
    );
    if (color == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      await repo.updateNode(block.uuid, color: color);
      if (mounted) await _loadDashboard();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not change color: $e')),
        );
      }
    }
  }

  void _showBlockActions(Node block) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(MdiIcons.paletteOutline),
              title: const Text('Change color'),
              onTap: () {
                Navigator.of(ctx).pop();
                _changeColor(block);
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.archiveOutline),
              title: const Text('Archive'),
              onTap: () {
                Navigator.of(ctx).pop();
                _archiveBlock(block);
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.fileMoveOutline),
              title: const Text('Move to page'),
              onTap: () {
                Navigator.of(ctx).pop();
                _moveBlock(block);
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.deleteOutline, color: Theme.of(ctx).colorScheme.error),
              title: Text('Delete', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () {
                Navigator.of(ctx).pop();
                _deleteBlock(block);
              },
            ),
          ],
        ),
      ),
    );
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
                      icon: Icon(MdiIcons.close),
                      tooltip: 'Close',
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
                      if (mounted) _openJournal(journal: journal);
                    } catch (e) {
                      if (mounted) setState(() => _error = e.toString());
                    } finally {
                      if (mounted) setState(() => _loading = false);
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
            const Text('Inbox'),
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
            icon: Icon(_viewMode.icon),
            tooltip: 'Change view',
            onPressed: () async {
              final mode = await ViewModeSheet.show(context, _viewMode);
              if (mode != null) await _setViewMode(mode);
            },
          ),
          _HomeOverflowMenu(
            onOpenJournal: _openCalendar,
            onOpenTodayJournal: _openJournal,
            onOpenSettings: () => context.push(Routes.settings),
            onOpenArchived: () => context.push(Routes.archived),
            onOpenAdvancedView: (route) => context.push(route),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadDashboard,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(colors),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openQuickNote,
        icon: Icon(MdiIcons.plus),
        label: const Text('Note'),
      ),
    );
  }

  Widget _buildBody(ColorScheme colors) {
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

    if (_inboxBlocks.isEmpty) {
      return ListView(
        children: [
          EmptyState(
            icon: MdiIcons.lightbulbOutline,
            title: 'Inbox is empty',
            subtitle: 'Tap + to capture a note, photo, or voice memo.',
          ),
        ],
      );
    }

    if (_viewMode == NodeViewMode.card) {
      return InboxCardView(
        blocks: _inboxBlocks,
        classNames: _classNames,
        onBlockTap: _openNode,
        onBlockLongPress: _showBlockActions,
        onBlockArchive: _archiveBlock,
        onBlockDelete: _deleteBlock,
        onBlockArchiveUndo: _unarchiveBlock,
        onBlockDeleteUndo: _restoreBlock,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _inboxBlocks.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final block = _inboxBlocks[index];
        return Dismissible(
          key: ValueKey(block.uuid),
          direction: DismissDirection.horizontal,
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.startToEnd) {
              HapticFeedback.lightImpact();
              await _archiveBlock(block);
              if (mounted) {
                _showUndoSnackBar(
                  this.context,
                  message: 'Note archived',
                  onUndo: () => _unarchiveBlock(block),
                );
              }
              return false;
            }
            final confirmed = await _confirmDelete(block);
            if (confirmed && mounted) {
              _showUndoSnackBar(
                this.context,
                message: 'Note deleted',
                onUndo: () => _restoreBlock(block),
              );
            }
            return false;
          },
          background: _SwipeBackground(
            alignment: Alignment.centerLeft,
            icon: MdiIcons.archiveOutline,
            label: 'Archive',
            color: colors.secondaryContainer,
            foregroundColor: colors.onSecondaryContainer,
          ),
          secondaryBackground: _SwipeBackground(
            alignment: Alignment.centerRight,
            icon: MdiIcons.deleteOutline,
            label: 'Delete',
            color: colors.errorContainer,
            foregroundColor: colors.onErrorContainer,
          ),
          child: FleetCard(
            child: InkWell(
              onTap: () => _openNode(block),
              onLongPress: () => _showBlockActions(block),
              borderRadius: BorderRadius.circular(20),
              child: _InboxListTile(
                block: block,
                classNames: _classNames,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _confirmDelete(Node block) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text('This note will be moved to trash.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (result == true) {
      HapticFeedback.mediumImpact();
      await _deleteBlock(block);
      return true;
    }
    return false;
  }

  void _showUndoSnackBar(
    BuildContext context, {
    required String message,
    required VoidCallback onUndo,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            HapticFeedback.lightImpact();
            onUndo();
          },
        ),
      ),
    );
  }
}

/// List tile for an Inbox block in list view.
class _InboxListTile extends StatelessWidget {
  const _InboxListTile({
    required this.block,
    required this.classNames,
  });

  final Node block;
  final Map<String, String> classNames;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chipColor = colors.primaryContainer;
    final chipFg = colors.onPrimaryContainer;

    final classLabels = block.classesUuid
        .map((uuid) => classNames[uuid])
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .take(3)
        .toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: ColorPresets.fromHex(block.color),
              shape: BoxShape.circle,
              border: Border.all(
                color: colors.outline.withAlpha((0.2 * 255).round()),
                width: 1,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  block.displayName,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (classLabels.isNotEmpty || block.isTask)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (block.isTask)
                          _ListChip(label: 'Task', backgroundColor: chipColor, foregroundColor: chipFg),
                        ...classLabels.map((label) => _ListChip(
                              label: label,
                              backgroundColor: chipColor,
                              foregroundColor: chipFg,
                            )),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Icon(MdiIcons.chevronRight, color: colors.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _ListChip extends StatelessWidget {
  const _ListChip({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foregroundColor,
              fontWeight: FontWeight.w500,
            ),
      ),
    );
  }
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.icon,
    required this.label,
    required this.color,
    required this.foregroundColor,
  });

  final Alignment alignment;
  final IconData icon;
  final String label;
  final Color color;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: foregroundColor),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: foregroundColor,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet for picking a note color.
class _ColorPickerSheet extends StatelessWidget {
  const _ColorPickerSheet({this.selectedColor});

  final String? selectedColor;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Note color',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _ColorOption(
                  color: ColorPresets.fromHex(ColorPresets.defaultHex),
                  label: 'Default',
                  isSelected: (selectedColor == null || selectedColor == ColorPresets.defaultHex),
                  onTap: () => Navigator.of(context).pop(ColorPresets.defaultHex),
                ),
                ...ColorPresets.entries.map((entry) {
                  final (hex, label) = entry;
                  return _ColorOption(
                    color: ColorPresets.fromHex(hex),
                    label: label,
                    isSelected: selectedColor == hex,
                    onTap: () => Navigator.of(context).pop(hex),
                  );
                }),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorOption extends StatelessWidget {
  const _ColorOption({
    required this.color,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
          },
          borderRadius: BorderRadius.circular(24),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outline.withAlpha((0.2 * 255).round()),
                width: isSelected ? 3 : 1,
              ),
            ),
            child: isSelected
                ? Icon(
                    MdiIcons.check,
                    color: ColorPresets.foregroundFor(color),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _AdvancedView {
  _AdvancedView({required this.label, required this.icon});

  final String label;
  final IconData icon;

  static final graph = _AdvancedView(label: 'Graph', icon: MdiIcons.lanConnect);
  static final whiteboard = _AdvancedView(label: 'Whiteboard', icon: MdiIcons.draw);
  static final timeline = _AdvancedView(label: 'Timeline', icon: MdiIcons.timeline);
  static final gantt = _AdvancedView(label: 'Gantt', icon: MdiIcons.viewWeekOutline);
  static final chart = _AdvancedView(label: 'Chart', icon: MdiIcons.chartBar);
  static final pivot = _AdvancedView(label: 'Pivot', icon: MdiIcons.tablePivot);
  static final query = _AdvancedView(label: 'Query builder', icon: MdiIcons.fileTree);
}

/// Overflow menu for the Home app bar.
class _HomeOverflowMenu extends StatelessWidget {
  const _HomeOverflowMenu({
    required this.onOpenJournal,
    required this.onOpenTodayJournal,
    required this.onOpenSettings,
    required this.onOpenArchived,
    required this.onOpenAdvancedView,
  });

  final VoidCallback onOpenJournal;
  final VoidCallback onOpenTodayJournal;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenArchived;
  final ValueChanged<String> onOpenAdvancedView;

  static final _advancedViews = <({_AdvancedView view, String route})>[
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
      tooltip: 'More',
      icon: Icon(MdiIcons.dotsVertical),
      onSelected: (value) {
        HapticFeedback.lightImpact();
        switch (value) {
          case 'journal':
            onOpenJournal();
          case 'today':
            onOpenTodayJournal();
          case 'settings':
            onOpenSettings();
          case 'archived':
            onOpenArchived();
          default:
            onOpenAdvancedView(value);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: 'today',
          child: ListTile(
            leading: Icon(MdiIcons.calendarEditOutline),
            title: Text("Today's journal"),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
        ),
        PopupMenuItem<String>(
          value: 'journal',
          child: ListTile(
            leading: Icon(MdiIcons.calendarOutline),
            title: Text('Jump to journal'),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
        ),
        PopupMenuItem<String>(
          value: 'archived',
          child: ListTile(
            leading: Icon(MdiIcons.archiveOutline),
            title: Text('Archived'),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
        ),
        PopupMenuItem<String>(
          value: 'settings',
          child: ListTile(
            leading: Icon(MdiIcons.cogOutline),
            title: Text('Settings'),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
        ),
        const PopupMenuDivider(),
        ..._advancedViews.map(
          (item) => PopupMenuItem<String>(
            value: item.route,
            child: ListTile(
              leading: Icon(item.view.icon),
              title: Text(item.view.label),
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
      ],
    );
  }
}
