import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/node_display_name.dart';
import '../../../core/utils/node_icon.dart';
import '../../../data/models/node.dart';
import '../../../data/repositories/node_repository.dart';
import '../../auth/providers/auth_provider.dart';
import '../../../shared/widgets/node_picker.dart';
import 'alias_target_guard.dart';

/// The aliases bottom sheet (SCHEMA.md "Node aliases") — the title-row
/// affordance on the ALIASED node's page: lists every page whose
/// alias-terminal is this node (chains included, via the store's recursive
/// read) and authors NEW aliases through THE BACKWARD WRITE — the picked
/// page's `aliasedNodeId` becomes THIS node; the main page holds nothing
/// (the relation is one-way FROM the alias).
///
/// Tapping a row returns the alias uuid from [show] so the caller can open
/// the ALIAS page itself — the deliberate bypass of the alias redirect (the
/// app has no redirect seam, so a plain editor push lands on the alias's
/// own view; from there the "Aliased node" row jumps back).
class AliasesSheet extends StatefulWidget {
  const AliasesSheet({
    super.key,
    required this.nodeUuid,
    this.onChanged,
  });

  final String nodeUuid;

  /// Notified after a successful backward write so the caller can refresh
  /// its count/list.
  final VoidCallback? onChanged;

  /// Returns the alias uuid to OPEN (the alias's own view), or null when
  /// the sheet closed without a navigation pick.
  static Future<String?> show(
    BuildContext context, {
    required String nodeUuid,
    VoidCallback? onChanged,
  }) {
    HapticFeedback.lightImpact();
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => AliasesSheet(nodeUuid: nodeUuid, onChanged: onChanged),
    );
  }

  @override
  State<AliasesSheet> createState() => _AliasesSheetState();
}

class _AliasesSheetState extends State<AliasesSheet> {
  List<Node> _aliases = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    setState(() => _loading = true);
    try {
      final repo = NodeRepository(
        dio: auth.dio!,
        syncService: auth.syncService,
      );
      final aliases = await repo.fetchAliasNodesOf(widget.nodeUuid);
      if (!mounted) return;
      setState(() {
        _aliases = aliases;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// THE backward write: the picked page's `aliasedNodeId` becomes the
  /// ACTIVE node — never the other way around.
  Future<void> _addAlias() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    final picked = await NodePicker.show(context, mode: NodePickerMode.page);
    if (picked == null || !mounted) return;
    final guardError = aliasTargetError(picked, carrierUuid: widget.nodeUuid);
    if (guardError != null) {
      _showError(guardError);
      return;
    }
    try {
      final repo = NodeRepository(
        dio: auth.dio!,
        syncService: auth.syncService,
      );
      await repo.setAliasedNodeId(picked.uuid, widget.nodeUuid);
      widget.onChanged?.call();
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showError(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Aliases',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                IconButton(
                  icon: Icon(MdiIcons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Flexible(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _error!,
                          style: TextStyle(color: colors.error),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        children: [
                          if (_aliases.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('No aliases yet.'),
                            )
                          else
                            for (final alias in _aliases)
                              ListTile(
                                leading: NodeIcon(
                                  iconField: alias.icon,
                                  size: 20,
                                  fallbackColor: colors.onSurfaceVariant,
                                ),
                                title: Text(
                                  resolveNodeDisplayName(alias),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: const Text('Open the alias page'),
                                trailing: Icon(
                                  MdiIcons.chevronRight,
                                  color: colors.onSurfaceVariant,
                                ),
                                onTap: () =>
                                    Navigator.of(context).pop(alias.uuid),
                              ),
                          const Divider(),
                          ListTile(
                            leading: Icon(
                              MdiIcons.plus,
                              color: colors.onSurfaceVariant,
                            ),
                            title: const Text('Add alias'),
                            subtitle: const Text(
                              'Point another page at this one',
                            ),
                            onTap: _addAlias,
                          ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}
