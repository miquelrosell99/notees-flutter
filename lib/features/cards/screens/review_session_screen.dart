import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/system.dart';
import '../../../core/utils/uuid7.dart';
import '../../../data/models/node.dart';
import '../../../data/repositories/node_cache_repository.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../data/repositories/prefs_repository.dart';
import '../../../domain/models/search_filters.dart';
import '../../../domain/services/card_schedule.dart';
import '../../../domain/services/srs.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/fleet_card.dart';
import '../../auth/providers/auth_provider.dart';
import '../../editor/widgets/ast_rich_text.dart';

/// The review-session hand-off — the local equivalent of the web
/// sessionStorage hand-off: the queue's card ids plus the summary label
/// the session's header wears ("All cards", "Single card", a filtered
/// summary).
class CardsSessionHandOff {
  const CardsSessionHandOff({required this.cardIds, required this.label});

  final List<String> cardIds;
  final String label;

  /// Parses `state.extra`; null for a missing/corrupt extra (the route then
  /// falls back to every card member, the web deep-link fallback). An
  /// EXPLICIT empty cardIds list is a valid hand-off — the session renders
  /// its "Nothing to review" empty state, the web behavior for an empty
  /// queue.
  static CardsSessionHandOff? fromExtra(Object? extra) {
    if (extra is! Map) return null;
    final rawIds = extra['cardIds'];
    final label = extra['label'];
    if (rawIds is! List) return null;
    final cardIds = rawIds.whereType<String>().toList(growable: false);
    if (label is! String) return null;
    return CardsSessionHandOff(cardIds: cardIds, label: label);
  }
}

/// One loaded card: the node, its embedded children (the back), the SRS
/// state (`ReviewSession.tsx` parity).
class _LoadedCard {
  const _LoadedCard({
    required this.id,
    required this.node,
    required this.children,
    required this.state,
  });

  final String id;
  final Node node;
  final List<Node> children;
  final CardSrsState state;
}

/// The review session (`/cards/review`) — grades the hand-off queue
/// (`ReviewSession.tsx` parity): front = the card node's own content;
/// Reveal → back = the node row + its embedded children (front-only cards
/// name their emptiness, grading still works); four grade buttons
/// (Again = danger); one `sessionId` (uuidv7) per session grades together.
///
/// [repository]/[prefsRepository] are injectable for tests; in production
/// they are built from the [AuthProvider] in `initState`.
class ReviewSessionScreen extends StatefulWidget {
  const ReviewSessionScreen({
    super.key,
    this.cardIds,
    this.label,
    this.repository,
    this.prefsRepository,
  });

  /// The hand-off queue; null = resolve every card member (deep-link arm).
  final List<String>? cardIds;

  /// The summary label for the session header.
  final String? label;

  final NodeRepository? repository;
  final PrefsRepository? prefsRepository;

  @override
  State<ReviewSessionScreen> createState() => _ReviewSessionScreenState();
}

class _ReviewSessionScreenState extends State<ReviewSessionScreen> {
  late final String _sessionId = Uuid7.generate();

  NodeRepository? _repository;

  /// The scheduler pref source — injected (tests) or self-provisioned from
  /// the [AuthProvider] exactly like the hub (cards_screen.dart). Without
  /// the self-provisioned repository the session would silently grade with
  /// the fsrs default regardless of the hub's toggle.
  PrefsRepository? _prefsRepository;

  List<_LoadedCard>? _cards;
  Object? _error;
  SrsAlgorithm? _algorithm;
  int _index = 0;
  bool _revealed = false;
  bool _grading = false;
  int _reviewed = 0;
  int _lapses = 0;

  @override
  void initState() {
    super.initState();
    if (widget.repository != null && widget.prefsRepository != null) {
      // Injected (test) path: both repositories provided.
      _repository = widget.repository;
      _prefsRepository = widget.prefsRepository;
      _load();
      return;
    }
    final auth = context.read<AuthProvider>();
    final dio = auth.dio;
    if (dio == null) {
      setState(() => _error = 'Review requires a synced workspace.');
      return;
    }
    _repository = widget.repository ?? NodeRepository(dio: dio, syncService: auth.syncService);
    _prefsRepository = widget.prefsRepository ??
        PrefsRepository(dio: dio, prefs: auth.prefs);
    _load();
  }

  Future<void> _load() async {
    final repository = _repository!;
    final prefsRepository = _prefsRepository!;
    try {
      // The scheduler is read once at mount; the op records which ran.
      final algorithm = await prefsRepository.getCardsAlgorithm();
      var ids = widget.cardIds;
      if (ids == null) {
        // Deep-link fallback: every card-classed member — the queue takes
        // the due + fresh set (future-due never enters the session).
        final members = await repository.searchWithFilters(
          const SearchFilters(classUuids: [SystemClassUuids.card], limit: 500),
        );
        ids = members.map((node) => node.uuid).toList(growable: false);
      }
      final rows = <CardScheduleRow>[];
      final propsById = <String, List<EffectiveProperty>>{};
      for (final id in ids) {
        final props = await repository.fetchEffectiveProperties(id);
        propsById[id] = props;
        rows.add(CardScheduleRow(id: id, due: srsStateOf(props).due));
      }
      final queue = buildReviewQueue(rows, todayIsoLocal());
      final loaded = <_LoadedCard>[];
      for (final id in queue) {
        final node = await repository.getCachedNode(id);
        if (node == null) continue; // vanished between hand-off and open
        loaded.add(_LoadedCard(
          id: id,
          node: node,
          children: await repository.getChildren(id),
          state: srsStateOf(propsById[id]!),
        ));
      }
      if (!mounted) return;
      setState(() {
        _cards = loaded;
        _algorithm = algorithm;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  _LoadedCard? get _current {
    final cards = _cards;
    return cards != null && _index < cards.length ? cards[_index] : null;
  }

  Future<void> _grade(CardGrade gradeValue) async {
    final card = _current;
    final algorithm = _algorithm;
    if (card == null || algorithm == null || _grading) return;
    final stateBefore = card.state;
    final stateAfter = nextCardState(stateBefore, gradeValue, algorithm, todayIsoLocal());
    setState(() => _grading = true);
    try {
      await _repository!.reviewCard(
        cardId: card.id,
        stateAfter: stateAfter,
        algorithm: algorithm,
        sessionId: _sessionId,
        grade: gradeValue,
        stateBefore: stateBefore,
        reviewedAt: DateTime.now(),
      );
    } finally {
      if (mounted) setState(() => _grading = false);
    }
    if (!mounted) return;
    setState(() {
      _reviewed += 1;
      if (gradeValue == CardGrade.again && stateBefore.reps > 0) _lapses += 1;
      _revealed = false;
      _index += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cards = _cards;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review'),
        actions: [
          IconButton(
            icon: Icon(MdiIcons.close),
            tooltip: 'Exit review',
            onPressed: () => context.pop(),
          ),
        ],
      ),
      body: _error != null
          ? const Center(child: Text('Could not start the review session'))
          : cards == null || _algorithm == null
              ? const Center(child: CircularProgressIndicator())
              : cards.isEmpty
                  ? _buildEmpty(context)
                  : _index >= cards.length
                      ? _buildSummary(context)
                      : _buildCard(context, cards),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: EmptyState(
            icon: MdiIcons.cardsPlayingOutline,
            title: 'Nothing to review',
            subtitle: 'No cards are due. New cards appear here once the card class is assigned.',
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: FilledButton(
              onPressed: () => context.pop(),
              child: const Text('Back to cards'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummary(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$_reviewed card${_reviewed == 1 ? '' : 's'} reviewed',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (_lapses > 0) ...[
            const SizedBox(height: 8),
            Text('$_lapses lapse${_lapses == 1 ? '' : 's'}'),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => context.pop(),
            child: const Text('Back to cards'),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context, List<_LoadedCard> cards) {
    final card = _current!;
    final label = widget.label;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${_index + 1} of ${cards.length}'
              '${label != null && label.isNotEmpty ? ' · $label' : ''}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              FleetCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AstRichText(source: card.node.name),
                      if (_revealed) ...[
                        const Divider(height: 24),
                        if (card.children.isEmpty)
                          EmptyState(
                            icon: MdiIcons.cardTextOutline,
                            title: 'No answer on this card',
                          )
                        else
                          ...card.children.map(
                            (child) => Padding(
                              padding: const EdgeInsets.only(left: 16, top: 8),
                              child: AstRichText(
                                source: child.name,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _revealed ? _buildGradeBar(context) : _buildReveal(context),
          ),
        ),
      ],
    );
  }

  Widget _buildReveal(BuildContext context) {
    return FilledButton(
      onPressed: () => setState(() => _revealed = true),
      child: const Text('Reveal'),
    );
  }

  Widget _buildGradeBar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final grades = <(CardGrade, String)>[
      (CardGrade.again, 'Again'),
      (CardGrade.hard, 'Hard'),
      (CardGrade.good, 'Good'),
      (CardGrade.easy, 'Easy'),
    ];
    return Row(
      children: [
        for (final (grade, label) in grades)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: grade == CardGrade.again
                  ? FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.error,
                        foregroundColor: colors.onError,
                      ),
                      onPressed: _grading ? null : () => _grade(grade),
                      child: Text(label),
                    )
                  : OutlinedButton(
                      onPressed: _grading ? null : () => _grade(grade),
                      child: Text(label),
                    ),
            ),
          ),
      ],
    );
  }
}
