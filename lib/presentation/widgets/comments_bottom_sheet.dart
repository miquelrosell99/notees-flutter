import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models/node.dart';
import '../../data/repositories/comment_repository.dart';
import '../providers/auth_provider.dart';

/// Bottom sheet for viewing and managing comments on a node.
class CommentsBottomSheet extends StatefulWidget {
  const CommentsBottomSheet({super.key, required this.nodeUuid});

  final String nodeUuid;

  static Future<void> show(BuildContext context, {required String nodeUuid}) {
    HapticFeedback.lightImpact();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => CommentsBottomSheet(nodeUuid: nodeUuid),
    );
  }

  @override
  State<CommentsBottomSheet> createState() => _CommentsBottomSheetState();
}

class _CommentsBottomSheetState extends State<CommentsBottomSheet> {
  List<Node> _comments = [];
  bool _loading = true;
  String? _error;
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = CommentRepository(dio: auth.dio!);
      final comments = await repo.fetchComments(widget.nodeUuid);
      if (mounted) {
        setState(() {
          _comments = comments;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createComment() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = CommentRepository(dio: auth.dio!);
      await repo.createComment(widget.nodeUuid, name: text);
      _controller.clear();
      await _loadComments();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteComment(Node comment) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = CommentRepository(dio: auth.dio!);
      await repo.deleteComment(widget.nodeUuid, comment.uuid);
      await _loadComments();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Comments',
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
            ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: _buildBody(colors),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Add a comment...',
                      ),
                      onSubmitted: (_) => _createComment(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _createComment,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme colors) {
    if (_loading && _comments.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _error!,
            style: TextStyle(color: colors.error),
          ),
        ),
      );
    }

    if (_comments.isEmpty) {
      return const Center(child: Text('No comments yet'));
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _comments.length,
      itemBuilder: (context, index) {
        final comment = _comments[index];
        return ListTile(
          title: Text(comment.displayName),
          subtitle: Text(comment.createDate ?? ''),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteComment(comment),
          ),
        );
      },
    );
  }
}
