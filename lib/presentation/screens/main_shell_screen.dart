import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../data/repositories/node_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/command_palette.dart';
import 'dashboard_screen.dart';
import 'journal_screen.dart';
import 'pages_screen.dart';
import 'search_screen.dart';
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

  final _destinations = const <_NavDestination>[
    _NavDestination(
      label: 'Home',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
    ),
    _NavDestination(
      label: 'Journal',
      icon: Icons.calendar_today_outlined,
      selectedIcon: Icons.calendar_today,
    ),
    _NavDestination(
      label: 'Tasks',
      icon: Icons.check_circle_outline,
      selectedIcon: Icons.check_circle,
    ),
    _NavDestination(
      label: 'Pages',
      icon: Icons.description_outlined,
      selectedIcon: Icons.description,
    ),
    _NavDestination(
      label: 'Search',
      icon: Icons.search,
      selectedIcon: Icons.search,
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
      case StaticCommand(action: CommandPaletteAction.dashboard):
        setState(() => _currentIndex = 0);
      case StaticCommand(action: CommandPaletteAction.journal):
        setState(() => _currentIndex = 1);
      case StaticCommand(action: CommandPaletteAction.tasks):
        setState(() => _currentIndex = 2);
      case StaticCommand(action: CommandPaletteAction.pages):
        setState(() => _currentIndex = 3);
      case StaticCommand(action: CommandPaletteAction.search):
        setState(() => _currentIndex = 4);
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
              onDestinationSelected: (index) {
                HapticFeedback.lightImpact();
                setState(() => _currentIndex = index);
              },
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
      bottomNavigationBar: useRail
          ? null
          : NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (index) {
                HapticFeedback.lightImpact();
                setState(() => _currentIndex = index);
              },
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

  Widget _buildBody() {
    switch (_currentIndex) {
      case 0:
        return const DashboardScreen();
      case 1:
        return const JournalScreen();
      case 2:
        return const TasksScreen();
      case 3:
        return const PagesScreen();
      case 4:
        return const SearchScreen();
      default:
        return const DashboardScreen();
    }
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
