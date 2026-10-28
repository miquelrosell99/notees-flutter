import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../../../core/routing/router.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../data/repositories/prefs_repository.dart';
import '../../../domain/services/srs.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/motion.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/cards_hub_provider.dart';
import '../providers/cards_prefs_provider.dart';
import '../widgets/card_bucket_strip.dart';
import '../widgets/card_row.dart';

/// The Cards hub — every node classed `card` (the web `/cards` route
/// parity): the bucket strip (Due action + fresh/later pills), the card
/// list as FleetCard rows, and the algorithm toggle in the AppBar.
///
/// [hub]/[prefs] are injectable for tests; in production they are built
/// from the [AuthProvider] in `initState`.
class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key, this.hub, this.prefs});

  final CardsHubProvider? hub;
  final CardsPrefsProvider? prefs;

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  CardsHubProvider? _hub;
  CardsPrefsProvider? _prefs;

  @override
  void initState() {
    super.initState();
    if (widget.hub != null || widget.prefs != null) {
      // Injected (test) path: the caller constructs, loads, and owns the
      // providers' lifecycle.
      _hub = widget.hub;
      _prefs = widget.prefs;
      return;
    }
    final auth = context.read<AuthProvider>();
    final dio = auth.dio;
    final syncService = auth.syncService;
    if (dio == null || syncService == null) {
      return; // the unsynced-local arm renders a static note
    }
    _hub = CardsHubProvider(
      repository: NodeRepository(dio: dio, syncService: syncService),
      syncService: syncService,
      isLocalWorkspace: auth.isLocalMode,
    );
    _prefs = CardsPrefsProvider(
      repository: PrefsRepository(dio: dio, prefs: auth.prefs),
    );
    _hub!.load();
    _prefs!.load();
  }

  @override
  Widget build(BuildContext context) {
    final hub = _hub;
    final prefs = _prefs;
    if (hub == null || prefs == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cards')),
        body: const Center(child: Text('Cards require a synced workspace.')),
      );
    }
    return ChangeNotifierProvider<CardsHubProvider>.value(
      value: hub,
      child: ChangeNotifierProvider<CardsPrefsProvider>.value(
        value: prefs,
        child: Consumer2<CardsHubProvider, CardsPrefsProvider>(
          builder: (context, hub, prefs, _) {
            return Scaffold(
              appBar: AppBar(
                title: const Text('Cards'),
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SegmentedButton<SrsAlgorithm>(
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      segments: const [
                        ButtonSegment(
                          value: SrsAlgorithm.fsrs,
                          label: Text('FSRS (default)'),
                        ),
                        ButtonSegment(value: SrsAlgorithm.sm2, label: Text('SM-2')),
                      ],
                      selected: {prefs.algorithm},
                      onSelectionChanged: (selection) => prefs.setAlgorithm(selection.first),
                    ),
                  ),
                ],
              ),
              body: RefreshIndicator(
                onRefresh: () async {
                  await hub.load();
                  await prefs.load();
                },
                child: _buildBody(hub),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody(CardsHubProvider hub) {
    if (hub.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (hub.error != null) {
      return const Center(child: Text('Could not load cards'));
    }
    if (hub.members.isEmpty) {
      return EmptyState(
        icon: MdiIcons.cardsPlayingOutline,
        title: 'No cards yet',
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        CardBucketStrip(buckets: hub.buckets, onReview: _startReview),
        ...List.generate(hub.members.length, (index) {
          final member = hub.members[index];
          return staggered(
            index,
            CardRow(
              node: member.node,
              due: member.due,
              onOpen: () => context.push('${Routes.editor}/${member.node.uuid}'),
              onReview: () => _startSingleCard(member),
            ),
          );
        }),
        const SizedBox(height: 16),
      ],
    );
  }

  /// The Due action: a session over the due + fresh set, labeled "All
  /// cards" (the unfiltered hand-off, the web summary).
  void _startReview() {
    context.push(Routes.cardsReview, extra: <String, dynamic>{
      'cardIds': _hub!.reviewIds,
      'label': 'All cards',
    });
  }

  /// The per-row action: a single-card session over the row's node.
  void _startSingleCard(CardMember member) {
    context.push(Routes.cardsReview, extra: <String, dynamic>{
      'cardIds': [member.node.uuid],
      'label': 'Single card',
    });
  }
}
