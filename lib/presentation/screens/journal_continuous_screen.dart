import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/routing/router.dart';
import '../../core/utils/ast_stringifier.dart';
import '../../data/models/node.dart';
import '../../data/repositories/node_repository.dart';
import '../../domain/models/search_filters.dart';
import '../providers/auth_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/fleet_card.dart';
import '../widgets/section_title.dart';

/// A continuous, scrollable view of recent journal entries.
///
/// Each day is shown as a card in reverse-chronological order; tapping a day
/// opens it in the editor. This is the dedicated "Journals" destination from
/// the Library and command palette.
class JournalContinuousScreen extends StatefulWidget {
  const JournalContinuousScreen({super.key});

  @override
  State<JournalContinuousScreen> createState() => _JournalContinuousScreenState();
}

class _JournalContinuousScreenState extends State<JournalContinuousScreen> {
  List<Node> _journals = [];
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
          limit: 60,
        ),
      );
      if (mounted) {
        setState(() {
          _journals = journals;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
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
        context.push('${Routes.editor}/${journal.uuid}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openNode(Node node) {
    HapticFeedback.lightImpact();
    context.push('${Routes.editor}/${node.uuid}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Journals'),
        actions: [
          IconButton(
            icon: Icon(MdiIcons.calendarEditOutline),
            tooltip: "Today's journal",
            onPressed: _openToday,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadJournals,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(colors),
      ),
    );
  }

  Widget _buildContent(ColorScheme colors) {
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          EmptyState(
            icon: MdiIcons.alertCircleOutline,
            title: 'Could not load journals',
            subtitle: _error,
          ),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: _loadJournals,
              icon: Icon(MdiIcons.refresh),
              label: const Text('Retry'),
            ),
          ),
        ],
      );
    }

    if (_journals.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Center(
            child: Column(
              children: [
                Text(
                  'No journal entries yet.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _openToday,
                  icon: Icon(MdiIcons.pencilOutline),
                  label: const Text("Write today's journal"),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _journals.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: SectionTitle(
              icon: MdiIcons.history,
              label: 'Recent entries',
            ),
          );
        }
        final journal = _journals[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _JournalCard(
            journal: journal,
            onTap: _openNode,
          ),
        );
      },
    );
  }
}

class _JournalCard extends StatelessWidget {
  const _JournalCard({
    required this.journal,
    required this.onTap,
  });

  final Node journal;
  final ValueChanged<Node> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final date = _parseDate(journal.displayName);
    final preview = _buildPreview(journal);

    return FleetCard(
      onTap: () => onTap(journal),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(MdiIcons.calendarOutline, size: 18, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    date,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                Icon(MdiIcons.chevronRight, color: colors.onSurfaceVariant),
              ],
            ),
            if (preview.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                preview,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _parseDate(String displayName) {
    try {
      final parsed = DateTime.parse(displayName);
      return DateFormat.yMMMMEEEEd().format(parsed);
    } catch (_) {
      return displayName;
    }
  }

  String _buildPreview(Node journal) {
    final buffer = StringBuffer();
    for (final child in journal.children.take(5)) {
      final text = astToPlainText(child.name).trim();
      if (text.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('  ');
        buffer.write(text);
      }
    }
    return buffer.toString();
  }
}
