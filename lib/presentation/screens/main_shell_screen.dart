import 'package:flutter/material.dart';

import 'dashboard_screen.dart';
import 'pages_screen.dart';
import 'search_screen.dart';
import 'tasks_screen.dart';

/// Main app shell with a bottom navigation bar.
///
/// Only the active tab is built; off-screen tabs are dropped to keep memory
/// usage low and ensure fresh data on each visit.
class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key});

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> {
  int _currentIndex = 0;

  final _destinations = const <_NavDestination>[
    _NavDestination(
      label: 'Home',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: _buildBody(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
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
        return const TasksScreen();
      case 2:
        return const PagesScreen();
      case 3:
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
