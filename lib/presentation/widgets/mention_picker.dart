import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models/node.dart';
import '../../data/models/user.dart';
import '../providers/auth_provider.dart';
import 'node_picker.dart';

/// Result of a mention selection: either the current user or a picked node.
class MentionResult {
  MentionResult._({required this.displayName, required this.target, required this.isUser});

  factory MentionResult.user(User user) => MentionResult._(
        displayName: user.displayName,
        target: user.uuid,
        isUser: true,
      );

  factory MentionResult.node(Node node) => MentionResult._(
        displayName: node.displayName,
        target: node.uuid,
        isUser: false,
      );

  final String displayName;
  final String target;
  final bool isUser;
}

/// Bottom-sheet picker for @ mentions (current user or any node/page).
class MentionPicker extends StatelessWidget {
  const MentionPicker({super.key});

  static Future<MentionResult?> show(BuildContext context) {
    return showModalBottomSheet<MentionResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.45,
        minChildSize: 0.35,
        maxChildSize: 0.7,
        expand: false,
        builder: (context, scrollController) => const MentionPicker(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
    final user = auth.user;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Mention',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          if (user != null)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: colors.primaryContainer,
                child: Text(
                  user.displayName.isNotEmpty ? user.displayName[0].toUpperCase() : '@',
                  style: TextStyle(color: colors.onPrimaryContainer),
                ),
              ),
              title: Text(user.displayName),
              subtitle: const Text('Current user'),
              onTap: () {
                HapticFeedback.lightImpact();
                Navigator.of(context).pop(MentionResult.user(user));
              },
            ),
          ListTile(
            leading: Icon(Icons.description_outlined, color: colors.onSurfaceVariant),
            title: const Text('Page or node'),
            subtitle: const Text('Search notes, pages, and more'),
            onTap: () async {
              HapticFeedback.lightImpact();
              final node = await NodePicker.show(context, mode: NodePickerMode.any);
              if (node == null) return;
              if (!context.mounted) return;
              Navigator.of(context).pop(MentionResult.node(node));
            },
          ),
        ],
      ),
    );
  }
}
