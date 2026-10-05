import '../../core/constants/system.dart';
import '../../core/utils/ast_builder.dart';
import '../models/relay/operation_payloads.dart';
import './sync_v2_service.dart';

/// Client-side local workspace seed for offline (serverless) mode.
///
/// Mirrors the web client's seed and the server seed: emits `class.create`
/// for every system class, then `object.create` for the Inbox. (The
/// scratchpad page the local seed used to mint as a personal page was
/// withdrawn 2026-10-05 per §34.81 of the main repo's plan — "not wanted";
/// the web/server seed no longer creates it either.)
///
/// Ops go through the normal outbox/applier path ([SyncV2Service.emitLocal]),
/// so the local derived state matches what a server-seeded workspace would
/// produce, and the ops stay in the outbox to be pushed if a server is
/// attached later.
class LocalWorkspaceSeed {
  LocalWorkspaceSeed(this._sync);

  final SyncV2Service _sync;

  /// Class name → fixed system class UUID. Matches `SYSTEM_CLASS_UUIDS` in
  /// `frontend/src/constants/systemProperties.ts` (the obsolete `page` class
  /// is not seeded; page status derives from the node kind).
  static const Map<String, String> systemClassNames = {
    'class': SystemClassUuids.class_,
    'year': SystemClassUuids.year,
    'month': SystemClassUuids.month,
    'day': SystemClassUuids.day,
    'quote': SystemClassUuids.quote,
    'query': SystemClassUuids.query,
    'code': SystemClassUuids.code,
    'asset': SystemClassUuids.asset,
    'whiteboard': SystemClassUuids.whiteboard,
    'card': SystemClassUuids.card,
    'task': SystemClassUuids.task,
    'template': SystemClassUuids.template,
    'comment': SystemClassUuids.comment,
    'table': SystemClassUuids.table,
    'warning': SystemClassUuids.warning,
    'note': SystemClassUuids.note,
    'tip': SystemClassUuids.tip,
    'info': SystemClassUuids.info,
    'danger': SystemClassUuids.danger,
    'success': SystemClassUuids.success,
    'cloze': SystemClassUuids.cloze,
    'source': SystemClassUuids.source,
    'song': SystemClassUuids.song,
    'tv_series': SystemClassUuids.tvSeries,
    'conference': SystemClassUuids.conference,
  };

  /// Icons for the classes the citations-model revision added (TS manifest
  /// `SYSTEM_CLASS_ICONS`); the legacy v1 mobile subset seeds without icons.
  static const Map<String, String> systemClassIcons = {
    'source': 'mdiBookshelf',
    'song': 'mdiMusicNote',
    'tv_series': 'mdiTelevisionClassic',
    'conference': 'mdiPresentation',
  };

  /// Canonical extends edges for the new classes (TS manifest
  /// `SYSTEM_CLASS_EXTENDS`): all three extend `source`.
  static const Map<String, List<String>> systemClassExtends = {
    'song': ['source'],
    'tv_series': ['source'],
    'conference': ['source'],
  };

  /// System property specs the citations-model revision touched (TS manifest
  /// `SYSTEM_PROPERTY_SPECS`, FINAL owner reversion): `authors` is
  /// node-typed again — explicit person linkage to `agent`.
  static const List<SeedPropertySpec> systemPropertySpecs = [
    SeedPropertySpec(
      name: 'authors',
      propertySchemaId: SystemPropertyUuids.authors,
      type: 'object',
      multi: true,
      bindTo: 'source',
      targetClassFilter: <String>[SystemClassUuids.agent],
    ),
  ];

  /// Seeds missing system classes and default pages, idempotently.
  ///
  /// Entries that already exist in the local store (e.g. a previously seeded
  /// or server-synced workspace) are skipped, so re-running emits nothing.
  /// Returns the number of seed operations emitted (0 when already seeded).
  Future<int> ensureLocalWorkspace() async {
    var emitted = 0;

    for (final entry in systemClassNames.entries) {
      final classId = entry.value;
      if (await _sync.cache.getClassByUuid(classId) != null) continue;
      // v2 class.create carries the title as contentAst (title-is-content;
      // the builder wraps the `name` convenience); no separate content op
      // is needed (v1 emitted a node.updateContent for the class-page title).
      await _sync.emitLocal(
        opType: 'class.create',
        payload: OperationPayloads.classCreate(
          classId: classId,
          name: entry.key,
          icon: systemClassIcons[entry.key],
        ),
        affectedNodeIds: [classId],
      );
      emitted += 1;

      final extendsNames = systemClassExtends[entry.key];
      if (extendsNames != null) {
        await _sync.emitLocal(
          opType: 'class.setExtends',
          payload: OperationPayloads.classSetExtends(
            classId: classId,
            parentClassIds: [
              for (final parent in extendsNames)
                systemClassNames[parent]!,
            ],
          ),
          affectedNodeIds: [classId],
        );
        emitted += 1;
      }
    }

    // Property schemas + their class bindings (citations revision).
    for (var i = 0; i < systemPropertySpecs.length; i++) {
      final spec = systemPropertySpecs[i];
      if (await _sync.cache.getPropertySchemaRow(spec.propertySchemaId) != null) {
        continue;
      }
      await _sync.emitLocal(
        opType: 'propertySchema.create',
        payload: OperationPayloads.propertySchemaCreate(
          propertySchemaId: spec.propertySchemaId,
          name: spec.name,
          type: spec.type,
          multi: spec.multi,
          targetClassFilter: spec.targetClassFilter,
        ),
        affectedNodeIds: [spec.propertySchemaId],
      );
      await _sync.emitLocal(
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: systemClassNames[spec.bindTo]!,
          propertySchemaId: spec.propertySchemaId,
          sequence: i,
        ),
        affectedNodeIds: [systemClassNames[spec.bindTo]!],
      );
      emitted += 2;
    }

    final pages = <String, String>{
      'Inbox': SystemPageUuids.inbox,
    };
    for (final entry in pages.entries) {
      final pageId = entry.value;
      if (await _sync.cache.getByUuid(pageId) != null) continue;
      await _sync.emitLocal(
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
          presentAsMain: true,
          contentAst: AstBuilder.parseInline(entry.key),
        ),
        affectedNodeIds: [pageId],
      );
      emitted += 1;
    }

    return emitted;
  }
}

/// One system property-schema spec entry (TS manifest
/// `SYSTEM_PROPERTY_SPECS` slice the mobile seed mirrors).
class SeedPropertySpec {
  const SeedPropertySpec({
    required this.name,
    required this.propertySchemaId,
    required this.type,
    required this.multi,
    required this.bindTo,
    this.targetClassFilter,
  });

  final String name;
  final String propertySchemaId;
  final String type;
  final bool multi;

  /// Class name the schema binds to (key of [LocalWorkspaceSeed.systemClassNames]).
  final String bindTo;
  final List<String>? targetClassFilter;
}
