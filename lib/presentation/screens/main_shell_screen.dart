import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/command_palette.dart';
import '../widgets/quick_capture_sheet.dart';
import 'dashboard_screen.dart';
import 'journal_continuous_screen.dart';
import 'library_screen.dart';
import 'node_editor_screen.dart';
import 'tasks_screen.dart';

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
  late int _currentIndex = widget.initialIndex;
  final _dashboardKey = GlobalKey<DashboardScreenState>();
  final _scrollControllers = List.generate(4, (_) => ScrollController());

  final _destinations = <_NavDestination>[
    _NavDestination(
      label: 'Inbox',
      icon: MdiIcons.inboxOutline,
      selectedIcon: MdiIcons.inbox,
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

    _openCommandPalette();
    return true;
  }

  Future<void> _openCommandPalette() async {
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
      case StaticCommand(action: CommandPaletteAction.journals):
        setState(() => _currentIndex = 2);
      case StaticCommand(action: CommandPaletteAction.library):
        setState(() => _currentIndex = 3);
      case StaticCommand(action: CommandPaletteAction.search):
        context.push(Routes.search);
      case StaticCommand(action: CommandPaletteAction.journalToday):
        context.push(Routes.journal);
      case StaticCommand(action: CommandPaletteAction.settings):
        context.push(Routes.settings);
      case NodeCommand(node: final node):
        context.push('${Routes.editor}/${node.id}');
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
              destinations: _destinations
                  .map(
                    (d) => NavigationRailDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.selectedIcon),
                      label: Text(d.label),
                    ),
                  )
                  .toList(),
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
          : NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: _onDestinationSelected,
              backgroundColor: theme.colorScheme.surface,
              indicatorColor: theme.colorScheme.primaryContainer,
              destinations: _destinations
                  .map(
                    (d) => NavigationDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.selectedIcon),
                      label: d.label,
                    ),
                  )
                  .toList(),
            ),
    );
  }

  void _onDestinationSelected(int index) {
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

  void _openCaptureSheet() {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => QuickCaptureSheet(
        onSaved: () {
          if (_currentIndex == 0) {
            _dashboardKey.currentState?.reload();
          }
        },
      ),
    );
  }

  Widget _buildBody() {
    final child = switch (_currentIndex) {
      0 => () {
          final settings = context.watch<SettingsProvider>();
          return settings.homePage == HomePage.today
              ? const _TodayJournalHome()
              : DashboardScreen(key: _dashboardKey);
        }(),
      1 => const TasksScreen(),
      2 => const JournalContinuousScreen(),
      3 => const LibraryScreen(),
      _ => const DashboardScreen(),
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

/// Home tab variant that opens today's daily journal directly in the editor.
class _TodayJournalHome extends StatefulWidget {
  const _TodayJournalHome();

  @override
  State<_TodayJournalHome> createState() => _TodayJournalHomeState();
}

class _TodayJournalHomeState extends State<_TodayJournalHome> {
  String? _journalUuid;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTodayJournal();
  }

  Future<void> _loadTodayJournal() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final journal = await repo.getOrCreateDailyJournal(DateTime.now());
      if (mounted) setState(() => _journalUuid = journal.uuid);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }
    final uuid = _journalUuid;
    if (uuid == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return NodeEditorScreen(nodeUuid: uuid);
  }
}
