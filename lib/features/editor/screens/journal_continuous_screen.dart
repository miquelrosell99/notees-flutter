import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/localization/material_localizations_override.dart';
import '../../../core/routing/router.dart';
import '../../../core/utils/ast_stringifier.dart';
import '../../../core/utils/date_uuid.dart';
import '../../../core/utils/node_display_name.dart';
import '../../../data/models/node.dart';
import '../../../data/models/page_content.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../domain/models/search_filters.dart';
import '../../auth/providers/auth_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../widgets/ast_rich_text.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/section_title.dart';

/// A continuous, scrollable view of recent journal entries.
///
/// Each day's blocks are rendered inline (newest first). Tapping a day opens
/// the full editor, and a calendar button in the app bar lets the user jump to
/// or create any date with highlighted days for existing journals.
class JournalContinuousScreen extends StatefulWidget {
  const JournalContinuousScreen({super.key});

  @override
  State<JournalContinuousScreen> createState() => _JournalContinuousScreenState();
}

class _JournalContinuousScreenState extends State<JournalContinuousScreen> {
  List<PageContent> _journalContents = [];
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
      final contents = await Future.wait(
        journals.map((j) => repo.fetchPageContent(j.uuid)),
      );
      if (mounted) {
        setState(() {
          _journalContents = contents;
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

  Future<void> _openDate(DateTime date) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final journal = await repo.getOrCreateDailyJournal(date);
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

  void _showCalendar() {
    HapticFeedback.lightImpact();
    final now = DateTime.now();
    final existingDates = <DateTime>{
      for (final content in _journalContents)
        if (journalDateFromUuid(content.node.uuid) != null)
          journalDateFromUuid(content.node.uuid)!,
    };

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        final settings = ctx.read<SettingsProvider>();
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Jump to journal',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    IconButton(
                      icon: Icon(MdiIcons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              Localizations.override(
                context: ctx,
                delegates: [
                  GlobalMaterialLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  FirstDayOfWeekLocalizationsDelegate(settings.firstDayOfWeek),
                ],
                child: _JournalCalendarPicker(
                  initialDate: now,
                  highlightedDates: existingDates,
                  onDateChanged: (date) {
                    Navigator.of(ctx).pop();
                    _openDate(date);
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Journals'),
        actions: [
          IconButton(
            icon: Icon(MdiIcons.calendarEditOutline),
            tooltip: "Today's journal",
            onPressed: _openToday,
          ),
          IconButton(
            icon: Icon(MdiIcons.calendarMonthOutline),
            tooltip: 'Jump to date',
            onPressed: _showCalendar,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadJournals,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(colors, settings),
      ),
    );
  }

  Widget _buildContent(ColorScheme colors, SettingsProvider settings) {
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

    if (_journalContents.isEmpty) {
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

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      itemCount: _journalContents.length + 1,
      separatorBuilder: (context, index) {
        if (index == 0) return const SizedBox.shrink();
        return const Divider(height: 1);
      },
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 8),
            child: SectionTitle(
              icon: MdiIcons.history,
              label: 'Recent entries',
            ),
          );
        }
        final content = _journalContents[index - 1];
        return _JournalDayCard(
          content: content,
          onHeaderTap: _openNode,
          onBlockTap: _openNode,
          dateFormat: settings.dateFormat,
        );
      },
    );
  }
}

class _JournalDayCard extends StatelessWidget {
  const _JournalDayCard({
    required this.content,
    required this.onHeaderTap,
    required this.onBlockTap,
    required this.dateFormat,
  });

  final PageContent content;
  final ValueChanged<Node> onHeaderTap;
  final ValueChanged<Node> onBlockTap;
  final String dateFormat;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final date = resolveNodeDisplayName(content.node, dateFormat: dateFormat);
    final children = content.node.children.where((b) => !b.isPage).toList();

    return InkWell(
      onTap: () => onHeaderTap(content.node),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
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
            if (children.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Nothing written yet.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                ),
              )
            else
              ...children.map((block) {
                final plain = astToPlainText(block.name).trim();
                if (plain.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: InkWell(
                    onTap: () => onBlockTap(block),
                    borderRadius: BorderRadius.circular(8),
                    child: AstRichText(
                      source: block.name,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                      onNodeLinkTap: (uuid) => context.push('${Routes.editor}/$uuid'),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

/// Calendar picker that highlights days with existing journal entries.
class _JournalCalendarPicker extends StatefulWidget {
  const _JournalCalendarPicker({
    required this.initialDate,
    required this.highlightedDates,
    required this.onDateChanged,
  });

  final DateTime initialDate;
  final Set<DateTime> highlightedDates;
  final ValueChanged<DateTime> onDateChanged;

  @override
  State<_JournalCalendarPicker> createState() => _JournalCalendarPickerState();
}

class _JournalCalendarPickerState extends State<_JournalCalendarPicker> {
  late DateTime _focusedMonth;

  @override
  void initState() {
    super.initState();
    _focusedMonth = DateTime(widget.initialDate.year, widget.initialDate.month);
  }

  bool _hasEntry(DateTime date) {
    return widget.highlightedDates.contains(DateTime(date.year, date.month, date.day));
  }

  void _previousMonth() {
    HapticFeedback.lightImpact();
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
    });
  }

  void _nextMonth() {
    HapticFeedback.lightImpact();
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final firstDayOfWeek = Localizations.of<MaterialLocalizations>(context, MaterialLocalizations)
            ?.firstDayOfWeekIndex ??
        0;

    final daysInMonth = DateUtils.getDaysInMonth(_focusedMonth.year, _focusedMonth.month);
    final firstWeekday = DateTime(_focusedMonth.year, _focusedMonth.month, 1).weekday;
    final leadingPadding = (firstWeekday - firstDayOfWeek + 7) % 7;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(MdiIcons.chevronLeft),
                tooltip: 'Previous month',
                onPressed: _previousMonth,
              ),
              Text(
                '${_monthName(_focusedMonth.month)} ${_focusedMonth.year}',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              IconButton(
                icon: Icon(MdiIcons.chevronRight),
                tooltip: 'Next month',
                onPressed: _nextMonth,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Center(
                    child: Text(
                      _weekdayLabel((firstDayOfWeek + i) % 7),
                      style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 7,
            childAspectRatio: 1,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < leadingPadding; i++) const SizedBox.shrink(),
              for (var day = 1; day <= daysInMonth; day++)
                _buildDayCell(day, colors, theme),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colors.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Has entry',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildDayCell(int day, ColorScheme colors, ThemeData theme) {
    final date = DateTime(_focusedMonth.year, _focusedMonth.month, day);
    final hasEntry = _hasEntry(date);
    final isToday = DateUtils.isSameDay(date, DateTime.now());

    return InkWell(
      onTap: () => widget.onDateChanged(date),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isToday ? colors.primaryContainer : null,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$day',
              style: theme.textTheme.bodyMedium?.copyWith(
                    color: isToday ? colors.onPrimaryContainer : colors.onSurface,
                    fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                  ),
            ),
            if (hasEntry)
              Container(
                width: 5,
                height: 5,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _monthName(int month) {
    return switch (month) {
      1 => 'January',
      2 => 'February',
      3 => 'March',
      4 => 'April',
      5 => 'May',
      6 => 'June',
      7 => 'July',
      8 => 'August',
      9 => 'September',
      10 => 'October',
      11 => 'November',
      12 => 'December',
      _ => '',
    };
  }

  String _weekdayLabel(int weekday) {
    return switch (weekday) {
      DateTime.monday => 'M',
      DateTime.tuesday => 'T',
      DateTime.wednesday => 'W',
      DateTime.thursday => 'T',
      DateTime.friday => 'F',
      DateTime.saturday => 'S',
      DateTime.sunday => 'S',
      _ => '',
    };
  }
}
