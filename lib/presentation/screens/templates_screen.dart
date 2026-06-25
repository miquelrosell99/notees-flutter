import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../data/models/node.dart';
import '../../data/repositories/template_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/fleet_card.dart';
import '../widgets/section_title.dart';

/// Lists available templates and instantiates them.
class TemplatesScreen extends StatefulWidget {
  const TemplatesScreen({super.key});

  @override
  State<TemplatesScreen> createState() => _TemplatesScreenState();
}

class _TemplatesScreenState extends State<TemplatesScreen> {
  List<Node> _templates = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = TemplateRepository(dio: auth.dio!);
      final templates = await repo.fetchTemplates();
      if (mounted) {
        setState(() {
          _templates = templates;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onTemplateTap(Node template) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final repo = TemplateRepository(dio: auth.dio!);
    late final List<String> variables;
    try {
      variables = await repo.fetchTemplateVariables(template.uuid);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load variables: $e')),
        );
      }
      return;
    }

    Map<String, String>? values = {};
    if (variables.isNotEmpty) {
      if (!mounted) return;
      values = await showDialog<Map<String, String>>(
        context: context,
        builder: (ctx) => _TemplateVariablesDialog(variables: variables),
      );
    }

    if (values == null || !mounted) return;

    setState(() => _loading = true);
    try {
      final node = await repo.instantiateTemplate(
        template.uuid,
        variables: values,
      );
      if (mounted) {
        HapticFeedback.lightImpact();
        context.push('${Routes.editor}/${node.uuid}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Templates'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadTemplates,
        child: _loading && _templates.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final colors = Theme.of(context).colorScheme;

    if (_error != null) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              _error!,
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      );
    }

    if (_templates.isEmpty) {
      return const Center(child: Text('No templates'));
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SectionTitle(
          icon: Icons.description_outlined,
          label: 'Choose a template',
        ),
        const SizedBox(height: 8),
        FleetCard(
          child: Column(
            children: _templates.asMap().entries.map((entry) {
              final template = entry.value;
              final isLast = entry.key == _templates.length - 1;
              return Column(
                children: [
                  ListTile(
                    leading: Icon(
                      Icons.description_outlined,
                      color: colors.onSurfaceVariant,
                    ),
                    title: Text(template.displayName),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: colors.onSurfaceVariant,
                    ),
                    onTap: () => _onTemplateTap(template),
                  ),
                  if (!isLast) const Divider(height: 1),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

class _TemplateVariablesDialog extends StatefulWidget {
  const _TemplateVariablesDialog({required this.variables});

  final List<String> variables;

  @override
  State<_TemplateVariablesDialog> createState() =>
      _TemplateVariablesDialogState();
}

class _TemplateVariablesDialogState extends State<_TemplateVariablesDialog> {
  final Map<String, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    for (final variable in widget.variables) {
      _controllers[variable] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Template variables'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: widget.variables.map((variable) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: _controllers[variable],
                decoration: InputDecoration(
                  labelText: variable,
                ),
                textCapitalization: TextCapitalization.sentences,
              ),
            );
          }).toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final values = <String, String>{};
            for (final entry in _controllers.entries) {
              values[entry.key] = entry.value.text.trim();
            }
            Navigator.of(context).pop(values);
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
