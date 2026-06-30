import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_builder.dart';
import '../../core/theme/theme_provider.dart';
import '../../data/repositories/workspace_repository.dart';
import '../../core/secure/encryption_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/biometric_provider.dart';
import '../providers/settings_provider.dart';
import '../views/node_view_mode.dart';
import '../widgets/fleet_card.dart';
import '../widgets/section_title.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _version = '';
  List<Workspace> _workspaces = [];
  bool _loadingWorkspaces = true;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadWorkspaces();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = '${info.version}+${info.buildNumber}');
  }

  Future<void> _loadWorkspaces() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loadingWorkspaces = true);
    try {
      final repo = WorkspaceRepository(dio: auth.dio!);
      final workspaces = await repo.listWorkspaces();
      if (mounted) {
        setState(() {
          _workspaces = workspaces;
          _loadingWorkspaces = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _workspaces = [];
          _loadingWorkspaces = false;
        });
      }
    }
  }

  Future<void> _switchWorkspace(Workspace workspace) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    try {
      final repo = WorkspaceRepository(dio: auth.dio!);
      await repo.switchWorkspace(workspace.uuid);
      if (mounted) {
        context.go('/dashboard');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not switch workspace: $e')),
        );
      }
    }
  }

  Future<void> _logout() async {
    HapticFeedback.mediumImpact();
    final auth = context.read<AuthProvider>();
    await auth.logout();
    if (mounted) context.go('/login');
  }

  Future<void> _showEncryptionDialog(BuildContext context) async {
    final encryption = context.read<EncryptionProvider>();
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          String? error;
          bool busy = false;

          Future<void> submit() async {
            final password = passwordController.text;
            setState(() => error = null);
            try {
              if (!encryption.isEnabled) {
                if (password.length < 8) {
                  setState(() => error = 'Password must be at least 8 characters');
                  return;
                }
                if (password != confirmController.text) {
                  setState(() => error = 'Passwords do not match');
                  return;
                }
                setState(() => busy = true);
                await encryption.enable(password);
              } else if (!encryption.isUnlocked) {
                setState(() => busy = true);
                await encryption.unlock(password);
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
            } on EncryptionException catch (e) {
              setState(() => error = e.message);
            } catch (e) {
              setState(() => error = e.toString());
            } finally {
              setState(() => busy = false);
            }
          }

          return AlertDialog(
            title: Text(
              !encryption.isEnabled
                  ? 'Enable local encryption'
                  : !encryption.isUnlocked
                      ? 'Unlock local encryption'
                      : 'Local encryption active',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!encryption.isEnabled) ...[
                    const Text(
                      'This will encrypt your local database with SQLCipher. '
                      'The local cache will be cleared and re-synced from the server.',
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (encryption.isEnabled && !encryption.isUnlocked)
                    const Text(
                      'Your local database is encrypted. Enter your password to unlock this session.',
                    ),
                  if (encryption.isEnabled && encryption.isUnlocked)
                    const Text(
                      'Your local database is encrypted and unlocked for this session.',
                    ),
                  if (!encryption.isEnabled || !encryption.isUnlocked) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  if (!encryption.isEnabled) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirmController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm password',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              if (!encryption.isEnabled || !encryption.isUnlocked)
                TextButton(
                  onPressed: busy ? null : submit,
                  child: busy ? const CircularProgressIndicator() : const Text('Confirm'),
                ),
              if (encryption.isEnabled && encryption.isUnlocked) ...[
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          await encryption.lock();
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                  child: const Text('Lock now'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          await encryption.disable();
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                  child: const Text('Disable'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final auth = context.watch<AuthProvider>();
    final biometric = context.watch<BiometricProvider>();
    final settings = context.watch<SettingsProvider>();
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SectionTitle(icon: MdiIcons.paletteOutline, label: 'Appearance'),
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
          SectionTitle(icon: MdiIcons.noteEditOutline, label: 'Editor'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(MdiIcons.viewListOutline),
                  title: const Text('Default view mode'),
                  trailing: Text(
                    settings.defaultViewMode.label,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  onTap: () => _showViewModePicker(context, settings),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.formatIndentIncrease),
                  title: const Text('Linked refs collapse level'),
                  trailing: Text(
                    settings.linkedRefsCollapseLevel == 0
                        ? 'Off'
                        : 'Level ${settings.linkedRefsCollapseLevel}',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  onTap: () => _showCollapseLevelPicker(context, settings),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.calendarWeekOutline),
                  title: const Text('First day of week'),
                  trailing: Text(
                    firstDayOfWeekLabel(settings.firstDayOfWeek),
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  onTap: () => _showFirstDayOfWeekPicker(context, settings),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.calendarOutline),
                  title: const Text('Date format'),
                  trailing: Text(
                    settings.dateFormat,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  onTap: () => _showDateFormatPicker(context, settings),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.plusCircleOutline),
                  title: const Text('Quick capture destination'),
                  trailing: Text(
                    quickCaptureDestinationLabel(settings.quickCaptureDestination),
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  onTap: () => _showQuickCaptureDestinationPicker(context, settings),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          SectionTitle(icon: MdiIcons.dnsOutline, label: 'Server'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(MdiIcons.dns),
                  title: const Text('Manage servers'),
                  subtitle: auth.activeServer != null
                      ? Text(auth.activeServer!.nickname)
                      : const Text('No active server'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push('/settings/servers'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          SectionTitle(icon: MdiIcons.layersTripleOutline, label: 'Workspace'),
          const SizedBox(height: 8),
          FleetCard(
            child: _loadingWorkspaces
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Column(
                    children: _workspaces.asMap().entries.map((entry) {
                      final workspace = entry.value;
                      final isLast = entry.key == _workspaces.length - 1;
                      return Column(
                        children: [
                          ListTile(
                            leading: Icon(
                              workspace.isActive ? MdiIcons.checkCircle : MdiIcons.circleOutline,
                              color: workspace.isActive ? colors.primary : colors.onSurfaceVariant,
                            ),
                            title: Text(workspace.name),
                            subtitle: workspace.isActive ? const Text('Active') : null,
                            trailing: workspace.isActive
                                ? Icon(MdiIcons.check, color: colors.primary)
                                : Icon(MdiIcons.chevronRight),
                            onTap: workspace.isActive
                                ? null
                                : () => _switchWorkspace(workspace),
                          ),
                          if (!isLast) const Divider(height: 1),
                        ],
                      );
                    }).toList(),
                  ),
          ),
          const SizedBox(height: 28),
          SectionTitle(icon: MdiIcons.viewDashboardOutline, label: 'Graph & sidebar'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: [
                _ToggleTile(
                  icon: MdiIcons.starOutline,
                  label: 'Show favorites',
                  value: settings.showSidebarFavorites,
                  onChanged: settings.setShowSidebarFavorites,
                ),
                const Divider(height: 1),
                _ToggleTile(
                  icon: MdiIcons.clockOutline,
                  label: 'Show recents',
                  value: settings.showSidebarRecents,
                  onChanged: settings.setShowSidebarRecents,
                ),
                const Divider(height: 1),
                _ToggleTile(
                  icon: MdiIcons.calendarOutline,
                  label: 'Show journals',
                  value: settings.showSidebarJournals,
                  onChanged: settings.setShowSidebarJournals,
                ),
                const Divider(height: 1),
                _ToggleTile(
                  icon: MdiIcons.checkCircleOutline,
                  label: 'Show tasks',
                  value: settings.showSidebarTasks,
                  onChanged: settings.setShowSidebarTasks,
                ),
                const Divider(height: 1),
                _ToggleTile(
                  icon: MdiIcons.fileDocumentOutline,
                  label: 'Show pages',
                  value: settings.showSidebarPages,
                  onChanged: settings.setShowSidebarPages,
                ),
                const Divider(height: 1),
                _ToggleTile(
                  icon: MdiIcons.lanConnect,
                  label: 'Show graph',
                  value: settings.showSidebarGraph,
                  onChanged: settings.setShowSidebarGraph,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.deleteClockOutline),
                  title: const Text('Trash retention days'),
                  trailing: Text(
                    '${settings.trashRetentionDays} days',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  onTap: () => _showTrashRetentionPicker(context, settings),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          SectionTitle(icon: MdiIcons.accountCircleOutline, label: 'Account'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(MdiIcons.accountOutline),
                  title: Text(auth.user?.displayName ?? 'Guest'),
                  subtitle: auth.user != null ? Text(auth.user!.email) : null,
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: auth.user != null
                      ? () => context.push('/settings/profile')
                      : null,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.keyOutline),
                  title: const Text('API keys'),
                  subtitle: const Text('Manage personal access tokens'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: auth.user != null
                      ? () => context.push('/settings/api-keys')
                      : null,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    MdiIcons.fingerprint,
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
                  leading: Icon(MdiIcons.archiveOutline),
                  title: const Text('Archived'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push(Routes.archived),
                ),
                ListTile(
                  leading: Icon(MdiIcons.deleteOutline),
                  title: const Text('Trash'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push('/trash'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.logout, color: colors.error),
                  title: Text('Sign out', style: TextStyle(color: colors.error)),
                  onTap: _logout,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          SectionTitle(icon: MdiIcons.shieldOutline, label: 'Security'),
          const SizedBox(height: 8),
          FleetCard(
            child: _EncryptionSection(
              onConfigure: () => _showEncryptionDialog(context),
            ),
          ),
          const SizedBox(height: 28),
          SectionTitle(icon: MdiIcons.layersOutline, label: 'Advanced views'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(MdiIcons.lanConnect),
                  title: const Text('Graph'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push(Routes.graph),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.draw),
                  title: const Text('Whiteboard'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push(Routes.whiteboard),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.timeline),
                  title: const Text('Timeline'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push(Routes.timeline),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.viewWeekOutline),
                  title: const Text('Gantt'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push(Routes.gantt),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.chartBar),
                  title: const Text('Chart'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push(Routes.chart),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.tablePivot),
                  title: const Text('Pivot'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push(Routes.pivot),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.fileTree),
                  title: const Text('Query builder'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push(Routes.query),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          SectionTitle(icon: MdiIcons.informationOutline, label: 'About'),
          const SizedBox(height: 8),
          FleetCard(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(MdiIcons.fileDocumentOutline),
                  title: const Text('About Notees'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push('/about'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.keyboardOutline),
                  title: const Text('Keyboard shortcuts'),
                  trailing: Icon(MdiIcons.chevronRight),
                  onTap: () => context.push('/settings/keyboard-shortcuts'),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(MdiIcons.numeric),
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

  Future<void> _showViewModePicker(BuildContext context, SettingsProvider settings) async {
    final mode = await _showEnumPicker<NodeViewMode>(
      context: context,
      title: 'Default view mode',
      values: NodeViewMode.values,
      selected: settings.defaultViewMode,
      labelBuilder: (m) => m.label,
    );
    if (mode != null) await settings.setDefaultViewMode(mode);
  }

  Future<void> _showCollapseLevelPicker(BuildContext context, SettingsProvider settings) async {
    final level = await _showIntPicker(
      context: context,
      title: 'Linked refs collapse level',
      values: const [0, 1, 2, 3],
      selected: settings.linkedRefsCollapseLevel,
      labelBuilder: (v) => v == 0 ? 'Off' : 'Level $v',
    );
    if (level != null) await settings.setLinkedRefsCollapseLevel(level);
  }

  Future<void> _showFirstDayOfWeekPicker(BuildContext context, SettingsProvider settings) async {
    const values = [0, 1, 6];
    final day = await _showIntPicker(
      context: context,
      title: 'First day of week',
      values: values,
      selected: settings.firstDayOfWeek,
      labelBuilder: firstDayOfWeekLabel,
    );
    if (day != null) await settings.setFirstDayOfWeek(day);
  }

  Future<void> _showDateFormatPicker(BuildContext context, SettingsProvider settings) async {
    final format = await _showStringPicker(
      context: context,
      title: 'Date format',
      values: kDateFormatOptions,
      selected: settings.dateFormat,
      labelBuilder: (v) => v,
    );
    if (format != null) await settings.setDateFormat(format);
  }

  Future<void> _showTrashRetentionPicker(BuildContext context, SettingsProvider settings) async {
    const values = [7, 14, 30, 60, 90];
    final days = await _showIntPicker(
      context: context,
      title: 'Trash retention days',
      values: values,
      selected: settings.trashRetentionDays,
      labelBuilder: (v) => '$v days',
    );
    if (days != null) await settings.setTrashRetentionDays(days);
  }

  Future<void> _showQuickCaptureDestinationPicker(BuildContext context, SettingsProvider settings) async {
    final destination = await _showEnumPicker<QuickCaptureDestination>(
      context: context,
      title: 'Quick capture destination',
      values: QuickCaptureDestination.values,
      selected: settings.quickCaptureDestination,
      labelBuilder: quickCaptureDestinationLabel,
    );
    if (destination != null) await settings.setQuickCaptureDestination(destination);
  }

  Future<T?> _showEnumPicker<T>({
    required BuildContext context,
    required String title,
    required List<T> values,
    required T selected,
    required String Function(T) labelBuilder,
  }) async {
    return showModalBottomSheet<T>(
      context: context,
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
                    title,
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
            ...values.map((value) => ListTile(
                  title: Text(labelBuilder(value)),
                  trailing: value == selected
                      ? Icon(MdiIcons.check, color: Theme.of(ctx).colorScheme.primary)
                      : null,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Navigator.of(ctx).pop(value);
                  },
                )),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<int?> _showIntPicker({
    required BuildContext context,
    required String title,
    required List<int> values,
    required int selected,
    required String Function(int) labelBuilder,
  }) async {
    return showModalBottomSheet<int>(
      context: context,
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
                    title,
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
            ...values.map((value) => ListTile(
                  title: Text(labelBuilder(value)),
                  trailing: value == selected
                      ? Icon(MdiIcons.check, color: Theme.of(ctx).colorScheme.primary)
                      : null,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Navigator.of(ctx).pop(value);
                  },
                )),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<String?> _showStringPicker({
    required BuildContext context,
    required String title,
    required List<String> values,
    required String selected,
    required String Function(String) labelBuilder,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
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
                    title,
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
            ...values.map((value) => ListTile(
                  title: Text(labelBuilder(value)),
                  trailing: value == selected
                      ? Icon(MdiIcons.check, color: Theme.of(ctx).colorScheme.primary)
                      : null,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Navigator.of(ctx).pop(value);
                  },
                )),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _EncryptionSection extends StatelessWidget {
  const _EncryptionSection({required this.onConfigure});

  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final encryption = context.watch<EncryptionProvider>();
    final colors = Theme.of(context).colorScheme;

    if (!encryption.isEnabled) {
      return ListTile(
        leading: Icon(MdiIcons.lockOutline),
        title: const Text('Local encryption'),
        subtitle: const Text('Encrypt the local database with a password'),
        trailing: Icon(MdiIcons.chevronRight),
        onTap: onConfigure,
      );
    }

    if (!encryption.isUnlocked) {
      return ListTile(
        leading: Icon(MdiIcons.lock, color: colors.primary),
        title: const Text('Local encryption locked'),
        subtitle: const Text('Tap to unlock the local database'),
        trailing: Icon(MdiIcons.chevronRight),
        onTap: onConfigure,
      );
    }

    return ListTile(
      leading: Icon(MdiIcons.lockOpen, color: colors.primary),
      title: const Text('Local encryption active'),
      subtitle: const Text('Tap to lock or disable encryption'),
      trailing: Icon(MdiIcons.chevronRight),
      onTap: onConfigure,
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
            icon: MdiIcons.weatherSunny,
            selected: mode == AppThemeMode.light,
            onTap: () => onChanged(AppThemeMode.light),
          ),
          const SizedBox(width: 8),
          _ThemeButton(
            icon: MdiIcons.weatherNight,
            selected: mode == AppThemeMode.dark,
            onTap: () => onChanged(AppThemeMode.dark),
          ),
          const SizedBox(width: 8),
          _ThemeButton(
            icon: MdiIcons.brightnessAuto,
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
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        borderRadius: BorderRadius.circular(8),
        child: Center(
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
            color: noteesAccent,
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
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        customBorder: const CircleBorder(),
        child: Center(
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
                    MdiIcons.android,
                    size: 14,
                    color: colors.onPrimaryContainer,
                  )
                : null,
          ),
        ),
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

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: Switch(
        value: value,
        onChanged: (v) {
          HapticFeedback.lightImpact();
          onChanged(v);
        },
      ),
    );
  }
}
