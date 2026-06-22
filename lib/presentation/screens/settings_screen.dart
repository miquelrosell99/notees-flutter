import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../core/theme/theme_builder.dart';
import '../../core/theme/theme_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/biometric_provider.dart';
import '../widgets/fleet_card.dart';
import '../widgets/section_title.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = '${info.version}+${info.buildNumber}');
  }

  Future<void> _logout() async {
    HapticFeedback.mediumImpact();
    final auth = context.read<AuthProvider>();
    await auth.logout();
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final auth = context.watch<AuthProvider>();
    final biometric = context.watch<BiometricProvider>();
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SectionTitle(icon: Icons.palette_outlined, label: 'Appearance'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: [
                _ThemeRow(
                  mode: theme.themeMode,
                  onChanged: theme.setThemeMode,
                ),
                const Divider(height: 1),
                _AccentRow(
                  accent: theme.accent,
                  onChanged: theme.setAccent,
                ),
                const Divider(height: 1),
                _PureBlackRow(
                  value: theme.pureBlack,
                  onChanged: theme.setPureBlack,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const SectionTitle(icon: Icons.dns_outlined, label: 'Server'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.dns),
                  title: const Text('Manage servers'),
                  subtitle: auth.activeServer != null
                      ? Text(auth.activeServer!.nickname)
                      : const Text('No active server'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/settings/servers'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const SectionTitle(icon: Icons.account_circle_outlined, label: 'Account'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(auth.user?.displayName ?? 'Guest'),
                  subtitle: auth.user != null ? Text(auth.user!.email) : null,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: auth.user != null
                      ? () => context.push('/settings/profile')
                      : null,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: const Text('API keys'),
                  subtitle: const Text('Manage personal access tokens'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: auth.user != null
                      ? () => context.push('/settings/api-keys')
                      : null,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    Icons.fingerprint,
                    color: biometric.available == false ? colors.outline : null,
                  ),
                  title: const Text('Biometric lock'),
                  subtitle: biometric.available == false
                      ? const Text('No biometrics enrolled on this device')
                      : const Text('Require authentication to open the app'),
                  trailing: Switch(
                    value: biometric.enabled,
                    onChanged: biometric.available == true
                        ? (value) => biometric.setEnabled(value)
                        : null,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.logout, color: colors.error),
                  title: Text('Sign out', style: TextStyle(color: colors.error)),
                  onTap: _logout,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const SectionTitle(icon: Icons.info_outline, label: 'About'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('About Notees'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/about'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.numbers),
                  title: const Text('Version'),
                  trailing: Text(_version, style: TextStyle(color: colors.onSurfaceVariant)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({required this.mode, required this.onChanged});

  final AppThemeMode mode;
  final ValueChanged<AppThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Theme',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          _ThemeButton(
            icon: Icons.wb_sunny_outlined,
            selected: mode == AppThemeMode.light,
            onTap: () => onChanged(AppThemeMode.light),
          ),
          const SizedBox(width: 8),
          _ThemeButton(
            icon: Icons.dark_mode_outlined,
            selected: mode == AppThemeMode.dark,
            onTap: () => onChanged(AppThemeMode.dark),
          ),
          const SizedBox(width: 8),
          _ThemeButton(
            icon: Icons.brightness_auto_outlined,
            selected: mode == AppThemeMode.system,
            onTap: () => onChanged(AppThemeMode.system),
          ),
        ],
      ),
    );
  }
}

class _ThemeButton extends StatelessWidget {
  const _ThemeButton({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: selected ? colors.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? colors.primary
                : colors.outline.withAlpha((0.2 * 255).round()),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Icon(
          icon,
          size: 18,
          color: selected ? colors.onPrimaryContainer : colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _AccentRow extends StatelessWidget {
  const _AccentRow({required this.accent, required this.onChanged});

  final AppAccent accent;
  final ValueChanged<AppAccent> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Accent Color',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          _AccentSwatch(
            color: Colors.white,
            selected: accent == AppAccent.white,
            onTap: () => onChanged(AppAccent.white),
          ),
          const SizedBox(width: 10),
          _AccentSwatch(
            color: const Color(0xFF5B7D5B),
            selected: accent == AppAccent.functional,
            onTap: () => onChanged(AppAccent.functional),
          ),
          const SizedBox(width: 10),
          _AccentSwatch(
            color: null,
            selected: accent == AppAccent.dynamicColor,
            onTap: () => onChanged(AppAccent.dynamicColor),
          ),
        ],
      ),
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      customBorder: const CircleBorder(),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color ?? colors.primaryContainer,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? colors.primary : colors.outline.withAlpha((0.2 * 255).round()),
            width: selected ? 2.5 : 1,
          ),
        ),
        child: color == null
            ? Icon(
                Icons.android_outlined,
                size: 14,
                color: colors.onPrimaryContainer,
              )
            : null,
      ),
    );
  }
}

class _PureBlackRow extends StatelessWidget {
  const _PureBlackRow({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final enabled = brightness == Brightness.dark;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: const Text('Pure Black'),
      subtitle: const Text('Pure black backgrounds for OLED displays'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!enabled)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Dark only',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onPrimaryContainer,
                    ),
              ),
            ),
          Switch(
            value: value,
            onChanged: enabled ? (v) {
              HapticFeedback.lightImpact();
              onChanged(v);
            } : null,
          ),
        ],
      ),
    );
  }
}
