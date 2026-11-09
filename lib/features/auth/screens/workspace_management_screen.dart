import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../../core/routing/router.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/workspace_repository.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/fleet_card.dart';
import '../providers/auth_provider.dart';

/// Fullscreen workspace management — the landing screen when the signed-in
/// account has no valid active workspace, and the switcher surface later
/// (Settings → Workspaces). Mirrors the web client's workspace manager: the
/// account's workspaces as rows, tap to enter (becomes the active workspace),
/// a create affordance with a name sheet, and owner-only rename. At startup
/// with no valid workspace there is deliberately no close button: the shell
/// is unreachable until a workspace is selected.
class WorkspaceManagementScreen extends StatefulWidget {
  const WorkspaceManagementScreen({super.key});

  @override
  State<WorkspaceManagementScreen> createState() =>
      _WorkspaceManagementScreenState();
}

class _WorkspaceManagementScreenState extends State<WorkspaceManagementScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Memberships change server-side: refresh the list on every entry.
    unawaited(context.read<AuthProvider>().refreshWorkspaces());
  }

  Future<void> _refresh() =>
      context.read<AuthProvider>().refreshWorkspaces();

  /// The unlock re-prompt (the web client's W2 modal): asks for the
  /// account password, re-derives the master key in place, and re-opens
  /// the refused workspace. Wrong password / account lockout render as the
  /// dialog's form error (the server message carries the retry-after).
  Future<void> _showUnlockDialog(AuthProvider auth) async {
    HapticFeedback.lightImpact();
    await showDialog<void>(
      context: context,
      builder: (_) => const UnlockWorkspaceDialog(),
    );
    if (!mounted) return;
    // Unlocked: the refusal cleared and the workspace is active — leave
    // the manager for the shell like a normal open would.
    if (auth.workspaceOpenError == null && auth.hasValidWorkspace) {
      context.go(Routes.dashboard);
    }
  }

  Future<void> _enterWorkspace(Workspace workspace, AuthProvider auth) async {
    if (_busy) return;
    // Tapping the current workspace just closes the manager (web parity).
    if (workspace.uuid == auth.activeWorkspaceId &&
        auth.hasValidWorkspace) {
      context.go(Routes.dashboard);
      return;
    }
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      await auth.switchWorkspace(workspace.uuid);
      if (!mounted) return;
      context.go(Routes.dashboard);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not switch workspace: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showNameSheet({Workspace? workspace}) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _WorkspaceNameSheet(workspace: workspace),
    );
    if (name == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final repo = WorkspaceRepository(dio: auth.dio!);
      if (workspace == null) {
        // Create → enter (the web client's flow); an empty name is unnamed
        // and the server names it by default.
        final created = await repo.createWorkspace(
          name: name.trim().isEmpty ? null : name.trim(),
        );
        await auth.switchWorkspace(created.uuid);
        if (mounted) context.go(Routes.dashboard);
      } else {
        await repo.renameWorkspace(workspace.uuid, name.trim());
        await auth.refreshWorkspaces();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(workspace == null
                ? 'Could not create workspace: $e'
                : 'Could not rename workspace: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final workspaces = auth.workspaces;
    final error = auth.workspaceListError;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Workspaces'),
        automaticallyImplyLeading: false,
        // Escaping back to the shell is only possible when a valid workspace
        // is active; at startup with none, selection is the only way out.
        leading: auth.hasValidWorkspace
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => context.go(Routes.dashboard),
              )
            : null,
      ),
      body: Stack(
        children: [
          if (auth.isLocalMode || !auth.canManageWorkspaces)
            EmptyState(
              icon: MdiIcons.layersTripleOutline,
              title: 'Workspaces need a server',
              subtitle:
                  'Connect a Notees server to manage workspaces.',
            )
          else if (workspaces == null && error == null)
            const Center(child: CircularProgressIndicator())
          else if (workspaces == null)
            _ListError(message: error!, onRetry: _refresh)
          else if (workspaces.isEmpty)
            _EmptyList(onCreate: () => _showNameSheet())
          else
            ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Fail-loud refusal: a keyed workspace this session cannot
                // open stays visible with the unlock re-prompt until an
                // open succeeds (or the state clears).
                if (auth.workspaceOpenError != null) ...[
                  FleetCard(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 16),
                      child: Row(
                        children: [
                          Icon(MdiIcons.lockOutline,
                              color: colors.error),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(auth.workspaceOpenError!),
                          ),
                          TextButton(
                            onPressed: () => _showUnlockDialog(auth),
                            child: const Text('Unlock'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                FleetCard(
                  child: Column(
                    children: [
                      for (final workspace in workspaces) ...[
                        _workspaceTile(workspace, auth),
                        if (workspace != workspaces.last)
                          const Divider(height: 1),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                FleetCard(
                  onTap: () => _showNameSheet(),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Row(
                      children: [
                        Icon(MdiIcons.plus),
                        SizedBox(width: 12),
                        Text('New workspace'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          if (_busy)
            const ModalBarrier(
              color: Colors.black26,
              dismissible: false,
            ),
          if (_busy)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }

  Widget _workspaceTile(Workspace workspace, AuthProvider auth) {
    final colors = Theme.of(context).colorScheme;
    final isActive = workspace.uuid == auth.activeWorkspaceId;
    final role = _capitalizeRole(workspace.role);
    final subtitle = <String>[
      if (role.isNotEmpty) role,
      if (isActive) 'Active',
    ].join(' · ');
    return ListTile(
      leading: Icon(
        MdiIcons.layersTripleOutline,
        color: isActive ? colors.primary : colors.onSurfaceVariant,
      ),
      title: Text(workspace.displayName),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Encrypted workspaces carry the lock badge (the listing's
          // `encrypted` flag); without the master key a tap refuses loud.
          if (workspace.encrypted)
            Icon(MdiIcons.lockOutline,
                size: 18, color: colors.onSurfaceVariant),
          if (workspace.encrypted) const SizedBox(width: 8),
          if (isActive)
            Icon(MdiIcons.check, color: colors.primary),
          // Owner-only, matching the server's PATCH semantics; the web
          // manager's per-card actions menu is a single rename here.
          if (workspace.isOwner)
            IconButton(
              icon: Icon(MdiIcons.dotsVertical),
              tooltip: 'Rename ${workspace.displayName}',
              onPressed: () => _showNameSheet(workspace: workspace),
            )
          else if (!isActive)
            Icon(MdiIcons.chevronRight),
        ],
      ),
      onTap: () => _enterWorkspace(workspace, auth),
    );
  }

  String _capitalizeRole(String? role) {
    if (role == null || role.isEmpty) return '';
    return role[0].toUpperCase() + role.substring(1);
  }
}

/// Honest empty state: zero workspaces means there is nothing to select.
class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyState(
              icon: MdiIcons.layersTripleOutline,
              title: 'Create your first workspace',
              subtitle:
                  'A workspace holds your notes, pages, and tasks — create one to get started.',
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: onCreate,
              icon: Icon(MdiIcons.plus),
              label: const Text('New workspace'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fetch failure with a retry — the list may be unreachable, but the session
/// is fine.
class _ListError extends StatelessWidget {
  const _ListError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              MdiIcons.cloudAlertOutline,
              size: 48,
              color: colors.onSurfaceVariant.withAlpha((0.35 * 255).round()),
            ),
            const SizedBox(height: 16),
            Text(
              'Could not load workspaces',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant
                        .withAlpha((0.75 * 255).round()),
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: Icon(MdiIcons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Create / rename workspace name sheet. Create may be submitted unnamed (the
/// server names it by default); rename requires a name (the server 422s an
/// empty one), enforced before the request leaves the client.
class _WorkspaceNameSheet extends StatefulWidget {
  const _WorkspaceNameSheet({this.workspace});

  final Workspace? workspace;

  @override
  State<_WorkspaceNameSheet> createState() => _WorkspaceNameSheetState();
}

class _WorkspaceNameSheetState extends State<_WorkspaceNameSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.workspace?.name ?? '');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (widget.workspace != null && name.isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    Navigator.of(context).pop(name);
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
            widget.workspace == null ? 'New workspace' : 'Rename workspace',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: widget.workspace == null ? 'Workspace' : null,
              prefixIcon: Icon(MdiIcons.layersTripleOutline),
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _submit,
                child: Text(widget.workspace == null ? 'Create' : 'Rename'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The unlock re-prompt (the web client's W2 modal, native patterns from
/// the biometric Lock screen): asks for the account password, derives the
/// master key into custody via `POST /auth/unlock`, and lets the provider
/// re-open the refused workspace in place. Wrong password and the
/// account-locked rate limit render as the form error — the server's
/// message carries the retry-after.
class UnlockWorkspaceDialog extends StatefulWidget {
  const UnlockWorkspaceDialog({super.key});

  @override
  State<UnlockWorkspaceDialog> createState() =>
      _UnlockWorkspaceDialogState();
}

class _UnlockWorkspaceDialogState extends State<UnlockWorkspaceDialog> {
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    HapticFeedback.lightImpact();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context
          .read<AuthProvider>()
          .unlockWorkspace(_passwordController.text);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final email = context.watch<AuthProvider>().user?.email ?? '';

    return AlertDialog(
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                MdiIcons.lockOutline,
                size: 32,
                color: colors.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Unlock workspace',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              email.isEmpty
                  ? 'Enter your account password to open this workspace.'
                  : 'Enter the password for $email to open this workspace.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              autofocus: true,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: Icon(MdiIcons.lockOutline),
                errorText: _error,
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword
                      ? MdiIcons.eyeOutline
                      : MdiIcons.eyeOffOutline),
                  onPressed: () => setState(
                      () => _obscurePassword = !_obscurePassword),
                ),
              ),
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Unlocking…' : 'Unlock'),
        ),
      ],
    );
  }
}
