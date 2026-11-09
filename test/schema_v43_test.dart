import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The schema-v43 pins: `class_property.show_in_node_rows` (the binding
/// row's binary node-row preview flag — the TS store schema v36→v37
/// lockstep). The fresh create carries the column (NOT NULL DEFAULT 0) and
/// the applier COALESCE-patches it: absent = keep the stored flag, a new
/// row defaults to no preview.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const ws = '0192a000-0000-7000-8000-000000000001';
  const actor = '0192a000-0000-7000-8000-000000000002';
  const cls = '0192a000-0000-7000-8000-00000000e101';
  const schema = '0192a000-0000-7000-8000-00000000e102';

  late AppDatabase database;
  late NodeCacheRepository cache;
  late RelayAppliers appliers;

  OperationEnvelope binding(
    int physical,
    Map<String, dynamic> payload,
  ) =>
      OperationEnvelope(
        id: '0192a000-0000-7000-8000-00000000d$physical',
        workspaceId: ws,
        actorId: actor,
        deviceId: 'v43-test-device',
        hlc: Hlc(physical: physical, logical: 0),
        affectedNodeIds: const [cls],
        opType: 'class.property.set',
        payload: {
          'classId': cls,
          'propertySchemaId': schema,
          ...payload,
        },
        timestamp: '2026-11-09T09:00:00.000Z',
      );

  Future<int?> flag() async {
    final db = await database.database;
    final rows = await db.rawQuery(
      'SELECT show_in_node_rows FROM class_property WHERE class_id = ? '
      'AND property_schema_id = ?',
      [cls, schema],
    );
    return rows.isEmpty
        ? null
        : (rows.single['show_in_node_rows'] as num?)?.toInt();
  }

  setUp(() async {
    final ffiDb = await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    database = AppDatabase.fromDatabase(ffiDb);
    await database.initializeSchema();
    cache = NodeCacheRepository(database);
    appliers = RelayAppliers(cache);
    await appliers.apply(OperationEnvelope(
      id: '0192a000-0000-7000-8000-00000000d0',
      workspaceId: ws,
      actorId: actor,
      deviceId: 'v43-test-device',
      hlc: const Hlc(physical: 0, logical: 0),
      affectedNodeIds: const [cls],
      opType: 'class.create',
      payload: {
        'classId': cls,
        'contentAst': [
          {'type': 'text', 'text': 'Occasion'},
        ],
      },
      timestamp: '2026-11-09T09:00:00.000Z',
    ));
  });

  tearDown(() async {
    await database.close();
    AppDatabase.reset();
  });

  test('the fresh schema carries show_in_node_rows NOT NULL DEFAULT 0', () async {
    final db = await database.database;
    final columns = await db.rawQuery('PRAGMA table_info(class_property)');
    final column = columns.singleWhere((c) => c['name'] == 'show_in_node_rows');
    expect(column['notnull'], 1);
    expect(column['dflt_value'], '0');
  });

  test('absent = false: a bare binding stores the default; the applier '
      'COALESCE-patches partial writes', () async {
    // A bare binding (no flags at all) stores the default: no preview.
    expect(await appliers.apply(binding(100, const {})), isTrue);
    expect(await flag(), 0);

    // A flagged write flips the preview on.
    expect(
      await appliers.apply(binding(200, {'showInNodeRows': true})),
      isTrue,
    );
    expect(await flag(), 1);

    // An active-only patch keeps the stored flag (the COALESCE patch — the
    // pinned/active identical semantics).
    expect(await appliers.apply(binding(300, {'active': false})), isTrue);
    expect(await flag(), 1);

    // A losing (stale-HLC) write changes nothing.
    expect(
      await appliers.apply(binding(150, {'showInNodeRows': false})),
      isFalse,
    );
    expect(await flag(), 1);

    // An explicit false flips the preview off.
    expect(
      await appliers.apply(binding(400, {'showInNodeRows': false})),
      isTrue,
    );
    expect(await flag(), 0);
  });
}
