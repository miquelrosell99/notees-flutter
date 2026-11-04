import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/domain/query/query_ast.dart';
import 'package:notees/domain/query/query_placeholders.dart';
import 'package:notees/domain/query/query_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The golden parity suite: the vendored query-golden corpus (byte-pinned,
/// sha256 below) replayed through the Dart compiler + runner over the local
/// derived schema — the same cases the TS reference runner
/// (`packages/query/gen-golden.mjs`, better-sqlite3 + the TS store schema)
/// generated the expectations with. One source of truth, two runners.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const goldenPath = 'test/fixtures/query/query-golden.json';
  const goldenSha256 =
      'be45ab94f65e0ad80900fd83fa2156cc4d7a021194e2202e2c063eaae3e214f4';

  late AppDatabase database;
  late QueryRunner runner;

  // The corpus loads at registration time (the cases are built from it).
  final Map<String, dynamic> golden = jsonDecode(
    File(goldenPath).readAsStringSync(),
  ) as Map<String, dynamic>;

  Future<void> seed() async {
    final db = await database.database;
    final seedData = golden['seed'] as Map<String, dynamic>;

    // The node rows: TS-schema semantic fields mapped to the local renames
    // (F1/F2): id → uuid, title → the content JSON in `name`, is_active →
    // is_deleted/is_archived (an inactive TS row is the local archived
    // shape).
    for (final node in (seedData['nodes'] as List<dynamic>).cast<Map>()) {
      await db.insert('node_cache', {
        'uuid': node['id'],
        'parent_uuid': node['parent_id'],
        'name': jsonEncode([
          {'type': 'text', 'text': node['title']}
        ]),
        'created_at': node['created_at'],
        'updated_at': node['updated_at'],
        'write_date': node['updated_at'],
        'payload': '{}',
        'synced_at': 0,
        'is_class': node['is_class'],
        'is_embedded': node['is_embedded'],
        'is_deleted': 0,
        'is_archived': node['is_active'] == 1 ? 0 : 1,
        'classes_uuid': jsonEncode(node['class_ids']),
        'tag_ids': jsonEncode(node['tag_ids']),
        if (node['cover_asset_id'] != null)
          'cover_asset_id': node['cover_asset_id'],
        if (node['banner_asset_id'] != null)
          'banner_asset_id': node['banner_asset_id'],
        if (node['aliased_node_id'] != null)
          'aliased_node_id': node['aliased_node_id'],
      });
      // The plaintext FTS backend (the same text the TS runner inserts into
      // its search_index FTS table).
      final docid = await db.insert('search_index_fts', {
        'content': node['search_text'],
      });
      await db.insert('search_index_fts_docid', {
        'node_id': node['id'],
        'docid': docid,
      });
    }
    for (final edge in (seedData['edges'] as List<dynamic>).cast<Map>()) {
      await db.insert('edge', {
        'id': 'e-${edge['source_id']}-${edge['target_id']}',
        'source_id': edge['source_id'],
        'target_id': edge['target_id'],
        'type': 'mention',
      });
    }
    for (final row
        in (seedData['class_hierarchy'] as List<dynamic>).cast<Map>()) {
      await db.insert('class_hierarchy', {
        'class_id': row['class_id'],
        'ancestor_id': row['ancestor_id'],
      });
    }
    for (final row
        in (seedData['class_member_set'] as List<dynamic>).cast<Map>()) {
      await db.insert('class_member_set', {
        'node_uuid': row['node_id'],
        'class_id': row['class_id'],
        'present': row['present'],
        'hlc_physical': row['hlc_physical'],
        'hlc_logical': row['hlc_logical'],
      });
    }
    for (final row
        in (seedData['class_property'] as List<dynamic>).cast<Map>()) {
      await db.insert('class_property', {
        'class_id': row['class_id'],
        'property_schema_id': row['property_schema_id'],
        'active': row['active'],
        'pinned': row['pinned'],
        'hlc_physical': row['hlc_physical'],
        'hlc_logical': row['hlc_logical'],
      });
    }
    for (final row
        in (seedData['property_schema'] as List<dynamic>).cast<Map>()) {
      await db.insert('property_schema', {
        'uuid': row['id'],
        'workspace_id': '',
        'name': row['id'],
        'type': row['type'],
        'default_value': row['default_value'],
        'options': row['options'],
      });
    }
    for (final row
        in (seedData['property_value'] as List<dynamic>).cast<Map>()) {
      await db.insert('property_value', {
        'id': row['id'],
        'node_uuid': row['node_id'],
        'property_schema_id': row['property_schema_id'],
        'value': row['value'],
        'idx': row['idx'],
        'hlc_physical': row['hlc_physical'],
        'hlc_logical': row['hlc_logical'],
      });
    }
    for (final row in (seedData['property_value_tombstone']
            as List<dynamic>)
        .cast<Map>()) {
      await db.insert('property_value_tombstone', {
        'node_uuid': row['node_id'],
        'property_schema_id': row['property_schema_id'],
        'idx': row['idx'],
        'hlc_physical': row['hlc_physical'],
        'hlc_logical': row['hlc_logical'],
      });
    }
    // The class registry rows (the demote join's local home — all NULL
    // parentless_role flags in this corpus).
    for (final node in (seedData['nodes'] as List<dynamic>).cast<Map>()) {
      if (node['is_class'] == 1) {
        await db.insert('class_cache', {
          'uuid': node['id'],
          'name': node['title'],
          'active': 1,
        });
      }
    }
  }

  setUp(() async {
    final bytes = await File(goldenPath).readAsBytes();
    final digest = await Sha256().hash(bytes);
    final hex = digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(hex, goldenSha256,
        reason: 'the golden corpus is byte-pinned (the fixture law)');

    final ffiDb = await databaseFactoryFfi.openDatabase(
      ':memory:',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    database = AppDatabase.fromDatabase(ffiDb);
    await database.initializeSchema();
    final ftsMeta = await (await database.database).rawQuery(
      "SELECT sql FROM sqlite_master WHERE name = 'search_index_fts'",
    );
    expect(ftsMeta.first['sql'], contains('fts5'),
        reason: 'the ffi harness builds must carry FTS5');
    await seed();
    runner = QueryRunner(await database.database);
  });

  tearDown(() async {
    await database.close();
    AppDatabase.reset();
  });

  CompileOptions optionsFor(Map<String, dynamic> testCase) {
    final raw = testCase['options'] as Map<String, dynamic>?;
    if (raw == null) return const CompileOptions();
    return CompileOptions(
      now: raw['now'] == null ? null : DateTime.parse(raw['now'] as String),
      selfNodeId: raw['selfNodeId'] as String?,
    );
  }

  void expectRowsEqual(List<List<Object?>> actual, List<dynamic> expected) {
    expect(actual, hasLength(expected.length), reason: 'aggregate row count');
    for (var i = 0; i < expected.length; i++) {
      final expectedRow = (expected[i] as List).cast<dynamic>();
      expect(actual[i], hasLength(expectedRow.length));
      for (var j = 0; j < expectedRow.length; j++) {
        final want = expectedRow[j];
        final got = actual[i][j];
        if (want is num && got is num) {
          expect(got - want, lessThan(1e-9),
              reason: 'aggregate cell [$i][$j]');
        } else {
          expect(got, want, reason: 'aggregate cell [$i][$j]');
        }
      }
    }
  }

  for (final rawCase in (golden['cases'] as List<dynamic>)) {
    final testCase = Map<String, dynamic>.from(rawCase as Map);
    final name = testCase['name'] as String;
    test(name, () async {
      final ast = QueryAst.parse(testCase['ast']);
      final options = optionsFor(testCase);

      if (testCase['aggregate'] == true) {
        final result = await runner.runAggregate(ast, options);
        expect(
          result.columns,
          (testCase['expectedColumns'] as List).cast<dynamic>(),
        );
        expectRowsEqual(result.rows, testCase['expectedRows'] as List);
        return;
      }

      if (testCase['matches'] != null) {
        final pins =
            (testCase['matches'] as Map).cast<String, dynamic>();
        for (final entry in pins.entries) {
          expect(
            await runner.matches(entry.key, ast, options),
            entry.value,
            reason: 'matches(${entry.key})',
          );
        }
        expect(await runner.count(ast, options), testCase['expectedCount']);
        return;
      }

      final result = await runner.run(ast, options);
      final ids = result.ids;
      expect(await runner.count(ast, options), testCase['expectedCount'],
          reason: 'count over the compiled select');
      final expected = (testCase['expectedIds'] as List).cast<String>();
      if (testCase['orderedIds'] == true) {
        expect(ids, expected, reason: 'the ordered id vector');
      } else {
        expect([...ids]..sort(), expected, reason: 'the sorted id set');
      }
    });
  }
}
