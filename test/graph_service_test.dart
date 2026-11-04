import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/color_group_store.dart';
import 'package:notees/data/repositories/graph_repository.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/services/graph_service.dart';
import 'package:notees/domain/services/query_service.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The GraphService pins over the seeded ffi store: the load migration
/// (a stored legacy DSL-string row parses and paints), the group CRUD
/// round-trip through the device-local store, and the live-recolor ride
/// on the store-change bus (a rename funnels through a bus notification
/// and the assignment follows — the debounced rebuild contract).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const ws = '0192a000-0000-7000-8000-000000000001';
  const pageA = '0192a000-0000-7000-8000-000000000101';
  const pageB = '0192a000-0000-7000-8000-000000000102';

  late AppDatabase database;
  late NodeCacheRepository cache;
  late RelayAppliers appliers;
  late StreamController<void> changes;
  late QueryService queryService;
  late GraphService service;
  late SharedPreferences prefs;

  OperationEnvelope envelope({
    required String opType,
    required Map<String, dynamic> payload,
    required int physical,
  }) =>
      OperationEnvelope(
        id: '0192a000-0000-7000-8000-0000000003$physical',
        workspaceId: ws,
        actorId: '0192a000-0000-7000-8000-000000000002',
        deviceId: 'test-device',
        hlc: Hlc(physical: physical, logical: 0),
        affectedNodeIds: [payload['objectId'] ?? ''],
        opType: opType,
        payload: payload,
        timestamp: '2026-11-04T12:00:00.000Z',
      );

  Future<void> create(String objectId, String name, {int physical = 100}) =>
      appliers.apply(envelope(
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(objectId: objectId, name: name),
        physical: physical,
      ));

  /// The debounced rebuild window, padded — real timers, never faked.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 350));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final ffiDb = await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    database = AppDatabase.fromDatabase(ffiDb);
    await database.initializeSchema();
    cache = NodeCacheRepository(database);
    appliers = RelayAppliers(cache);
    changes = StreamController<void>.broadcast(sync: true);
    queryService = QueryService(
      database: database,
      cache: cache,
      storeChanges: changes.stream,
    );
    service = GraphService(
      graphRepository: GraphRepository(database, cache: cache),
      queryService: queryService,
      colorGroupStore: ColorGroupStore(prefs: prefs),
      storeChanges: changes.stream,
    );
    await create(pageA, 'Alpha');
    await create(pageB, 'Beta', physical: 110);
  });

  tearDown(() async {
    service.dispose();
    queryService.dispose();
    await changes.close();
    await database.close();
    AppDatabase.reset();
  });

  test('load migrates a stored legacy DSL row and paints the match',
      () async {
    await prefs.setString('graph_color_groups', jsonEncode(const [
      {'id': 'g1', 'label': 'Papers', 'color': 'sky', 'query': 'name: Alpha'},
    ]));
    await service.load();
    expect(service.groups, hasLength(1));
    expect(service.groups.single.error, isNull);
    expect(service.groups.single.ast, isNotNull);
    expect(service.colorFor(pageA), 'sky');
    expect(service.colorFor(pageB), isNull);
    expect(service.topology!.nodes, hasLength(2));
    expect(service.layout, hasLength(2));
    // The migrated shape re-persisted (no legacy `query` key on disk).
    final persisted = jsonDecode(prefs.getString('graph_color_groups')!)
        as List<dynamic>;
    expect(persisted.single, isNot(contains('query')));
  });

  test('load keeps a failing legacy row listed but painted nowhere',
      () async {
    await prefs.setString('graph_color_groups', jsonEncode(const [
      {'id': 'g1', 'label': 'Broken', 'color': 'red', 'query': 'linked: Ghost'},
    ]));
    await service.load();
    expect(service.groups.single.error, isNotNull);
    expect(service.colorFor(pageA), isNull);
    expect(service.colorFor(pageB), isNull);
  });

  test('saveGroup adds, edits in place, and persists', () async {
    await service.load();
    await service.saveGroup(label: 'First', color: 'red', dslText: 'name: Alpha');
    expect(service.groups, hasLength(1));
    expect(service.colorFor(pageA), 'red');

    final id = service.groups.single.id;
    await service.saveGroup(
        id: id, label: 'Renamed', color: 'green', dslText: 'name: Beta');
    expect(service.groups, hasLength(1)); // the slot is preserved
    expect(service.groups.single.label, 'Renamed');
    expect(service.colorFor(pageA), isNull);
    expect(service.colorFor(pageB), 'green');

    final persisted = jsonDecode(prefs.getString('graph_color_groups')!)
        as List<dynamic>;
    expect(persisted.single['label'], 'Renamed');
    expect(persisted.single['color'], 'green');
    expect(persisted.single['ast'], isA<Map>());
  });

  test('saveGroup fails loud on bad DSL and changes nothing', () async {
    await service.load();
    expect(
      () => service.saveGroup(label: 'X', color: 'red', dslText: 'class: Ghost'),
      throwsA(anything),
    );
    expect(service.groups, isEmpty);
    // load()'s persist of the empty list stands — nothing was added.
    expect(prefs.getString('graph_color_groups'), '[]');
  });

  test('removeGroup unpaints immediately', () async {
    await service.load();
    await service.saveGroup(label: 'First', color: 'red', dslText: 'name: Alpha');
    await service.removeGroup(service.groups.single.id);
    expect(service.groups, isEmpty);
    expect(service.colorFor(pageA), isNull);
    expect(prefs.getString('graph_color_groups'), '[]');
  });

  test('a store change re-evaluates the coloring through the bus', () async {
    await prefs.setString('graph_color_groups', jsonEncode(const [
      {'id': 'g1', 'label': 'A', 'color': 'sky', 'query': 'name: Alpha'},
    ]));
    await service.load();
    expect(service.colorFor(pageA), 'sky');

    // Rename Alpha → Alpheratz through the op path, then the sync
    // funnel's bus notification (SyncV2Service notifies after its batch
    // applies — the appliers themselves never touch the bus): the
    // service's debounced rebuild re-evaluates the group and the
    // assignment follows the name.
    await appliers.apply(envelope(
      opType: 'object.update',
      payload: OperationPayloads.objectUpdate(
        objectId: pageA,
        contentAst: const [
          {'type': 'text', 'text': 'Alpheratz'},
        ],
      ),
      physical: 200,
    ));
    changes.add(null);
    await settle();
    expect(service.colorFor(pageA), isNull);

    await appliers.apply(envelope(
      opType: 'object.update',
      payload: OperationPayloads.objectUpdate(
        objectId: pageA,
        contentAst: const [
          {'type': 'text', 'text': 'Alpha'},
        ],
      ),
      physical: 300,
    ));
    changes.add(null);
    await settle();
    expect(service.colorFor(pageA), 'sky');
  });

  test('a store change rebuilds the topology too', () async {
    await service.load();
    expect(service.topology!.nodes, hasLength(2));
    await create('0192a000-0000-7000-8000-000000000103', 'Gamma',
        physical: 210);
    changes.add(null);
    await settle();
    expect(service.topology!.nodes, hasLength(3));
    expect(service.layout, hasLength(3));
  });

  test('group colors are the stored values (tokens pass through)', () async {
    await service.load();
    await service.saveGroup(
        label: 'Hex', color: '#123456', dslText: 'name: Beta');
    expect(service.colorFor(pageB), '#123456');
    final group = service.groups.single;
    expect(group.toJson()['color'], '#123456');
  });
}
