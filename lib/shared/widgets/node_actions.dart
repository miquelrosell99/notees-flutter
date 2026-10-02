import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../core/utils/node_display_name.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/settings/providers/settings_provider.dart';

/// Row-level node actions shared by the collection screens (Library, Home):
/// open in the editor, pin/unpin, archive, and the long-press action sheet.
///
/// The owning screen keeps its favorite set and reload logic; this helper only
/// performs the repository calls and feedback, so every node list in the app
/// behaves the same way.
class NodeActions {
  NodeActions({
    required this.isFavorite,
    required this.onFavoriteChanged,
    required this.onReload,
    this.onOpened,
  });

  final bool Function(Node node) isFavorite;

  /// Optimistic favorite-state update applied (and rolled back) by the owning
  /// screen.
  final void Function(Node node, bool favorite) onFavoriteChanged;

  /// Reloads the owning screen's lists after a mutation.
  final Future<void> Function() onReload;

  /// Called after the editor opened for [node] is popped — e.g. to record a
  /// local recent. Runs before [onReload].
  final Future<void> Function(Node node)? onOpened;

  Future<NodeRepository?> _repo(BuildContext context) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return null;
    return NodeRepository(dio: auth.dio!, syncService: auth.syncService);
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Opens the node in the editor, then records the open and reloads the
  /// lists when the editor is popped.
  Future<void> open(BuildContext context, Node node) async {
    HapticFeedback.lightImpact();
    await context.push('${Routes.editor}/${node.uuid}');
    if (context.mounted) {
      await onOpened?.call(node);
      await onReload();
    }
  }

  /// Toggles the pinned state with an optimistic update, rolling back on
  /// failure.
  Future<void> toggleFavorite(BuildContext context, Node node) async {
    HapticFeedback.lightImpact();
    final favorite = !isFavorite(node);
    onFavoriteChanged(node, favorite);

    final repo = await _repo(context);
    if (repo == null) return;
    try {
      if (favorite) {
        await repo.addFavorite(node.uuid);
      } else {
        await repo.removeFavorite(node.uuid);
      }
    } catch (e) {
      if (context.mounted) {
        onFavoriteChanged(node, !favorite);
        _toast(context, 'Could not update favorite: $e');
      }
    }
  }

  /// Archives the node, confirms with a snackbar, then reloads the lists.
  Future<void> archive(BuildContext context, Node node) async {
    final repo = await _repo(context);
    if (repo == null) return;
    try {
      await repo.archiveNode(node.uuid);
      if (context.mounted) {
        final dateFormat = context.read<SettingsProvider>().dateFormat;
        _toast(
          context,
          '${resolveNodeDisplayName(node, dateFormat: dateFormat)} archived',
        );
        await onReload();
      }
    } catch (e) {
      if (context.mounted) _toast(context, 'Could not archive: $e');
    }
  }

  /// Long-press action sheet: Pin/Unpin, Archive, and open in Focus Mode.
  void showActions(BuildContext context, Node node) {
    final favorite = isFavorite(node);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(favorite ? MdiIcons.star : MdiIcons.starOutline),
              title: Text(favorite ? 'Unpin' : 'Pin'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                toggleFavorite(context, node);
              },
            ),
            ListTile(
              leading: Icon(MdiIcons.archiveOutline),
              title: const Text('Archive'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                archive(context, node);
              },
            ),
            ListTile(
              leading: Icon(
                node.isJournal ? MdiIcons.fileDocumentEditOutline : MdiIcons.eyeOutline,
              ),
              title: Text(node.isJournal ? 'Open journal' : 'Open in Focus Mode'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                open(context, node);
              },
            ),
          ],
        ),
      ),
    );
  }
}
