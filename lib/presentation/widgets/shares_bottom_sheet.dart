import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart' as share_plus;

import '../../data/repositories/share_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/fleet_card.dart';

/// Bottom sheet for creating and revoking public share links for a node.
class SharesBottomSheet extends StatefulWidget {
  const SharesBottomSheet({super.key, required this.nodeId});

  final int nodeId;

  static Future<void> show(BuildContext context, {required int nodeId}) {
    HapticFeedback.lightImpact();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => SharesBottomSheet(nodeId: nodeId),
    );
  }

  @override
  State<SharesBottomSheet> createState() => _SharesBottomSheetState();
}

class _SharesBottomSheetState extends State<SharesBottomSheet> {
  List<Share> _shares = [];
  bool _loading = true;
  String? _error;
  bool _hasExpiry = false;
  DateTime? _expiry;

  @override
  void initState() {
    super.initState();
    _loadShares();
  }

  Future<void> _loadShares() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = ShareRepository(dio: auth.dio!);
      final shares = await repo.fetchNodeShares(widget.nodeId);
      if (mounted) {
        setState(() {
          _shares = shares;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createShare() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = ShareRepository(dio: auth.dio!);
      final expiryDate = _hasExpiry && _expiry != null
          ? _expiry!.toUtc().toIso8601String()
          : null;
      final share = await repo.createShare(
        widget.nodeId,
        expiryDate: expiryDate,
      );
      if (share.url != null && share.url!.isNotEmpty) {
        await share_plus.Share.share(share.url!);
      }
      await _loadShares();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revokeShare(Share share) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = ShareRepository(dio: auth.dio!);
      await repo.revokeShare(share.shareUuid);
      await _loadShares();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        _expiry = picked;
        _hasExpiry = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Share page',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FleetCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Checkbox(
                          value: _hasExpiry,
                          onChanged: (value) => setState(
                            () => _hasExpiry = value ?? false,
                          ),
                        ),
                        const Expanded(child: Text('Set expiry date')),
                      ],
                    ),
                    if (_hasExpiry) ...[
                      const SizedBox(height: 8),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          _expiry == null
                              ? 'Select date'
                              : _expiry!.toIso8601String().split('T').first,
                        ),
                        trailing: const Icon(Icons.calendar_today_outlined),
                        onTap: _pickExpiry,
                      ),
                    ],
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _createShare,
                      icon: const Icon(Icons.link),
                      label: const Text('Create public link'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Active shares',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.35,
              ),
              child: _buildSharesList(colors),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSharesList(ColorScheme colors) {
    if (_loading && _shares.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: colors.error),
        ),
      );
    }

    if (_shares.isEmpty) {
      return const Center(child: Text('No active shares'));
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: _shares.length,
      itemBuilder: (context, index) {
        final share = _shares[index];
        return ListTile(
          title: Text(
            share.url ?? 'Share link',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(share.expiryDate ?? 'No expiry'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _revokeShare(share),
          ),
        );
      },
    );
  }
}
