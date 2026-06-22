import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../data/models/server_profile.dart';
import '../providers/auth_provider.dart';
import '../widgets/fleet_card.dart';

/// Native server management: list, add, edit, delete, and switch servers.
class ServerManagementScreen extends StatefulWidget {
  const ServerManagementScreen({super.key});

  @override
  State<ServerManagementScreen> createState() => _ServerManagementScreenState();
}

class _ServerManagementScreenState extends State<ServerManagementScreen> {
  List<ServerProfile> _servers = [];
  ServerProfile? _activeServer;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  Future<void> _loadServers() async {
    final repo = context.read<AuthProvider>().serverRepository;
    final servers = await repo.getServers();
    final active = await repo.getActiveServer();
    setState(() {
      _servers = servers;
      _activeServer = active;
      _loading = false;
    });
  }

  Future<void> _switchServer(ServerProfile server) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();
    await auth.switchActiveServer(server);
    await _loadServers();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Switched to ${server.nickname}. Please sign in.')),
      );
      context.go('/login');
    }
  }

  Future<void> _deleteServer(ServerProfile server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove server?'),
        content: Text('Remove ${server.nickname} from this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    HapticFeedback.mediumImpact();
    final repo = context.read<AuthProvider>().serverRepository;
    await repo.removeServer(server.id);
    await _loadServers();
  }

  Future<void> _showServerSheet({ServerProfile? server}) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ServerFormSheet(
        server: server,
        onSaved: _loadServers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Servers')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                FleetCard(
                  child: _servers.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text('No servers saved')),
                        )
                      : Column(
                          children: _servers.asMap().entries.map((entry) {
                            final server = entry.value;
                            final isLast = entry.key == _servers.length - 1;
                            final isActive = server.id == _activeServer?.id;
                            return Column(
                              children: [
                                ListTile(
                                  leading: Icon(
                                    Icons.dns,
                                    color: isActive ? colors.primary : colors.onSurfaceVariant,
                                  ),
                                  title: Text(server.nickname),
                                  subtitle: Text(
                                    server.url,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: isActive
                                      ? Icon(Icons.check_circle, color: colors.primary)
                                      : const Icon(Icons.chevron_right),
                                  onTap: () => _switchServer(server),
                                  onLongPress: () => _showServerSheet(server: server),
                                ),
                                if (!isLast) const Divider(height: 1),
                              ],
                            );
                          }).toList(),
                        ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Long-press a server to edit its nickname.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showServerSheet(),
        icon: const Icon(Icons.add),
        label: const Text('Server'),
      ),
    );
  }
}

class _ServerFormSheet extends StatefulWidget {
  const _ServerFormSheet({this.server, required this.onSaved});

  final ServerProfile? server;
  final VoidCallback onSaved;

  @override
  State<_ServerFormSheet> createState() => _ServerFormSheetState();
}

class _ServerFormSheetState extends State<_ServerFormSheet> {
  late final TextEditingController _urlController;
  late final TextEditingController _nicknameController;
  late bool _trustSelfSigned;
  bool _testing = false;
  bool _saving = false;
  String? _error;
  String? _pingResult;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.server?.url ?? '');
    _nicknameController = TextEditingController(text: widget.server?.nickname ?? '');
    _trustSelfSigned = widget.server?.trustSelfSigned ?? false;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _testing = true;
      _pingResult = null;
      _error = null;
    });
    final repo = context.read<AuthProvider>().serverRepository;
    final result = await repo.pingServer(url, trustSelfSigned: _trustSelfSigned);
    setState(() {
      _testing = false;
      _pingResult = result;
    });
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    final nickname = _nicknameController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Server URL is required');
      return;
    }

    setState(() => _saving = true);
    try {
      final repo = context.read<AuthProvider>().serverRepository;
      final existing = widget.server;
      if (existing != null) {
        await repo.updateServer(existing.copyWith(
          url: url,
          nickname: nickname.isEmpty ? url : nickname,
          trustSelfSigned: _trustSelfSigned,
        ));
      } else {
        await repo.addServer(
          url: url,
          nickname: nickname.isEmpty ? url : nickname,
          trustSelfSigned: _trustSelfSigned,
        );
      }
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSaved();
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.server == null ? 'Add server' : 'Edit server',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://notees.example.com',
              prefixIcon: Icon(Icons.link),
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nicknameController,
            decoration: const InputDecoration(
              labelText: 'Nickname (optional)',
              prefixIcon: Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('Trust self-signed certificate'),
            subtitle: const Text('Only enable for servers you control.'),
            value: _trustSelfSigned,
            onChanged: (value) => setState(() => _trustSelfSigned = value),
          ),
          if (_pingResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _pingResult!,
                style: TextStyle(
                  color: _pingResult == null
                      ? null
                      : _pingResult!.startsWith('Could not')
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          Row(
            children: [
              OutlinedButton(
                onPressed: _testing ? null : _testConnection,
                child: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Test'),
              ),
              const Spacer(),
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
