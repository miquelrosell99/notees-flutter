import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/capture_types.dart';
import '../../../core/routing/router.dart';
import '../../../core/utils/color_presets.dart';
import '../../../core/utils/node_display_name.dart';
import '../../../core/utils/view_mode_store.dart';
import '../../../data/models/node.dart';
import '../../../data/models/page_content.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../domain/models/search_filters.dart';
import '../../auth/providers/auth_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../../../shared/views/inbox_card_view.dart';
import '../../../shared/views/node_view_mode.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../search/widgets/filter_bottom_sheet.dart';
import '../../../shared/widgets/fleet_card.dart';
import '../../../shared/widgets/node_picker.dart';
import '../../../shared/widgets/skeletons.dart';
import '../../capture/widgets/quick_capture_sheet.dart';
import '../../../shared/widgets/view_mode_sheet.dart';

/// The workspace Inbox, shown as the default Home tab.
///
/// It shows uncaptured blocks in a Google Keep–style card grid by default.
/// Notes created via quick capture land here; users can open, move, or delete
/// them, and relocate them from the web app later.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
  /// Reloads dashboard data from the server/cache. Called by the shell after a
  /// successful quick capture so the new note appears immediately.
  void reload() => _loadDashboard();
  List<Node> _inboxBlocks = [];
  Map<String, Node> _classIndex = {};
  bool _loading = true;
  String? _error;
  NodeViewMode _viewMode = NodeViewMode.card;
  final _viewModeStore = ViewModeStore();
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadDashboard();
    _loadViewMode();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchSubmitted(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    context.push(Routes.search, extra: {'query': trimmed});
  }

  Future<void> _openCaptureSheet() async {
    HapticFeedback.lightImpact();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => QuickCaptureSheet(
        initialType: QuickCaptureType.note,
        onSaved: _loadDashboard,
      ),
    );
  }

  Future<void> _openQueryBuilder() async {
    HapticFeedback.lightImpact();
    final filters = await FilterBottomSheet.show(
      context,
      const SearchFilters(),
    );
    if (filters == null) return;
    if (!mounted) return;
    context.push(Routes.search, extra: {'filters': filters});
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
        repo.fetchClasses(),
      ]);
      final inboxContent = results[0] as PageContent;
      final classes = results[1] as List<Node>;
      if (mounted) {
        setState(() {
          _inboxBlocks = inboxContent.node.children;
          _classIndex = {for (final c in classes) c.uuid: c};
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
      showDragHandle: true,
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
      showDragHandle: true,
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: 'Search notes, tasks, pages...',
            prefixIcon: Icon(MdiIcons.magnify),
            suffixIcon: IconButton(
              icon: Icon(MdiIcons.tune),
              tooltip: 'Advanced search',
              onPressed: _openQueryBuilder,
            ),
            filled: true,
            fillColor: colors.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
          onSubmitted: _onSearchSubmitted,
        ),
        actions: [
          IconButton(
            icon: Icon(_viewMode.icon),
            tooltip: 'Change view',
            onPressed: () async {
              final mode = await ViewModeSheet.show(context, _viewMode);
              if (!mounted) return;
              if (mode != null) await _setViewMode(mode);
            },
          ),
          _HomeOverflowMenu(
            onOpenSettings: () => context.push(Routes.settings),
            onOpenArchived: () => context.push(Routes.archived),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadDashboard,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _loading
              ? const CardGridSkeleton(key: ValueKey('dashboard-loading'))
              : _buildBody(colors, settings),
        ),
      ),

    );
  }

  Widget _buildBody(ColorScheme colors, SettingsProvider settings) {
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          EmptyState(
            icon: MdiIcons.alertCircleOutline,
            title: 'Could not load dashboard',
            subtitle: _error,
          ),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: _loadDashboard,
              icon: Icon(MdiIcons.refresh),
              label: const Text('Retry'),
            ),
          ),
        ],
      );
    }

    if (_inboxBlocks.isEmpty) {
      return ListView(
        children: [
          EmptyState(
            icon: MdiIcons.inboxOutline,
            title: 'Nothing here yet',
            subtitle: 'Tap + to capture a note, task, photo, or voice memo.',
          ),
          const SizedBox(height: 20),
          Center(
            child: FilledButton.icon(
              onPressed: _openCaptureSheet,
              icon: Icon(MdiIcons.plus),
              label: const Text('Capture a note'),
            ),
          ),
        ],
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_viewMode == NodeViewMode.card)
            InboxCardView(
              blocks: _inboxBlocks,
              classIndex: _classIndex,
              onBlockTap: _openNode,
              onBlockLongPress: _showBlockActions,
              onBlockArchive: _archiveBlock,
              onBlockDelete: _deleteBlock,
              onBlockArchiveUndo: _unarchiveBlock,
              onBlockDeleteUndo: _restoreBlock,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
            )
          else
            Padding(
              padding: const EdgeInsets.all(16),
              child: FleetCard(
                child: Column(
                  children: _inboxBlocks.asMap().entries.map((entry) {
                    final block = entry.value;
                    final isLast = entry.key == _inboxBlocks.length - 1;
                    return Column(
                      children: [
                        Dismissible(
                          key: ValueKey(block.uuid),
                          direction: DismissDirection.horizontal,
                          confirmDismiss: (direction) async {
                            if (direction == DismissDirection.startToEnd) {
                              HapticFeedback.lightImpact();
                              await _archiveBlock(block);
                              if (mounted) {
                                _showUndoSnackBar(
                                  context,
                                  message: 'Note archived',
                                  onUndo: () => _unarchiveBlock(block),
                                );
                              }
                              return false;
                            }
                            final confirmed = await _confirmDelete(block);
                            if (confirmed && mounted) {
                              _showUndoSnackBar(
                                context,
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
                          child: InkWell(
                            onTap: () => _openNode(block),
                            onLongPress: () => _showBlockActions(block),
                            borderRadius: BorderRadius.circular(20),
                            child: _InboxListTile(
                              block: block,
                              classIndex: _classIndex,
                            ),
                          ),
                        ),
                        if (!isLast) const Divider(height: 1),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
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
    required this.classIndex,
  });

  final Node block;
  final Map<String, Node> classIndex;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chipColor = colors.primaryContainer;
    final chipFg = colors.onPrimaryContainer;

    final classes = block.classesUuid
        .map((uuid) => classIndex[uuid])
        .whereType<Node>()
        .where((cls) => cls.displayName.isNotEmpty)
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
                  resolveNodeDisplayName(block, dateFormat: context.read<SettingsProvider>().dateFormat),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (classes.isNotEmpty || block.isTask)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (block.isTask)
                          _ListChip(label: 'Task', backgroundColor: chipColor, foregroundColor: chipFg),
                        ...classes.map((cls) {
                          final color = ColorPresets.tryResolve(cls.color);
                          return _ListChip(
                            label: cls.displayName,
                            backgroundColor: color ?? chipColor,
                            foregroundColor: color != null ? ColorPresets.foregroundFor(color) : chipFg,
                          );
                        }),
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

/// Overflow menu for the Home app bar, shown as a bottom sheet.
class _HomeOverflowMenu extends StatelessWidget {
  const _HomeOverflowMenu({
    required this.onOpenSettings,
    required this.onOpenArchived,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback onOpenArchived;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'More',
      icon: Icon(MdiIcons.dotsVertical),
      onPressed: () => _showMenu(context),
    );
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        void select(VoidCallback action) {
          HapticFeedback.lightImpact();
          Navigator.of(sheetContext).pop();
          action();
        }

        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _menuTile(
                    icon: MdiIcons.archiveOutline,
                    label: 'Archived',
                    onTap: () => select(onOpenArchived),
                  ),
                  _menuTile(
                    icon: MdiIcons.cogOutline,
                    label: 'Settings',
                    onTap: () => select(onOpenSettings),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _menuTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      onTap: onTap,
    );
  }
}
