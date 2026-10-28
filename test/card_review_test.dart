import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/core/utils/date_uuid.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/data/repositories/node_repository.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/models/relay/store_errors.dart';
import 'package:notees/domain/services/card_schedule.dart';
import 'package:notees/domain/services/srs.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The grade write path (web `client.ts reviewCard` parity): idx-addressed
/// `property.set` envelopes for the ACTIVE algorithm's fields only (the
/// inactive one's stay byte-for-byte stale), the `card.review` history
/// envelope appended after, the full year→month→day chain ensured before
/// the due write (owner ruling 2 — the `getOrCreateDailyJournal` seam is
/// day-only), and the fail-loud missing-card arm.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const workspaceId = '10000000-0000-4000-8000-000000000001';
  const cardId = '30000000-0000-4000-8000-00000000000a';
  const sessionId = '50000000-0000-4000-8000-000000000001';
  const today = '2026-10-28';
  const tomorrow = '2026-10-29';

  late AppDatabase database;
  late NodeCacheRepository cache;
  late SyncV2Service service;
  late NodeRepository repo;

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

    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response(
            requestOptions: options,
            data: const {'savedCount': 1, 'savedIds': ['id']},
          ),
        ),
      ),
    );
    service = SyncV2Service(
      database: database,
      dio: dio,
      clientId: '40000000-0000-4000-8000-000000000001',
    );
    await service.setWorkspaceId(workspaceId);
    repo = NodeRepository(dio: dio, syncService: service);

    // The six card-family schemas + bindings (a converged workspace).
    const family = [
      (SystemPropertyUuids.cardDue, 'Card due', 'datetime'),
      (SystemPropertyUuids.cardReps, 'Card reps', 'number'),
      (SystemPropertyUuids.cardInterval, 'Card interval', 'number'),
      (SystemPropertyUuids.cardEase, 'Card ease', 'number'),
      (SystemPropertyUuids.cardDifficulty, 'Card difficulty', 'number'),
      (SystemPropertyUuids.cardStability, 'Card stability', 'number'),
    ];
    for (final spec in family) {
      await service.emitLocal(
        opType: 'propertySchema.create',
        payload: OperationPayloads.propertySchemaCreate(
          propertySchemaId: spec.$1,
          name: spec.$2,
          type: spec.$3,
        ),
        affectedNodeIds: [spec.$1],
      );
      await service.emitLocal(
        opType: 'class.property.set',
        payload: OperationPayloads.classPropertySet(
          classId: SystemClassUuids.card,
          propertySchemaId: spec.$1,
        ),
        affectedNodeIds: [SystemClassUuids.card],
      );
    }
    await service.emitLocal(
      opType: 'object.create',
      payload: OperationPayloads.objectCreate(
        objectId: cardId,
        isEmbedded: false,
        classIds: const [SystemClassUuids.card],
        contentAst: AstBuilder.parseInline('Card A'),
      ),
      affectedNodeIds: [cardId],
    );
  });

  tearDown(() async {
    await database.close();
    AppDatabase.reset();
  });

  Future<List<Map<String, dynamic>>> envelopes({String? opType}) async {
    final db = await database.database;
    final rows = await db.query('relay_outbox', orderBy: 'id');
    final all = rows
        .map((row) => Map<String, dynamic>.from(jsonDecode(row['envelope_json'] as String) as Map))
        .toList();
    if (opType == null) return all;
    return all.where((e) => e['opType'] == opType).toList();
  }

  Future<CardSrsState> effectiveState(String uuid) async =>
      srsStateOf(await repo.fetchEffectiveProperties(uuid));

  group('reviewCard', () {
    test('sm2: idx-addressed property.set envelopes + the strict card.review '
        'payload; the fsrs fields stay byte-for-byte stale', () async {
      // Prior history under both algorithms (the mid-deck switch state).
      const stateBefore = CardSrsState(
        due: today,
        reps: 5,
        interval: 21,
        ease: 1.35,
        difficulty: 5,
        stability: 7,
      );
      await service.setPropertyValue(
          objectId: cardId, propertySchemaId: SystemPropertyUuids.cardReps, value: 5);
      await service.setPropertyValue(
          objectId: cardId, propertySchemaId: SystemPropertyUuids.cardInterval, value: 21);
      await service.setPropertyValue(
          objectId: cardId, propertySchemaId: SystemPropertyUuids.cardEase, value: 1.35);
      await service.setPropertyValue(
          objectId: cardId, propertySchemaId: SystemPropertyUuids.cardDifficulty, value: 5);
      await service.setPropertyValue(
          objectId: cardId, propertySchemaId: SystemPropertyUuids.cardStability, value: 7);
      // The day node the stale due points at must exist for the seed writes.
      final todayDay = dateToDayUuid(DateTime.parse(today));
      await service.emitLocal(
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: todayDay,
          isEmbedded: false,
          classIds: const [SystemClassUuids.day],
          name: '20261028',
        ),
        affectedNodeIds: [todayDay],
      );
      await service.setPropertyValue(
        objectId: cardId,
        propertySchemaId: SystemPropertyUuids.cardDue,
        value: {'nodeId': todayDay},
      );

      final stateAfter = nextCardState(stateBefore, CardGrade.good, SrsAlgorithm.sm2, today);
      final outboxBefore = (await envelopes()).length;
      await repo.reviewCard(
        cardId: cardId,
        stateAfter: stateAfter,
        algorithm: SrsAlgorithm.sm2,
        sessionId: sessionId,
        grade: CardGrade.good,
        stateBefore: stateBefore,
        reviewedAt: DateTime.utc(2026, 10, 28, 12),
      );
      final emitted = (await envelopes()).sublist(outboxBefore);

      // The gesture's envelope order: chain create ×3 (fresh workspace),
      // property.set ×4 (sm2: due/reps/interval/ease), card.review.
      expect(emitted.map((e) => e['opType']).toList(), [
        'object.create',
        'object.create',
        'object.create',
        'property.set',
        'property.set',
        'property.set',
        'property.set',
        'card.review',
      ]);

      final sets = emitted.where((e) => e['opType'] == 'property.set').toList();
      final bySchema = {for (final e in sets) (e['payload'] as Map)['propertySchemaId'] as String: e['payload'] as Map};
      expect(bySchema.keys, {
        SystemPropertyUuids.cardDue,
        SystemPropertyUuids.cardReps,
        SystemPropertyUuids.cardInterval,
        SystemPropertyUuids.cardEase,
      });
      // The due write addresses the ensured day node at the row's idx.
      expect(bySchema[SystemPropertyUuids.cardDue]!['value'],
          {'nodeId': dateToDayUuid(DateTime.parse(stateAfter.due!))});
      expect(bySchema[SystemPropertyUuids.cardDue]!['idx'], 0);
      expect(bySchema[SystemPropertyUuids.cardReps]!['value'], stateAfter.reps);
      expect(bySchema[SystemPropertyUuids.cardInterval]!['value'], stateAfter.interval);
      expect(bySchema[SystemPropertyUuids.cardEase]!['value'], stateAfter.ease);

      // The strict card.review payload, appended after the property writes.
      final review = emitted.last;
      expect(review['opType'], 'card.review');
      final payload = Map<String, dynamic>.from(review['payload'] as Map);
      expect(payload['cardId'], cardId);
      expect(payload['grade'], 'good');
      expect(payload['algorithm'], 'sm2');
      expect(payload['sessionId'], sessionId);
      expect(payload['reviewedAt'], '2026-10-28T12:00:00.000Z');
      expect(payload['stateBefore'], stateBefore.toJson());
      expect(payload['stateAfter'], stateAfter.toJson());

      // The values land in the cache; the fsrs fields stay stale.
      final state = await effectiveState(cardId);
      expect(state.due, stateAfter.due);
      expect(state.reps, stateAfter.reps);
      expect(state.interval, stateAfter.interval);
      expect(state.ease, stateAfter.ease);
      expect(state.difficulty, 5); // untouched
      expect(state.stability, 7); // untouched

      // The history row is in the derived card_review table.
      final reviews = await cache.listCardReviews(cardId);
      expect(reviews, hasLength(1));
      expect(reviews.single.grade, 'good');
      expect(reviews.single.sessionId, sessionId);
    });

    test('fsrs: difficulty + stability only; the sm2 ease stays stale', () async {
      const stateBefore = CardSrsState(
        due: today,
        reps: 2,
        interval: 6,
        ease: 2.36,
        difficulty: 5,
        stability: 3.173,
      );
      final stateAfter = nextCardState(stateBefore, CardGrade.hard, SrsAlgorithm.fsrs, today);
      final outboxBefore = (await envelopes()).length;
      await repo.reviewCard(
        cardId: cardId,
        stateAfter: stateAfter,
        algorithm: SrsAlgorithm.fsrs,
        sessionId: sessionId,
        grade: CardGrade.hard,
        stateBefore: stateBefore,
        reviewedAt: DateTime.utc(2026, 10, 28, 12, 30),
      );
      final emitted = (await envelopes()).sublist(outboxBefore);
      final sets = emitted.where((e) => e['opType'] == 'property.set').toList();
      final schemas = sets.map((e) => (e['payload'] as Map)['propertySchemaId'] as String).toSet();
      expect(schemas, {
        SystemPropertyUuids.cardDue,
        SystemPropertyUuids.cardReps,
        SystemPropertyUuids.cardInterval,
        SystemPropertyUuids.cardDifficulty,
        SystemPropertyUuids.cardStability,
      });
      expect(schemas.contains(SystemPropertyUuids.cardEase), isFalse);

      final state = await effectiveState(cardId);
      expect(state.ease, isNull); // never written — stays unseen-stale
      expect(state.difficulty, stateAfter.difficulty);
      expect(state.stability, stateAfter.stability);
    });

    test('fails loud on a missing card before any write lands', () async {
      const state = CardSrsState(due: tomorrow, reps: 1, interval: 1, ease: 2.5);
      await expectLater(
        repo.reviewCard(
          cardId: '30000000-0000-4000-8000-00000000ffff',
          stateAfter: state,
          algorithm: SrsAlgorithm.sm2,
          sessionId: sessionId,
          grade: CardGrade.good,
          stateBefore: unseenCardState,
          reviewedAt: DateTime.utc(2026, 10, 28, 12),
        ),
        throwsA(isA<NodeNotFoundError>()),
      );
      // Nothing from the gesture reaches the outbox: the seed envelopes are
      // the only rows.
      final all = await envelopes();
      expect(all.where((e) => e['opType'] == 'card.review'), isEmpty);
      expect(all.where((e) => e['opType'] == 'property.set'), isEmpty);
    });
  });

  group('ensureDateChain (owner ruling 2)', () {
    test('a fresh workspace gets year → month → day at their deterministic '
        'chain parents, compact date labels, before the due write', () async {
      await repo.reviewCard(
        cardId: cardId,
        stateAfter: const CardSrsState(due: tomorrow, reps: 1, interval: 1, ease: 2.5),
        algorithm: SrsAlgorithm.sm2,
        sessionId: sessionId,
        grade: CardGrade.good,
        stateBefore: unseenCardState,
        reviewedAt: DateTime.utc(2026, 10, 28, 12),
      );

      final date = DateTime.parse(tomorrow);
      final year = dateToYearUuid(date);
      final month = dateToMonthUuid(date);
      final day = dateToDayUuid(date);

      final creates = (await envelopes(opType: 'object.create'))
          .where((e) => [year, month, day].contains((e['payload'] as Map)['objectId']))
          .toList();
      expect(creates, hasLength(3));
      final byId = {for (final e in creates) (e['payload'] as Map)['objectId'] as String: e['payload'] as Map};
      // Year at the workspace root; month under the year; day under the month.
      expect(byId[year]!.containsKey('parentId'), isFalse);
      expect(byId[month]!['parentId'], year);
      expect(byId[day]!['parentId'], month);
      // The compact date labels (the web dateNodeLabel).
      expect(byId[year]!['contentAst'], [
        {'type': 'text', 'text': '20260000'},
      ]);
      expect(byId[month]!['contentAst'], [
        {'type': 'text', 'text': '20261000'},
      ]);
      expect(byId[day]!['contentAst'], [
        {'type': 'text', 'text': '20261029'},
      ]);

      // The chain is real in the cache: parentUuid links + class locks.
      final yearNode = await cache.getByUuid(year);
      final monthNode = await cache.getByUuid(month);
      final dayNode = await cache.getByUuid(day);
      expect(yearNode!.parentUuid, isNull);
      expect(monthNode!.parentUuid, year);
      expect(dayNode!.parentUuid, month);
      expect(yearNode.classesUuid, [SystemClassUuids.year]);
      expect(monthNode.classesUuid, [SystemClassUuids.month]);
      expect(dayNode.classesUuid, [SystemClassUuids.day]);
    });

    test('an existing chain is reused — no new create envelopes', () async {
      await repo.ensureDateChain(DateTime.parse(tomorrow));
      final before = (await envelopes(opType: 'object.create'))
          .where((e) => parseDateNodeId((e['payload'] as Map)['objectId'] as String) != null)
          .length;

      // A due write for a DIFFERENT day of the same month re-uses year+month.
      await repo.reviewCard(
        cardId: cardId,
        stateAfter: const CardSrsState(due: '2026-10-31', reps: 1, interval: 1, ease: 2.5),
        algorithm: SrsAlgorithm.sm2,
        sessionId: sessionId,
        grade: CardGrade.good,
        stateBefore: unseenCardState,
        reviewedAt: DateTime.utc(2026, 10, 28, 12),
      );
      final after = (await envelopes(opType: 'object.create'))
          .where((e) => parseDateNodeId((e['payload'] as Map)['objectId'] as String) != null)
          .length;
      expect(after - before, 1); // only the 2026-10-31 day node
    });

    test('the getOrCreateDailyJournal seam is day-only (the ruling-2 '
        'verification): it creates the day node, never the month/year', () async {
      await repo.getOrCreateDailyJournal(DateTime.parse(tomorrow));

      final date = DateTime.parse(tomorrow);
      expect(await cache.getByUuid(dateToDayUuid(date)), isNotNull);
      expect(await cache.getByUuid(dateToMonthUuid(date)), isNull);
      expect(await cache.getByUuid(dateToYearUuid(date)), isNull);
    });
  });
}
