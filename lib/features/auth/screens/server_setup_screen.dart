import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../data/models/server_profile.dart';
import '../providers/auth_provider.dart';
import '../../../shared/widgets/fleet_card.dart';
import '../../../shared/widgets/section_title.dart';

class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _urlController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _pinging = false;
  bool _trustSelfSigned = false;
  String? _error;
  List<_ServerItem> _servers = [];

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  Future<void> _loadServers() async {
    final repo = context.read<AuthProvider>().serverRepository;
    final servers = await repo.getServers();
    final activeId = await repo.getActiveServerId();
    if (mounted) {
      setState(() {
        _servers = servers
            .map((s) => _ServerItem(server: s, isActive: s.id == activeId))
            .toList();
      });
    }
  }

  Future<void> _saveServer() async {
    if (!_formKey.currentState!.validate()) return;

    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    final repo = auth.serverRepository;
    setState(() {
      _pinging = true;
      _error = null;
    });

    try {
      final url = _urlController.text.trim();
      final error = await repo.pingServer(
        url,
        trustSelfSigned: _trustSelfSigned,
      );

      if (error != null) {
        if (mounted) {
          setState(() {
            _pinging = false;
            _error = error;
          });
        }
        return;
      }

      final profile = await repo.addServer(
        url: url,
        nickname: _nicknameController.text.trim(),
        trustSelfSigned: _trustSelfSigned,
      );

      if (!mounted) return;
      await auth.selectServer(profile);
      if (mounted) await _loadServers();

      if (!mounted) return;
      context.go('/login');
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not connect: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _pinging = false);
      }
    }
  }

  Future<void> _continueOffline() async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    setState(() {
      _pinging = true;
      _error = null;
    });
    try {
      await auth.loginLocally();
      if (!mounted) return;
      if (auth.error != null) {
        setState(() => _error = auth.error);
        return;
      }
      context.go('/dashboard');
    } finally {
      if (mounted) {
        setState(() => _pinging = false);
      }
    }
  }

  Future<void> _selectServer(String id) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    final repo = auth.serverRepository;
    setState(() => _pinging = true);
    try {
      final servers = await repo.getServers();
      final profile = servers.firstWhere((s) => s.id == id);
      await repo.setActiveServerId(id);
      if (!mounted) return;
      await auth.selectServer(profile);
      if (mounted) await _loadServers();
      if (!mounted) return;
      context.go('/login');
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not select server: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _pinging = false);
      }
    }
  }

  Future<void> _removeServer(String id) async {
    HapticFeedback.mediumImpact();
    final repo = context.read<AuthProvider>().serverRepository;
    await repo.removeServer(id);
    if (mounted) await _loadServers();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Connect to Notees')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
            Text(
              'Enter your self-hosted Notees server URL. Your data stays on your server.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'https://notees.example.com',
                      prefixIcon: Icon(MdiIcons.link),
                    ),
                    validator: (value) {
                      final trimmed = value?.trim() ?? '';
                      if (trimmed.isEmpty) return 'Server URL is required';
                      final lower = trimmed.toLowerCase();
                      if (!lower.startsWith('http://') &&
                          !lower.startsWith('https://')) {
                        return 'URL must start with http:// or https://';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _nicknameController,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Nickname (optional)',
                      hintText: 'Home server',
                      prefixIcon: Icon(MdiIcons.labelOutline),
                    ),
                    onFieldSubmitted: (_) => _saveServer(),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Trust self-signed certificate'),
                    subtitle: const Text('Only enable for servers you control.'),
                    value: _trustSelfSigned,
                    onChanged: (value) => setState(() => _trustSelfSigned = value),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.error,
                          ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _pinging ? null : _saveServer,
                    icon: _pinging
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(MdiIcons.arrowRight),
                    label: const Text('Connect'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _pinging ? null : _continueOffline,
                    icon: Icon(MdiIcons.cloudOffOutline),
                    label: const Text('Continue offline'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Offline mode keeps everything on this device. '
                    'You can connect a server later from Settings.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            if (_servers.isNotEmpty) ...[
              const SizedBox(height: 32),
              SectionTitle(icon: MdiIcons.dns, label: 'Saved servers'),
              const SizedBox(height: 8),
              FleetCard(
                child: Column(
                  children: _servers.asMap().entries.map((entry) {
                    final item = entry.value;
                    final isLast = entry.key == _servers.length - 1;
                    return Column(
                      children: [
                        ListTile(
                          leading: Icon(
                            item.isActive ? MdiIcons.checkCircle : MdiIcons.circleOutline,
                            color: item.isActive ? colors.primary : colors.outline,
                          ),
                          title: Text(item.server.nickname),
                          subtitle: Text(
                            item.server.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: Icon(MdiIcons.deleteOutline),
                            tooltip: 'Delete',
                            onPressed: () => _removeServer(item.server.id),
                          ),
                          onTap: () => _selectServer(item.server.id),
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
        ),
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }
}

class _ServerItem {
  _ServerItem({required this.server, required this.isActive});

  final ServerProfile server;
  final bool isActive;
}
