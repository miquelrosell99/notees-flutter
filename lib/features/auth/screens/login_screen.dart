import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  bool _rememberMe = false;

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    HapticFeedback.lightImpact();

    final auth = context.read<AuthProvider>();
    await auth.login(
      _emailController.text.trim(),
      _passwordController.text,
      rememberMe: _rememberMe,
    );

    if (!mounted) return;
    if (auth.isAuthenticated) {
      context.go('/dashboard');
    }
  }

  Future<void> _verify() async {
    if (!_formKey.currentState!.validate()) return;
    HapticFeedback.lightImpact();

    final auth = context.read<AuthProvider>();
    await auth.verifyTwoFactor(_codeController.text.trim());

    if (!mounted) return;
    if (auth.isAuthenticated) {
      context.go('/dashboard');
    }
  }

  void _cancelTwoFactor() {
    HapticFeedback.lightImpact();
    _codeController.clear();
    context.read<AuthProvider>().cancelTwoFactor();
  }

  void _changeServer() {
    HapticFeedback.lightImpact();
    context.go('/server-setup');
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in'),
        actions: [
          TextButton(
            onPressed: _changeServer,
            child: const Text('Change server'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (auth.activeServer != null)
              Text(
                auth.activeServer!.url,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 24),
            Form(
              key: _formKey,
              child: auth.twoFactorChallenge != null
                  ? _buildTwoFactorStep(auth, colors)
                  : _buildPasswordStep(auth, colors),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPasswordStep(AuthProvider auth, ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Email',
            prefixIcon: Icon(MdiIcons.emailOutline),
          ),
          validator: (value) {
            final trimmed = value?.trim() ?? '';
            if (trimmed.isEmpty) return 'Email is required';
            if (!trimmed.contains('@')) return 'Enter a valid email';
            return null;
          },
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: Icon(MdiIcons.lockOutline),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword ? MdiIcons.eyeOff : MdiIcons.eye,
              ),
              tooltip: 'Toggle password visibility',
              onPressed: () {
                HapticFeedback.lightImpact();
                setState(() => _obscurePassword = !_obscurePassword);
              },
            ),
          ),
          validator: (value) {
            if (value == null || value.length < 8) {
              return 'Password must be at least 8 characters';
            }
            return null;
          },
          onFieldSubmitted: (_) => _login(),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _rememberMe,
          onChanged: (value) {
            HapticFeedback.lightImpact();
            setState(() => _rememberMe = value ?? false);
          },
          title: const Text('Remember me'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
        if (auth.error != null) ...[
          const SizedBox(height: 12),
          _ErrorText(message: auth.error!),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: auth.busy ? null : _login,
          icon: auth.busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(MdiIcons.login),
          label: const Text('Sign in'),
        ),
      ],
    );
  }

  Widget _buildTwoFactorStep(AuthProvider auth, ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Two-factor authentication',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Enter the 6-digit code from your authenticator app, or one of your backup codes.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _codeController,
          autofocus: true,
          autocorrect: false,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Authentication code',
            prefixIcon: Icon(MdiIcons.shieldKeyOutline),
          ),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return 'Enter your authentication code';
            }
            return null;
          },
          onFieldSubmitted: (_) => _verify(),
        ),
        if (auth.error != null) ...[
          const SizedBox(height: 12),
          _ErrorText(message: auth.error!),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: auth.busy ? null : _verify,
          icon: auth.busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(MdiIcons.shieldCheckOutline),
          label: const Text('Verify'),
        ),
        TextButton(
          onPressed: auth.busy ? null : _cancelTwoFactor,
          child: const Text('Back to password'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.error,
          ),
      textAlign: TextAlign.center,
    );
  }
}
