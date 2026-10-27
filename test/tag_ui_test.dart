import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/data/repositories/node_repository.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:notees/features/editor/widgets/block_tree_editor.dart';
import 'package:notees/features/editor/widgets/tag_pills.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Widget/logic acceptance for the tag management surface (web TagsRow /
/// BlockRow parity): alphabetical pill ordering, effective-color
/// resolution, the block-row visibility rule, and the write path — assign
/// rides the offline outbox as a re-issued `object.create` tagIds carrier
/// and remove as `tag.unassign`, the exact queue class writes use.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  Node tag(String uuid, String name, {String? color, List<String>? classes}) =>
      Node(
        id: 1,
        uuid: uuid,
        name: name,
        displayName: name,
        color: color,
        classesUuid: classes ?? const [],
      );

  group('sortedTagNodes', () {
    test('orders alphabetically by display name, dropping unknown ids', () {
      final nodes = <String, Node>{
        't-b': tag('t-b', 'Beta'),
        't-a': tag('t-a', 'alfa'),
        't-c': tag('t-c', 'Gamma'),
      };
      final sorted = sortedTagNodes(['t-c', 'missing', 't-a', 't-b'], nodes);
      expect(sorted.map((n) => n.uuid).toList(), ['t-a', 't-b', 't-c']);
    });
  });

  group('effectiveTagColor', () {
    const fallback = Color(0xFF112233);

    test('prefers the tag’s own color over its classes’', () {
      final node = tag(
        't-a',
        'A',
        color: 'red',
        classes: ['cls-1'],
      );
      final colors = <String, Color>{'cls-1': const Color(0xFF444444)};
      expect(effectiveTagColor(node, colors, fallback), const Color(0xFFe34d45));
    });

    test('falls back to a class color, then the fallback', () {
      final node = tag('t-a', 'A', classes: ['cls-1', 'cls-2']);
      final colors = <String, Color>{'cls-2': const Color(0xFF444444)};
      expect(effectiveTagColor(node, colors, fallback), const Color(0xFF444444));
      expect(
        effectiveTagColor(node, const {}, fallback),
        fallback,
      );
    });
  });

  group('shouldShowTagRow (block visibility rule)', () {
    test('renders only when the block carries at least one tag', () {
      expect(shouldShowTagRow(const ['t-a']), isTrue);
      expect(shouldShowTagRow(const []), isFalse);
    });
  });

  group('TagPills widget', () {
    testWidgets('renders pills alphabetically; × fires onRemove; add chip '
        'fires onAdd', (tester) async {
      final removed = <String>[];
      var added = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TagPills(
            tagIds: const ['t-b', 't-a'],
            nodesByUuid: {
              't-b': tag('t-b', 'Beta'),
              't-a': tag('t-a', 'Alfa'),
            },
            colorsByUuid: const {},
            fallbackColor: const Color(0xFF2E5E46),
            onRemove: (t) => removed.add(t.uuid),
            onAdd: () => added++,
          ),
        ),
      ));

      // Alphabetical order in the wrap.
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .toList();
      expect(texts.indexOf('Alfa'), lessThan(texts.indexOf('Beta')));

      await tester.tap(find.byWidgetPredicate(
        (w) => w is Icon && w.icon == MdiIcons.close,
      ).first);
      await tester.pump();
      expect(removed, ['t-a']);

      await tester.tap(find.byWidgetPredicate(
        (w) => w is Icon && w.icon == MdiIcons.tagPlus,
      ));
      await tester.pump();
      expect(added, 1);
    });
  });

  group('BlockTreeEditor tags row', () {
    BlockNode block({List<String> tags = const []}) => BlockNode(
          node: Node(
            id: 1,
            uuid: 'block-1',
            name: '[]',
            displayName: '',
            tagsUuid: tags,
          ),
          controller: TextEditingController(text: ''),
        );

    Widget host(BlockNode root, {void Function(BlockNode, String)? onRemove}) {
      return MaterialApp(
        home: Scaffold(
          body: BlockTreeEditor(
            roots: [root],
            classNames: const {},
            dio: Dio(),
            focusedNode: null,
            onFocus: (_) {},
            onDelete: (_) {},
            onMove: (_, _, _) {},
            onAddSibling: () {},
            onAddChild: (_) {},
            onIndent: (_) {},
            onOutdent: (_) {},
            onToggleCollapse: (_) {},
            tagNodes: {'t-a': tag('t-a', 'Alfa')},
            linkColors: const {'t-a': Color(0xFF2E5E46)},
            onOpenTag: (_) {},
            onRemoveTag: onRemove,
            onAddTag: (_) {},
          ),
        ),
      );
    }

    testWidgets('a tagged block renders its tags row; × fires '
        'onRemoveTag', (tester) async {
      final root = block(tags: const ['t-a']);
      final removed = <String>[];
      await tester.pumpWidget(host(root, onRemove: (_, tagUuid) {
        removed.add(tagUuid);
      }));

      expect(find.text('Alfa'), findsOneWidget);
      await tester.tap(find.byWidgetPredicate(
        (w) => w is Icon && w.icon == MdiIcons.close,
      ));
      await tester.pump();
      expect(removed, ['t-a']);
    });

    testWidgets('an untagged block renders no tags row', (tester) async {
      await tester.pumpWidget(host(block()));
      expect(find.text('Alfa'), findsNothing);
    });
  });

  group('tag write path (offline outbox, class-write mirror)', () {
    const workspaceId = '10000000-0000-4000-8000-000000000001';
    const pageId = '20000000-0000-4000-8000-000000000001';
    const tagId = '30000000-0000-4000-8000-000000000001';

    late AppDatabase database;
    late List<Map<String, dynamic>> pushed;

    Dio buildDio() {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/relay/v2/batch') {
              final body = options.data as Map<String, dynamic>;
              final envelopes =
                  (body['envelopes'] as List<dynamic>).cast<Map<String, dynamic>>();
              pushed.addAll(envelopes);
              handler.resolve(Response(
                requestOptions: options,
                data: {
                  'savedCount': envelopes.length,
                  'savedIds': envelopes.map((e) => e['id']).toList(),
                },
                statusCode: 200,
              ));
              return;
            }
            if (options.path == '/relay/v2/snapshot') {
              handler.resolve(Response(
                requestOptions: options,
                data: const {
                  'snapshotId': null,
                  'hlc': {'physical': 0, 'logical': 0},
                  'hasSnapshot': false,
                  'restoreEpoch': 0,
                  'upToSeq': null,
                },
                statusCode: 200,
              ));
              return;
            }
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'unexpected call to ${options.path}',
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
      // Keep pull() from force-resetting the workspace due to empty class
      // and property-schema caches.
      final cache = NodeCacheRepository(database);
      await cache.upsertClass(uuid: 'class-1', name: 'Class');
      await cache.upsertPropertySchema(
        PropertySchemaRow(uuid: 'schema-1', workspaceId: workspaceId, name: 'P'),
      );
      pushed = [];
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('assign rides the outbox as an object.create tagIds carrier and '
        'applies to the local cache', () async {
      final service = SyncV2Service(
        database: database,
        dio: buildDio(),
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await service.setWorkspaceId(workspaceId);

      await service.enqueue(
        type: 'create',
        nodeUuid: pageId,
        contentAst: AstBuilder.parseInline('Shopping'),
        isPage: true,
      );
      await service.flush();

      // The repository's class-write mirror: updateNode(tags:) diffs the
      // cached set and enqueues one add_tag per new tag.
      final repo = NodeRepository(
        dio: buildDio(),
        syncService: service,
      );
      await repo.updateNode(pageId, tags: const [tagId]);

      expect(pushed.last['opType'], 'object.create');
      expect(pushed.last['payload']['objectId'], pageId);
      expect(pushed.last['payload']['tagIds'], [tagId]);

      final node = await service.cache.getByUuid(pageId);
      expect(node!.tagsUuid, contains(tagId));
    });

    test('unassign rides the outbox as tag.unassign and applies to the '
        'local cache', () async {
      final service = SyncV2Service(
        database: database,
        dio: buildDio(),
        clientId: '40000000-0000-4000-8000-000000000001',
      );
      await service.setWorkspaceId(workspaceId);

      await service.enqueue(
        type: 'create',
        nodeUuid: pageId,
        contentAst: AstBuilder.parseInline('Shopping'),
        isPage: true,
      );
      await service.flush();

      await service.enqueue(
        type: 'add_tag',
        nodeUuid: pageId,
        tagUuid: tagId,
      );
      await service.flush();
      expect(
        (await service.cache.getByUuid(pageId))!.tagsUuid,
        contains(tagId),
      );

      await service.enqueue(
        type: 'remove_tag',
        nodeUuid: pageId,
        tagUuid: tagId,
      );
      await service.flush();

      expect(pushed.last['opType'], 'tag.unassign');
      expect(pushed.last['payload']['objectId'], pageId);
      expect(pushed.last['payload']['tagId'], tagId);

      final node = await service.cache.getByUuid(pageId);
      expect(node!.tagsUuid, isNot(contains(tagId)));
    });
  });
}
