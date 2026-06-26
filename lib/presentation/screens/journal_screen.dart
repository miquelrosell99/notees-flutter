import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../../domain/models/search_filters.dart';
import '../providers/auth_provider.dart';
import '../views/node_list_view.dart';
import '../widgets/fleet_card.dart';
import '../widgets/section_title.dart';

/// Dedicated journal tab: today, date picker, and recent journals.
class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key});

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  List<Node> _recentJournals = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadJournals();
  }

  Future<void> _loadJournals() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final journals = await repo.searchWithFilters(
        const SearchFilters(
          nodeType: NodeType.journal,
          sortBy: SortBy.writeDate,
          order: SortOrder.desc,
          limit: 30,
        ),
      );
      setState(() {
        _recentJournals = journals;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _openToday() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final journal = await repo.getOrCreateDailyJournal(DateTime.now());
      if (mounted) {
        context.push('${Routes.editor}/${journal.id}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openDate(DateTime date) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final journal = await repo.getOrCreateDailyJournal(date);
      if (mounted) {
        context.push('${Routes.editor}/${journal.id}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1),
    );
    if (picked != null) await _openDate(picked);
  }

  void _openNode(Node node) {
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${node.id}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final today = DateTime.now();
    final todayLabel = DateFormat.yMMMMEEEEd().format(today);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Journal'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadJournals,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(colors, todayLabel),
      ),
    );
  }

  Widget _buildContent(ColorScheme colors, String todayLabel) {
    if (_error != null) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(_error!, style: TextStyle(color: colors.error)),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FleetCard(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.edit_calendar_outlined, color: colors.primary),
                title: const Text('Today'),
                subtitle: Text(todayLabel),
                trailing: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
                onTap: _openToday,
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.calendar_month_outlined, color: colors.onSurfaceVariant),
                title: const Text('Pick a date'),
                trailing: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
                onTap: _pickDate,
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        const SectionTitle(icon: Icons.history_outlined, label: 'Recent journals'),
        const SizedBox(height: 8),
        FleetCard(
          child: _recentJournals.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('No recent journals')),
                )
              : NodeListView(
                  nodes: _recentJournals,
                  onNodeTap: _openNode,
                  shrinkWrap: true,
                ),
        ),
      ],
    );
  }
}
