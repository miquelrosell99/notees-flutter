import 'package:flutter/foundation.dart';

import '../../../core/constants/system.dart';
import '../../../data/models/node.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../domain/models/relay/operation_payloads.dart';
import '../../../domain/models/search_filters.dart';
import '../../../domain/services/card_schedule.dart';
import '../../../domain/services/sync_v2_service.dart';

/// One hub member: the card node plus its effective cardDue day
/// (null = fresh — never scheduled).
class CardMember {
  const CardMember({required this.node, this.due});

  final Node node;

  /// The effective `cardDue` day (YYYY-MM-DD); null = fresh.
  final String? due;
}

/// One card-family seed spec (`CARD_FAMILY_SEED` parity: the reserved
/// schema id, the canonical name, the wire type).
class CardFamilySpec {
  const CardFamilySpec(this.schemaId, this.name, this.type);

  final String schemaId;
  final String name;
  final String type;
}

/// The six SRS schedule schemas, reserved ids + canonical names/types
/// (the web `CARD_FAMILY_SEED`, SystemPropertyUuids parity).
const cardFamilySpecs = <CardFamilySpec>[
  CardFamilySpec(SystemPropertyUuids.cardDue, 'Card due', 'datetime'),
  CardFamilySpec(SystemPropertyUuids.cardReps, 'Card reps', 'number'),
  CardFamilySpec(SystemPropertyUuids.cardInterval, 'Card interval', 'number'),
  CardFamilySpec(SystemPropertyUuids.cardEase, 'Card ease', 'number'),
  CardFamilySpec(SystemPropertyUuids.cardDifficulty, 'Card difficulty', 'number'),
  CardFamilySpec(SystemPropertyUuids.cardStability, 'Card stability', 'number'),
];

/// The Cards hub's state: the card members, the due/fresh/later partition,
/// and the family self-heal (`ensureCardFamily` — the web `cardFamily.ts`
/// port).
class CardsHubProvider extends ChangeNotifier {
  CardsHubProvider({
    required this._repository,
    required this._syncService,
    this._isLocalWorkspace = false,
  });

  final NodeRepository _repository;
  final SyncV2Service _syncService;
  final bool _isLocalWorkspace;

  bool _loading = true;
  Object? _error;
  List<CardMember> _members = const [];
  CardBuckets _buckets = const CardBuckets(due: [], fresh: [], later: []);

  bool get loading => _loading;
  Object? get error => _error;

  /// Every node classed `card`, in member order.
  List<CardMember> get members => _members;

  /// The due/fresh/later partition of the effective cardDue reads.
  CardBuckets get buckets => _buckets;

  /// The review session's set: due + fresh ids, the bucket order
  /// (due day-asc, then fresh input order — the Due action contract).
  List<String> get reviewIds => [
        ..._buckets.due.map((row) => row.id),
        ..._buckets.fresh.map((row) => row.id),
      ];

  /// Loads the members and re-derives the buckets. The family self-heal
  /// runs first (a no-op once present; skipped for local workspaces — the
  /// local seed authors the family).
  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      if (!_isLocalWorkspace) {
        await ensureCardFamily();
      }
      final members = await _repository.searchWithFilters(
        const SearchFilters(classUuids: [SystemClassUuids.card], limit: 500),
      );
      final cards = <CardMember>[];
      final rows = <CardScheduleRow>[];
      for (final node in members) {
        final state = srsStateOf(await _repository.fetchEffectiveProperties(node.uuid));
        cards.add(CardMember(node: node, due: state.due));
        rows.add(CardScheduleRow(id: node.uuid, due: state.due));
      }
      _members = cards;
      _buckets = partitionCardsIntoBuckets(rows, todayIsoLocal());
    } catch (error) {
      _error = error;
    }
    _loading = false;
    notifyListeners();
  }

  /// Author the six card property schemas + card-class bindings when
  /// missing; a complete no-op once present (idempotent — safe on every
  /// open, `cardFamily.ts` parity). PRESENCE is the binding contract (the
  /// web `cardFamilyPresent` checks `getClassBindings` with NO active
  /// filter): a soft-unbound row (active = 0) counts as present — the user
  /// unbound it on purpose and the self-heal must NOT re-author it on
  /// every open. The schemas land GLOBAL-scoped with an empty
  /// binding-fields object (all seed unpinned; the schema arm stays
  /// active-only, the web `listPropertySchemas` filter); the card class
  /// node is an always-on system seed — never fabricated here, and the
  /// binding pass is skipped when it is absent (the bindings would attach
  /// to nothing and re-author on every open).
  Future<void> ensureCardFamily() async {
    final present = await Future.wait(
      cardFamilySpecs.map(
        (spec) async =>
            await _repository.fetchPropertySchemaRow(spec.schemaId) != null &&
            await _repository.fetchClassPropertyBindingActive(
                  SystemClassUuids.card,
                  spec.schemaId,
                ) !=
                null,
      ),
    );
    if (present.every((isPresent) => isPresent)) {
      return;
    }
    for (final spec in cardFamilySpecs) {
      if (await _repository.fetchPropertySchemaRow(spec.schemaId) == null) {
        await _syncService.emitLocal(
          opType: 'propertySchema.create',
          payload: OperationPayloads.propertySchemaCreate(
            propertySchemaId: spec.schemaId,
            name: spec.name,
            type: spec.type,
          ),
          affectedNodeIds: [spec.schemaId],
        );
      }
    }
    if (await _repository.findClassByUuid(SystemClassUuids.card) == null) {
      return;
    }
    for (final spec in cardFamilySpecs) {
      // Row presence, not the active flag (see the method doc).
      if (await _repository.fetchClassPropertyBindingActive(SystemClassUuids.card, spec.schemaId) !=
          null) {
        continue;
      }
      await _syncService.emitLocal(
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: SystemClassUuids.card,
          propertySchemaId: spec.schemaId,
        ),
        affectedNodeIds: [SystemClassUuids.card],
      );
    }
  }
}
