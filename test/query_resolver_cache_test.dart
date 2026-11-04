import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/services/query_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The slice-2 follow-up: `QueryService.parseQueryLanguage` no longer
/// rebuilds the three resolver name maps (class / property-schema / node
/// display names) on every debounced keystroke. The maps rebuild ONLY when
/// the store-change bus fires (the slice-3 `StoreChangeBus` — every
/// mutation funnel in SyncV2Service notifies) — the maps are derived
/// state, invalidated like any other projection, with no staleness window.
/// Behavior parity is pinned: case-insensitive EXACT matches and the
/// uuid-order first-wins policy ride the cached maps unchanged.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const ws = '0192a000-0000-7000-8000-000000000001';
  const classPaper = '0192a000-0000-7000-8000-000000000201';
  const schemaYear = '0192a000-0000-7000-8000-000000000301';
  const nodeAlphaLater = '0192a000-0000-7000-8000-0000000000a2';
  const nodeAlphaFirst = '0192a000-0000-7000-8000-0000000000a1';
  const nodeQuantum = '0192a000-0000-7000-8000-0000000000b1';

  late AppDatabase database;
  late NodeCacheRepository cache;
  late StreamController<void> changes;
  late QueryService service;

  Future<dynamic> db() async => database.database;

  Map<String, dynamic> memberIn(String family, List<String> ids) => {
        'type': 'member',
        'family': family,
        'op': 'in',
        'target': {'mode': 'ids', 'ids': ids},
      };

  Future<void> insertClass(String uuid, String name) async =>
      (await db()).insert('class_cache', {'uuid': uuid, 'name': name});

  Future<void> insertSchema(String uuid, String name) async =>
      (await db()).insert('property_schema',
          {'uuid': uuid, 'workspace_id': ws, 'name': name});

  Future<void> insertNode(String uuid, String title) async =>
      (await db()).insert('node_cache', {
        'uuid': uuid,
        'name': jsonEncode([
          {'type': 'text', 'text': title}
        ]),
        'payload': '{}',
        'synced_at': 0,
      });

  setUp(() async {
    final ffiDb = await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    database = AppDatabase.fromDatabase(ffiDb);
    await database.initializeSchema();
    cache = NodeCacheRepository(database);
    // sync: true — invalidation lands before the next statement, so the
    // pins exercise the cache deterministically (the production bus's
    // async delivery would only widen the same window).
    changes = StreamController<void>.broadcast(sync: true);
    service = QueryService(
      database: database,
      cache: cache,
      storeChanges: changes.stream,
    );
  });

  tearDown(() async {
    service.dispose();
    await changes.close();
    await database.close();
    AppDatabase.reset();
  });

  test('two parses without an intervening store change reuse the maps '
      '(one rebuild)', () async {
    await insertClass(classPaper, 'Paper');

    final first = await service.parseQueryLanguage('class:paper');
    final second = await service.parseQueryLanguage('class:paper');

    expect(service.resolverMapBuildCount, 1);
    expect(first.root.toJson(), second.root.toJson());
    expect(
      first.root.children.single.toJson(),
      memberIn('class', [classPaper]),
    );
  });

  test('a store-change notification invalidates the maps — a class added '
      'after the first parse resolves on the next', () async {
    await insertSchema(schemaYear, 'Year');

    // The class is not in the store yet: the parse fails loud.
    await expectLater(
      service.parseQueryLanguage('class:paper'),
      throwsA(isA<Exception>()),
    );
    await insertClass(classPaper, 'Paper');
    changes.add(null);

    final ast = await service.parseQueryLanguage('class:paper');
    expect(service.resolverMapBuildCount, 2);
    expect(
      ast.root.children.single.toJson(),
      memberIn('class', [classPaper]),
    );
  });

  test('a rename funnels through the bus: the old display name stops '
      'resolving, the new one resolves', () async {
    await insertNode(nodeQuantum, 'Quantum');

    final before = await service.parseQueryLanguage('linked:QUANTUM');
    expect(
      before.root.children.single.toJson(),
      memberIn('links', [nodeQuantum]),
    );

    await (await db()).update(
      'node_cache',
      {
        'name': jsonEncode([
          {'type': 'text', 'text': 'Renamed'}
        ]),
      },
      where: 'uuid = ?',
      whereArgs: [nodeQuantum],
    );
    changes.add(null);

    final after = await service.parseQueryLanguage('linked:renamed');
    expect(
      after.root.children.single.toJson(),
      memberIn('links', [nodeQuantum]),
    );
    await expectLater(
      service.parseQueryLanguage('linked:quantum'),
      throwsA(isA<Exception>()),
    );
  });

  test('matching semantics ride the cached maps unchanged: uuid-order '
      'first-wins, case-insensitive EXACT match', () async {
    // Same lowercased display name, different uuids: uuid ORDER decides
    // the winner (the slice-2 policy), independent of insertion order.
    await insertNode(nodeAlphaLater, 'Alpha');
    await insertNode(nodeAlphaFirst, 'ALPHA');

    final lower = await service.parseQueryLanguage('linked:alpha');
    final upper = await service.parseQueryLanguage('linked:ALPHA');
    expect(
      lower.root.children.single.toJson(),
      memberIn('links', [nodeAlphaFirst]),
    );
    expect(
      upper.root.children.single.toJson(),
      memberIn('links', [nodeAlphaFirst]),
    );
    // EXACT match only — a prefix does not resolve.
    await expectLater(
      service.parseQueryLanguage('linked:alph'),
      throwsA(isA<Exception>()),
    );
  });
}
