import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/core/utils/date_uuid.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/data/repositories/node_repository.dart';
import 'package:notees/data/repositories/prefs_repository.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/services/srs.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:notees/features/cards/providers/cards_hub_provider.dart';
import 'package:notees/features/cards/providers/cards_prefs_provider.dart';
import 'package:notees/features/cards/screens/cards_screen.dart';
import 'package:notees/features/cards/widgets/card_row.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The Cards hub: bucket strip counts, the review hand-off ids, the
/// algorithm toggle write, the empty state, and the family self-heal
/// (`ensureCardFamily` — the web `cardFamily.ts` parity).
///
/// sqflite_ffi never completes inside a `testWidgets` fake-async zone, so
/// every database-touching step runs in `setUp` (the real async zone) — the
/// widget bodies only pump and tap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const workspaceId = '10000000-0000-4000-8000-000000000001';

  const cardA = '30000000-0000-4000-8000-00000000000a';
  const cardB = '30000000-0000-4000-8000-00000000000b';
  const cardC = '30000000-0000-4000-8000-00000000000c';

  String isoLocal(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  late AppDatabase database;
  late NodeCacheRepository cache;
  late SyncV2Service service;
  late NodeRepository repo;
  late CardsHubProvider hub;
  late CardsPrefsProvider prefsProvider;
  late List<Map<String, dynamic>> prefsPuts;
  Object? capturedExtra;

  Dio prefsDio() {
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'PUT') {
            prefsPuts.add(Map<String, dynamic>.from(options.data as Map));
          }
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: const {'cardsAlgorithm': 'fsrs'},
          ));
        },
      ),
    );
    return dio;
  }

  setUp(() async {
    final ffiDb = await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    database = AppDatabase.fromDatabase(ffiDb);
    await database.initializeSchema();
    cache = NodeCacheRepository(database);
    await cache.upsertClass(uuid: SystemClassUuids.card, name: 'Memorization card');
    await cache.upsertPropertySchema(
      PropertySchemaRow(uuid: 'schema-1', workspaceId: workspaceId, name: 'P'),
    );

    service = SyncV2Service(
      database: database,
      dio: prefsDio(),
      clientId: '40000000-0000-4000-8000-000000000001',
    );
    await service.setWorkspaceId(workspaceId);
    repo = NodeRepository(dio: prefsDio(), syncService: service);
    hub = CardsHubProvider(repository: repo, syncService: service);
    prefsPuts = [];
    capturedExtra = null;

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    prefsProvider = CardsPrefsProvider(
      repository: PrefsRepository(dio: prefsDio(), prefs: prefs),
    );
    await prefsProvider.load();
  });

  tearDown(() async {
    await database.close();
    AppDatabase.reset();
  });

  Future<void> createCardNode(String uuid, String title) {
    return service.emitLocal(
      opType: 'object.create',
      payload: OperationPayloads.objectCreate(
        objectId: uuid,
        isEmbedded: false,
        classIds: const [SystemClassUuids.card],
        contentAst: AstBuilder.parseInline(title),
      ),
      affectedNodeIds: [uuid],
    );
  }

  /// A cardDue write points at a day node — the applier asserts the ref
  /// target exists, so the day node is created first (parentless create,
  /// the standalone shape the chain self-heal adopts).
  Future<void> setCardDue(String cardId, String isoDay) async {
    final dayUuid = dateToDayUuid(DateTime.parse(isoDay));
    if (await cache.getByUuid(dayUuid) == null) {
      await service.emitLocal(
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: dayUuid,
          isEmbedded: false,
          classIds: const [SystemClassUuids.day],
          name: isoDay.replaceAll('-', ''),
        ),
        affectedNodeIds: [dayUuid],
      );
    }
    await service.setPropertyValue(
      objectId: cardId,
      propertySchemaId: SystemPropertyUuids.cardDue,
      value: {'nodeId': dayUuid},
    );
  }

  Future<List<Map<String, dynamic>>> outboxEnvelopes() async {
    final db = await database.database;
    final rows = await db.query('relay_outbox');
    return rows
        .map((row) => Map<String, dynamic>.from(jsonDecode(row['envelope_json'] as String) as Map))
        .toList();
  }

  /// Pumps the (already loaded, in setUp) hub into a test router whose
  /// /cards/review route captures the session hand-off.
  Future<void> pumpHub(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: GoRouter(
        initialLocation: '/cards',
        routes: [
          GoRoute(
            path: '/cards',
            builder: (context, state) => CardsScreen(hub: hub, prefs: prefsProvider),
          ),
          GoRoute(
            path: '/cards/review',
            builder: (context, state) {
              capturedExtra = state.extra;
              return const Scaffold(body: Text('review-received'));
            },
          ),
          GoRoute(
            path: '/editor/:nodeUuid',
            builder: (context, state) => const Scaffold(body: Text('editor-opened')),
          ),
        ],
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
  }

  group('hub with due, fresh, and later cards', () {
    late String dueA;

    setUp(() async {
      final today = DateTime.now();
      dueA = isoLocal(today.subtract(const Duration(days: 2)));
      await createCardNode(cardA, 'Card A');
      await setCardDue(cardA, dueA);
      await createCardNode(cardB, 'Card B');
      await createCardNode(cardC, 'Card C');
      await setCardDue(cardC, isoLocal(today.add(const Duration(days: 5))));
      await hub.load();
    });

    testWidgets('counts due/fresh/later and hands the review the due + fresh ids',
        (tester) async {
      await pumpHub(tester);

      expect(find.text('Review 1 due · 1 new'), findsOneWidget);
      expect(find.text('1 fresh'), findsOneWidget);
      expect(find.text('1 later'), findsOneWidget);
      expect(find.byType(CardRow), findsNWidgets(3));
      expect(find.text(dueA), findsOneWidget); // the due-day caption

      await tester.tap(find.text('Review 1 due · 1 new'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('review-received'), findsOneWidget);
      final extra = capturedExtra! as Map<String, dynamic>;
      expect(extra['label'], 'All cards');
      expect(extra['cardIds'], [cardA, cardB]); // due first, then fresh
    });

    testWidgets('the per-row play action starts a single-card session',
        (tester) async {
      await pumpHub(tester);

      await tester.tap(find.byTooltip('Review this card').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final extra = capturedExtra! as Map<String, dynamic>;
      expect(extra['label'], 'Single card');
      expect(extra['cardIds'], [cardA]);
    });

    testWidgets('a row tap opens the editor', (tester) async {
      await pumpHub(tester);

      await tester.tap(find.text(dueA));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('editor-opened'), findsOneWidget);
    });
  });

  group('hub with only a future-due card', () {
    setUp(() async {
      await createCardNode(cardC, 'Card C');
      await setCardDue(cardC, isoLocal(DateTime.now().add(const Duration(days: 5))));
      await hub.load();
    });

    testWidgets('nothing to review: the Due action is disabled', (tester) async {
      await pumpHub(tester);

      expect(find.text('Review 0 due'), findsOneWidget);
      await tester.tap(find.text('Review 0 due'));
      await tester.pump();
      expect(find.text('review-received'), findsNothing);
    });
  });

  group('empty hub', () {
    setUp(() async {
      await hub.load();
    });

    testWidgets('shows the empty state and no strip', (tester) async {
      await pumpHub(tester);

      expect(find.text('No cards yet'), findsOneWidget);
      expect(find.textContaining('Review'), findsNothing);
    });
  });

  group('algorithm toggle', () {
    setUp(() async {
      await createCardNode(cardA, 'Card A');
      await hub.load();
    });

    testWidgets('reflects the pref and writes the choice', (tester) async {
      await pumpHub(tester);

      expect(find.text('FSRS (default)'), findsOneWidget);
      await tester.tap(find.text('SM-2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The toggle wrote the scalar through the repository.
      expect(prefsPuts.single, {'cardsAlgorithm': 'sm2'});
      expect(prefsProvider.algorithm, SrsAlgorithm.sm2);
    });
  });

  group('ensureCardFamily (the family self-heal)', () {
    test('authors the six schemas + bindings idempotently on a fresh workspace',
        () async {
      await hub.load();

      final envelopes = await outboxEnvelopes();
      final schemaCreates = envelopes.where((e) => e['opType'] == 'propertySchema.create').toList();
      final bindingSets = envelopes.where((e) => e['opType'] == 'class.property.set').toList();
      expect(schemaCreates, hasLength(6));
      expect(bindingSets, hasLength(6));
      final createdIds =
          schemaCreates.map((e) => (e['payload'] as Map)['propertySchemaId']).toSet();
      expect(createdIds, {
        SystemPropertyUuids.cardDue,
        SystemPropertyUuids.cardReps,
        SystemPropertyUuids.cardInterval,
        SystemPropertyUuids.cardEase,
        SystemPropertyUuids.cardDifficulty,
        SystemPropertyUuids.cardStability,
      });
      // The schemas landed in the cache and are bound to the card class.
      for (final id in createdIds) {
        expect(await repo.fetchClassPropertyBindingActive(SystemClassUuids.card, id), isTrue);
      }

      // Second run: a complete no-op.
      final before = envelopes.length;
      await hub.load();
      expect((await outboxEnvelopes()).length, before);
    });

    test('a soft-unbound binding counts as present (no re-author)', () async {
      await hub.load(); // converge the family first
      // The user soft-unbinds one property (active = 0, the row survives).
      await service.emitLocal(
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: SystemClassUuids.card,
          propertySchemaId: SystemPropertyUuids.cardEase,
          active: false,
        ),
        affectedNodeIds: [SystemClassUuids.card],
      );
      expect(
        await repo.fetchClassPropertyBindingActive(SystemClassUuids.card, SystemPropertyUuids.cardEase),
        isFalse,
      );

      // Presence, not the active flag: the self-heal must NOT re-author the
      // unbound binding on the next open (the web cardFamilyPresent parity).
      final bindingOpsBefore =
          (await outboxEnvelopes()).where((e) => e['opType'] == 'class.property.set').length;
      await hub.load();
      final bindingOpsAfter =
          (await outboxEnvelopes()).where((e) => e['opType'] == 'class.property.set').length;
      expect(bindingOpsAfter, bindingOpsBefore);
    });

    test('skips the binding pass when the card class node is absent', () async {
      // Remove the card class, keep another class so fetchClasses never pulls.
      final db = await database.database;
      await db.delete('class_cache', where: 'uuid = ?', whereArgs: [SystemClassUuids.card]);
      await cache.upsertClass(uuid: 'other-class', name: 'Other');

      await hub.load();

      final envelopes = await outboxEnvelopes();
      expect(envelopes.where((e) => e['opType'] == 'propertySchema.create'), hasLength(6));
      expect(envelopes.where((e) => e['opType'] == 'class.property.set'), isEmpty);
    });

    test('local workspaces skip the self-heal (the seed authors the family)',
        () async {
      final localHub = CardsHubProvider(
        repository: repo,
        syncService: service,
        isLocalWorkspace: true,
      );
      await localHub.load();

      expect(
        (await outboxEnvelopes()).where((e) => e['opType'] == 'propertySchema.create'),
        isEmpty,
      );
    });
  });
}
