import 'package:material_ui/material_ui.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/routing/router.dart';
import '../../../data/repositories/node_repository.dart';
import '../../auth/providers/auth_provider.dart';
import '../../search/widgets/command_palette.dart';
import '../../capture/widgets/quick_capture_sheet.dart';
import './home_screen.dart';
import '../../editor/screens/journal_continuous_screen.dart';
import '../../library/screens/library_screen.dart';
import '../../tasks/screens/tasks_screen.dart';

/// Main app shell with a bottom navigation bar.
///
/// Only the active tab is built; off-screen tabs are dropped to keep memory
/// usage low and ensure fresh data on each visit.
///
/// A global command palette is available anywhere in the shell via Ctrl/Cmd+K.
class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> {
  static const _tabCount = 4;

  late int _currentIndex =
      widget.initialIndex >= 0 && widget.initialIndex < _tabCount
          ? widget.initialIndex
          : 0;
  final _homeKey = GlobalKey<HomeScreenState>();
  final _scrollControllers =
      List.generate(_tabCount, (_) => ScrollController());

  final _destinations = <_NavDestination>[
    _NavDestination(
      label: 'Home',
      icon: MdiIcons.homeOutline,
      selectedIcon: MdiIcons.home,
    ),
    _NavDestination(
      label: 'Tasks',
      icon: MdiIcons.checkCircleOutline,
      selectedIcon: MdiIcons.checkCircle,
    ),
    _NavDestination(
      label: 'Journal',
      icon: MdiIcons.calendarOutline,
      selectedIcon: MdiIcons.calendar,
    ),
    _NavDestination(
      label: 'Library',
      icon: MdiIcons.bookshelf,
      selectedIcon: MdiIcons.bookshelf,
    ),
  ];

  /// Secondary targets, phone: behind the drag-pill sheet. On the rail they
  /// are appended as regular destinations.
  final _moreDestinations = <_NavDestination>[
    _NavDestination(
      label: 'Cards',
      icon: MdiIcons.cardsPlayingOutline,
      selectedIcon: MdiIcons.cardsPlaying,
    ),
    _NavDestination(
      label: 'Graph',
      icon: MdiIcons.graphOutline,
      selectedIcon: MdiIcons.graph,
    ),
    _NavDestination(
      label: 'Notifications',
      icon: MdiIcons.bellOutline,
      selectedIcon: MdiIcons.bell,
    ),
    _NavDestination(
      label: 'Settings',
      icon: MdiIcons.cogOutline,
      selectedIcon: MdiIcons.cog,
    ),
  ];

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    for (final controller in _scrollControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyK) return false;

    final keyboard = HardwareKeyboard.instance;
    final hasModifier = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (!hasModifier) return false;

    _openSearch();
    return true;
  }

  Future<void> _openSearch() async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
    final result = await CommandPalette.show(context, repo);

    if (!mounted || result == null) return;

    switch (result) {
      case StaticCommand(action: CommandPaletteAction.inbox):
        setState(() => _currentIndex = 0);
      case StaticCommand(action: CommandPaletteAction.tasks):
        setState(() => _currentIndex = 1);
      case StaticCommand(action: CommandPaletteAction.cards):
        context.push(Routes.cards);
      case StaticCommand(action: CommandPaletteAction.journals):
        setState(() => _currentIndex = 2);
      case StaticCommand(action: CommandPaletteAction.library):
        setState(() => _currentIndex = 3);
      case StaticCommand(action: CommandPaletteAction.journalToday):
        context.push(Routes.journal);
      case StaticCommand(action: CommandPaletteAction.graph):
        context.push(Routes.graph);
      case StaticCommand(action: CommandPaletteAction.settings):
        context.push(Routes.settings);
      case NodeCommand(node: final node):
        context.push('${Routes.editor}/${node.uuid}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;
    final useRail = width >= 600;

    return Scaffold(
      body: Row(
        children: [
          if (useRail)
            NavigationRail(
              selectedIndex: _currentIndex,
              onDestinationSelected: _onDestinationSelected,
              backgroundColor: theme.colorScheme.surface,
              indicatorColor: theme.colorScheme.primaryContainer,
              labelType: NavigationRailLabelType.all,
              destinations: [
                ..._destinations.map(
                  (d) => NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
                ),
                NavigationRailDestination(
                  icon: Icon(MdiIcons.magnify),
                  selectedIcon: Icon(MdiIcons.magnify),
                  label: Text('Search'),
                ),
                ..._moreDestinations.map(
                  (d) => NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
                ),
              ],
            ),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: useRail
          ? null
          : FloatingActionButton(
              onPressed: _openCaptureSheet,
              tooltip: 'Capture',
              child: Icon(MdiIcons.plus),
            ),
      floatingActionButtonLocation:
          useRail ? null : FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: useRail
          ? null
          : ColoredBox(
              color: theme.colorScheme.surface,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _NavPill(
                    key: const Key('nav-more-pill'),
                    onExpand: _openMoreSheet,
                  ),
                  NavigationBar(
                    selectedIndex: _currentIndex,
                    onDestinationSelected: _onDestinationSelected,
                    backgroundColor: theme.colorScheme.surface,
                    indicatorColor: theme.colorScheme.primaryContainer,
                    destinations: [
                      ..._destinations.map(
                        (d) => NavigationDestination(
                          icon: Icon(d.icon),
                          selectedIcon: Icon(d.selectedIcon),
                          label: d.label,
                        ),
                      ),
                      NavigationDestination(
                        icon: Icon(MdiIcons.magnify),
                        selectedIcon: Icon(MdiIcons.magnify),
                        label: 'Search',
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  void _onDestinationSelected(int index) {
    if (index >= _destinations.length) {
      _onExtraSelected(index - _destinations.length);
      return;
    }
    HapticFeedback.lightImpact();
    if (index == _currentIndex) {
      final controller = _scrollControllers[index];
      if (controller.hasClients) {
        controller.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    setState(() => _currentIndex = index);
  }

  /// Handles the destinations after the tabs: extra 0 is Search (both bar and
  /// rail); extras 1-4 are the [_moreDestinations] targets (rail-only).
  void _onExtraSelected(int extra) {
    if (extra == 0) {
      _openSearch();
      return;
    }
    HapticFeedback.lightImpact();
    switch (extra) {
      case 1:
        context.push(Routes.cards);
      case 2:
        context.push(Routes.graph);
      case 3:
        context.push(Routes.notifications);
      case 4:
        context.push(Routes.settings);
    }
  }

  void _openMoreSheet() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final width = MediaQuery.of(sheetContext).size.width;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: (width - 48) / 3,
                  child: _MoreSheetEntry(
                    label: 'Inbox',
                    icon: MdiIcons.inboxOutline,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      setState(() => _currentIndex = 0);
                    },
                  ),
                ),
                for (var i = 0; i < _moreDestinations.length; i++)
                  SizedBox(
                    width: (width - 48) / 3,
                    child: _MoreSheetEntry(
                      label: _moreDestinations[i].label,
                      icon: _moreDestinations[i].icon,
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _onExtraSelected(i + 1);
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openCaptureSheet() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => QuickCaptureSheet(
        onSaved: () {
          if (_currentIndex == 0) {
            _homeKey.currentState?.reload();
          }
        },
      ),
    );
  }

  Widget _buildBody() {
    final child = switch (_currentIndex) {
      0 => HomeScreen(key: _homeKey),
      1 => const TasksScreen(),
      2 => const JournalContinuousScreen(),
      3 => const LibraryScreen(),
      _ => const SizedBox.shrink(),
    };
    return PrimaryScrollController(
      controller: _scrollControllers[_currentIndex],
      child: child,
    );
  }
}

class _NavDestination {
  const _NavDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// The grab-pill stacked above the bottom bar. Tap, an upward drag past a
/// small threshold, or a fast upward fling all expand the more-sheet.
class _NavPill extends StatefulWidget {
  const _NavPill({super.key, required this.onExpand});

  final VoidCallback onExpand;

  @override
  State<_NavPill> createState() => _NavPillState();
}

class _NavPillState extends State<_NavPill> {
  double _dragDistance = 0;

  void _expand() {
    HapticFeedback.lightImpact();
    widget.onExpand();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _dragDistance = 0,
      onVerticalDragUpdate: (details) => _dragDistance += details.delta.dy,
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -300 || _dragDistance < -24) {
          _expand();
        }
      },
      child: Tooltip(
        message: 'More',
        child: InkWell(
          onTap: _expand,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreSheetEntry extends StatelessWidget {
  const _MoreSheetEntry({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26),
            const SizedBox(height: 6),
            Text(label, style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
