import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/auth_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/fleet_card.dart';

/// Native API key management.
class ApiKeysScreen extends StatefulWidget {
  const ApiKeysScreen({super.key});

  @override
  State<ApiKeysScreen> createState() => _ApiKeysScreenState();
}

class _ApiKeysScreenState extends State<ApiKeysScreen> {
  List<ApiKey> _keys = [];
  bool _loading = true;
  String? _error;
  ApiKey? _justCreated;

  @override
  void initState() {
    super.initState();
    _loadKeys();
  }

  Future<void> _loadKeys() async {
    final auth = context.read<AuthProvider>();
    final secureStorage = auth.secureStorage;

    setState(() => _loading = true);
    try {
      if (auth.dio == null) throw const AuthException('No server configured');
      final repo = AuthRepository(dio: auth.dio!, secureStorage: secureStorage);
      _keys = await repo.listApiKeys();
      _error = null;
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createKey() async {
    final auth = context.read<AuthProvider>();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _CreateKeyDialog(),
    );
    if (name == null || name.trim().isEmpty) return;

    HapticFeedback.lightImpact();
    setState(() => _loading = true);
    try {
      final repo = AuthRepository(dio: auth.dio!, secureStorage: auth.secureStorage);
      _justCreated = await repo.createApiKey(name: name.trim());
      if (mounted) await _loadKeys();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _revokeKey(ApiKey key) async {
    final auth = context.read<AuthProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke API key?'),
        content: Text('"${key.name}" will stop working immediately.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    HapticFeedback.mediumImpact();
    setState(() => _loading = true);
    try {
      final repo = AuthRepository(dio: auth.dio!, secureStorage: auth.secureStorage);
      await repo.revokeApiKey(key.id);
      if (mounted) await _loadKeys();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('API keys')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadKeys,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_error != null)
                    FleetCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _error!,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    ),
                  if (_justCreated != null) ...[
                    FleetCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'API key created',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Copy it now — you will not be able to see it again.',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 12),
                            SelectableText(
                              _justCreated!.key ?? '',
                              style: const TextStyle(fontFamily: 'monospace'),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: _justCreated!.key ?? ''),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Copied to clipboard')),
                                );
                              },
                              icon: Icon(MdiIcons.contentCopy),
                              label: const Text('Copy key'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  FleetCard(
                    child: _keys.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: Text('No API keys')),
                          )
                        : Column(
                            children: _keys.asMap().entries.map((entry) {
                              final key = entry.value;
                              final isLast = entry.key == _keys.length - 1;
                              return Column(
                                children: [
                                  ListTile(
                                    title: Text(key.name),
                                    subtitle: Text(
                                      'Created ${_formatDate(key.createDate)}',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                    trailing: IconButton(
                                      icon: Icon(MdiIcons.deleteOutline, color: colors.error),
                                      tooltip: 'Delete API key',
                                      onPressed: () => _revokeKey(key),
                                    ),
                                  ),
                                  if (!isLast) const Divider(height: 1),
                                ],
                              );
                            }).toList(),
                          ),
                  ),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createKey,
        icon: Icon(MdiIcons.plus),
        label: const Text('Key'),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${_two(date.month)}-${_two(date.day)}';
  }

  String _two(int n) => n.toString().padLeft(2, '0');
}

class _CreateKeyDialog extends StatefulWidget {
  const _CreateKeyDialog();

  @override
  State<_CreateKeyDialog> createState() => _CreateKeyDialogState();
}

class _CreateKeyDialogState extends State<_CreateKeyDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New API key'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Name',
          hintText: 'e.g. Phone sync',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
