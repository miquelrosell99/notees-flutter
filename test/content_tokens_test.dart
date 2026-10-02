import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/core/utils/ast_stringifier.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/content/content_token.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:notees/features/editor/widgets/ast_rich_text.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('content token model', () {
    test('text token round-trips with and without marks', () {
      const plain = TextToken(text: 'hello');
      expect(plain.toJson(), {'type': 'text', 'text': 'hello'});
      expect(ContentToken.fromJson(plain.toJson()), isA<TextToken>());

      const marked = TextToken(text: 'hi', marks: ['bold', 'code']);
      final json = marked.toJson();
      expect(json['marks'], ['bold', 'code']);
      final restored = ContentToken.fromJson(json) as TextToken;
      expect(restored.text, 'hi');
      expect(restored.marks, ['bold', 'code']);
    });

    test('unknown marks are dropped on parse (mark names are the v2 set)', () {
      final token = TextToken.fromJson({
        'type': 'text',
        'text': 'x',
        'marks': ['bold', 'blink', 'italic'],
      });
      expect(token.marks, ['bold', 'italic']);
    });

    test('typed_link round-trips the fixture shape (verb/locator/candidateSpans)',
        () {
      final fixture = {
        'type': 'typed_link',
        'verb': 'cites',
        'text': 'cites',
        'metadata': {
          'locator': 'p. 42',
          'candidateSpans': ['tok_3', 'tok_7'],
        },
      };
      final token = ContentToken.fromJson(fixture) as TypedLinkToken;
      expect(token.verb, isA<FreeVerb>());
      expect((token.verb as FreeVerb).verb, 'cites');
      expect(token.text, 'cites');
      expect(token.metadata!.locator, 'p. 42');
      expect(token.metadata!.candidateSpans, ['tok_3', 'tok_7']);
      expect(token.toJson(), fixture);
    });

    test('typed_link verb can bind a property schema', () {
      final token = ContentToken.fromJson({
        'type': 'typed_link',
        'verb': {
          'propertySchemaId': '0192a000-0000-7000-8000-0000000000a1',
        },
        'text': 'owns',
      }) as TypedLinkToken;
      expect(token.verb, isA<BoundVerb>());
      expect(
        (token.verb as BoundVerb).propertySchemaId,
        '0192a000-0000-7000-8000-0000000000a1',
      );
      expect(
        (token.toJson()['verb'] as Map<String, dynamic>)['propertySchemaId'],
        '0192a000-0000-7000-8000-0000000000a1',
      );
    });

    test('mention/class_chip round-trip displayText and linkId', () {
      final mention = ContentToken.fromJson({
        'type': 'mention',
        'targetNodeId': '0192a000-0000-7000-8000-000000000011',
        'text': 'The Structure of Scientific Revolutions',
        'linkId': '0192a000-0000-7000-8000-0000000000aa',
      }) as MentionToken;
      expect(mention.displayText, isNull);
      expect(mention.linkId, '0192a000-0000-7000-8000-0000000000aa');
      expect(mention.toJson()['linkId'], '0192a000-0000-7000-8000-0000000000aa');

      final chip = const ClassChipToken(
        classId: '00000000-0000-0000-0001-000000000025',
        displayText: 'Book',
      );
      expect(ContentToken.fromJson(chip.toJson()), isA<ClassChipToken>());
    });

    test('block-scale tokens round-trip (asset/embed/query/whiteboard)', () {
      for (final token in <ContentToken>[
        const AssetRefToken(assetId: '0192a000-0000-7000-8000-0000000000b1'),
        const EmbedRefToken(nodeId: '0192a000-0000-7000-8000-0000000000b2'),
        QueryToken(queryAst: {'op': 'and', 'args': []}, view: {'mode': 'list'}),
        const WhiteboardToken(layout: {'shapes': []}),
        const HardBreakToken(),
        const MathToken(expression: 'e = mc^2'),
        const ExternalLinkToken(href: 'https://x.example', text: 'x'),
      ]) {
        final restored = ContentToken.fromJson(token.toJson());
        expect(restored.runtimeType, token.runtimeType, reason: token.type);
        expect(restored.toJson(), token.toJson(), reason: token.type);
      }
    });

    test('quote is the only nested token and round-trips children', () {
      const quote = QuoteToken(children: [
        TextToken(text: 'quoted ', marks: ['italic']),
        HardBreakToken(),
        TextToken(text: 'text'),
      ]);
      final json = quote.toJson();
      expect(json['children'], hasLength(3));
      final restored = ContentToken.fromJson(json) as QuoteToken;
      expect(restored.children, hasLength(3));
      expect((restored.children[0] as TextToken).marks, ['italic']);
      expect(restored.children[1], isA<HardBreakToken>());
    });

    test('unknown token types degrade to UnsupportedToken', () {
      final raw = {'type': 'hologram', 'data': 1};
      final token = ContentToken.fromJson(raw);
      expect(token, isA<UnsupportedToken>());
      expect(token.toJson(), raw);
    });

    test('parseContentAst accepts serialized JSON and legacy plain text', () {
      final tokens = parseContentAst('[{"type":"text","text":"hi"}]');
      expect(tokens.single, isA<TextToken>());

      final plain = parseContentAst('just words');
      expect(plain.single, isA<TextToken>());
      expect((plain.single as TextToken).text, 'just words');
    });
  });

  group('plainTextExcerpt', () {
    test('contributes text/typed_link/mention/math, recurses quotes', () {
      final excerpt = plainTextExcerpt(parseContentAst([
        {'type': 'text', 'text': 'Kuhn '},
        {
          'type': 'typed_link',
          'verb': 'cites',
          'text': 'cites',
        },
        {
          'type': 'mention',
          'targetNodeId': '0192a000-0000-7000-8000-000000000011',
          'text': 'The Structure',
          'displayText': 'the book',
        },
        {'type': 'math', 'expression': 'e = mc^2'},
        {
          'type': 'quote',
          'children': [
            {'type': 'text', 'text': 'nested quote'},
          ],
        },
      ]));
      expect(excerpt, 'Kuhn cites the book e = mc^2 nested quote');
    });

    test('hard_break becomes a space and whitespace collapses', () {
      final excerpt = plainTextExcerpt(parseContentAst([
        {'type': 'text', 'text': 'line one'},
        {'type': 'hard_break'},
        {'type': 'text', 'text': 'line   two'},
      ]));
      expect(excerpt, 'line one line two');
    });
  });

  group('AstBuilder (flat grammar)', () {
    test('parses marks onto text runs', () {
      final tokens = AstBuilder.parseInline('a **bold** b *it* c ~~st~~ d');
      final texts = [
        for (final t in tokens)
          if (t['type'] == 'text') t,
      ];
      expect(texts[1]['text'], 'bold');
      expect(texts[1]['marks'], ['bold']);
      expect(texts[3]['marks'], ['italic']);
      expect(texts[5]['marks'], ['strike']);
    });

    test('underline maps to the highlight mark', () {
      final tokens = AstBuilder.parseInline('__under__');
      expect(tokens.single['marks'], ['highlight']);
    });

    test('***bold italic*** merges marks on one run', () {
      final tokens = AstBuilder.parseInline('***both***');
      expect(tokens.single['marks'], ['bold', 'italic']);
    });

    test('parses mention and class chips', () {
      final tokens =
          AstBuilder.parseInline('[[0192a000-0000-7000-8000-000000000011|Book]] {{00000000-0000-0000-0001-000000000025}}');
      final mention = tokens.firstWhere((t) => t['type'] == 'mention');
      expect(mention['targetNodeId'],
          '0192a000-0000-7000-8000-000000000011');
      expect(mention['text'], 'Book');
      final chip = tokens.firstWhere((t) => t['type'] == 'class_chip');
      expect(chip['classId'], '00000000-0000-0000-0001-000000000025');
      expect(chip.containsKey('displayText'), isFalse);
    });

    test('newlines become hard_break tokens', () {
      final tokens = AstBuilder.parseInline('line one\nline two');
      expect(tokens[1]['type'], 'hard_break');
      expect(AstBuilder.toPlainText(tokens), 'line one line two');
    });

    test('toMarkdown round-trips through parseInline', () {
      const source =
          'plain **bold** [[0192a000-0000-7000-8000-000000000011|Alias]]';
      final markdown = AstBuilder.toMarkdown(AstBuilder.parseInline(source));
      expect(markdown, source);
    });
  });

  group('legacy v1 AST conversion', () {
    test('paragraph children flatten with mark mapping', () {
      final tokens = legacyAstToTokens([
        {
          'type': 'paragraph',
          'children': [
            {'type': 'text', 'text': 'a '},
            {
              'type': 'strong',
              'children': [
                {'type': 'text', 'text': 'bold'},
              ],
            },
            {
              'type': 'em',
              'children': [
                {'type': 'text', 'text': ' it'},
              ],
            },
            {
              'type': 'strikethrough',
              'children': [
                {'type': 'text', 'text': 'gone'},
              ],
            },
            {
              'type': 'underline',
              'children': [
                {'type': 'text', 'text': 'under'},
              ],
            },
            {
              'type': 'highlight',
              'children': [
                {'type': 'text', 'text': 'mark'},
              ],
            },
          ],
        },
      ]);
      final byText = {for (final t in tokens) t['text']: t};
      expect(byText['bold']!['marks'], ['bold']);
      expect(byText[' it']!['marks'], ['italic']);
      expect(byText['gone']!['marks'], ['strike']);
      expect(byText['under']!['marks'], ['highlight']);
      expect(byText['mark']!['marks'], ['highlight']);
      // Flat: no paragraph wrapper.
      expect(tokens.every((t) => t['type'] == 'text'), isTrue);
    });

    test('node_link pills become mentions (target from link_id)', () {
      final tokens = legacyAstToTokens([
        {
          'type': 'paragraph',
          'children': [
            {
              'type': 'node_link',
              'link_id':
                  '0192a000-0000-7000-8000-000000000011:some-link-uuid',
              'ref_type': 'node',
              'label': 'The Book',
            },
            {
              'type': 'node_link',
              'link_id': '00000000-0000-0000-0001-000000000025',
              'ref_type': 'class',
              'label': 'Book',
            },
          ],
        },
      ]);
      final mention = tokens.firstWhere((t) => t['type'] == 'mention');
      expect(mention['targetNodeId'],
          '0192a000-0000-7000-8000-000000000011');
      expect(mention['text'], 'The Book');
      final chip = tokens.firstWhere((t) => t['type'] == 'class_chip');
      expect(chip['classId'], '00000000-0000-0000-0001-000000000025');
      expect(chip['displayText'], 'Book');
    });

    test('code/math/external_link/hard_break map one-to-one', () {
      final tokens = legacyAstToTokens([
        {
          'type': 'paragraph',
          'children': [
            {'type': 'code', 'text': 'x = 1'},
            {'type': 'math', 'expression': 'e^2'},
            {
              'type': 'external_link',
              'url': 'https://a.example',
              'children': [
                {'type': 'text', 'text': 'A'},
              ],
            },
            {'type': 'hard_break'},
          ],
        },
      ]);
      expect(tokens[0], {
        'type': 'text',
        'text': 'x = 1',
        'marks': ['code'],
      });
      expect(tokens[1]['type'], 'math');
      expect(tokens[2]['type'], 'external_link');
      expect(tokens[3]['type'], 'hard_break');
    });

    test('CRDT-wrapped legacy rows unwrap then convert', () {
      final inner = jsonEncode([
        {
          'type': 'paragraph',
          'children': [
            {'type': 'text', 'text': 'wrapped'},
          ],
        },
      ]);
      final tokens = contentTokensFromSource(jsonEncode([
        {'type': 'text', 'text': inner},
      ]));
      expect(tokens.single['text'], 'wrapped');
    });

    test('flat streams pass through unchanged (incl. fixture tokens)', () {
      final fixtureTokens = [
        {'type': 'text', 'text': 'Kuhn '},
        {
          'type': 'typed_link',
          'verb': 'cites',
          'text': 'cites',
          'metadata': {
            'locator': 'p. 42',
            'candidateSpans': ['tok_3', 'tok_7'],
          },
        },
      ];
      final tokens = contentTokensFromSource(jsonEncode(fixtureTokens));
      expect(tokens, fixtureTokens);
    });

    test('astToPlainText reads legacy and flat documents', () {
      final legacy = jsonEncode([
        {
          'type': 'paragraph',
          'children': [
            {'type': 'text', 'text': 'Legacy '},
            {
              'type': 'strong',
              'children': [
                {'type': 'text', 'text': 'title'},
              ],
            },
          ],
        },
      ]);
      expect(astToPlainText(legacy), 'Legacy title');

      final flat = jsonEncode([
        {'type': 'text', 'text': 'Flat '},
        {'type': 'hard_break'},
        {'type': 'text', 'text': ' content'},
      ]);
      expect(astToPlainText(flat), 'Flat content');
    });
  });

  group('edge derivation', () {
    late AppDatabase database;
    late NodeCacheRepository cache;
    late RelayAppliers appliers;

    OperationEnvelope envelope({
      required String id,
      required String opType,
      required Map<String, dynamic> payload,
      int physical = 1,
    }) =>
        OperationEnvelope(
          id: id,
          workspaceId: '0192a000-0000-7000-8000-000000000001',
          actorId: '0192a000-0000-7000-8000-000000000002',
          deviceId: 'test-device',
          hlc: Hlc(physical: physical, logical: 0),
          affectedNodeIds: [payload['objectId'] ?? ''],
          opType: opType,
          payload: payload,
          timestamp: '2026-09-24T12:00:00.000Z',
        );

    setUp(() async {
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      database = AppDatabase.fromDatabase(ffiDb);
      await database.initializeSchema();
      cache = NodeCacheRepository(database);
      appliers = RelayAppliers(cache);
    });

    tearDown(() async {
      await database.close();
      AppDatabase.reset();
    });

    test('typed-link-mark fixture payload derives mention + typed_link edges',
        () async {
      const pageId = '0192a000-0000-7000-8000-000000000010';
      const blockId = '0192a000-0000-7000-8000-000000000020';
      const bookId = '0192a000-0000-7000-8000-000000000011';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000001',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
        ),
      ));
      // Blocks keep the full (rich) token stream — pages/classes carry
      // text-only content (title-is-content), so the marked words live on a
      // block, mirroring the v2 store's baseStoreWithBlock tests.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000002',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: blockId,
          parentId: pageId,
        ),
      ));
      // The typed-link-mark.json fixture payload verbatim.
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000101',
        opType: 'object.update',
        payload: {
          'objectId': blockId,
          'contentAst': [
            {'type': 'text', 'text': 'Kuhn '},
            {
              'type': 'typed_link',
              'verb': 'cites',
              'text': 'cites',
              'metadata': {
                'locator': 'p. 42',
                'candidateSpans': ['tok_3', 'tok_7'],
              },
            },
            {'type': 'text', 'text': ' earlier work on '},
            {
              'type': 'mention',
              'targetNodeId': bookId,
              'text': 'The Structure of Scientific Revolutions',
            },
          ],
        },
        physical: 2,
      ));

      final db = await database.database;
      final edges = await db.rawQuery(
        'SELECT type, target_id, verb, metadata FROM edge WHERE source_id = ? ORDER BY type',
        [blockId],
      );
      expect(edges, hasLength(2));

      final mention = edges.firstWhere((e) => e['type'] == 'mention');
      expect(mention['target_id'], bookId);
      expect(mention['verb'], isNull);

      final typedLink = edges.firstWhere((e) => e['type'] == 'typed_link');
      // target_id is NULL by design (RECORD, DON'T RESOLVE until M2).
      expect(typedLink['target_id'], isNull);
      expect(typedLink['verb'], 'cites');
      final metadata =
          jsonDecode(typedLink['metadata'] as String) as Map<String, dynamic>;
      expect(metadata['locator'], 'p. 42');
      expect(metadata['candidateSpans'], ['tok_3', 'tok_7']);
      expect(metadata['text'], 'cites');

      // backlinks(target) sees the mention edge.
      final backlinks = await cache.backlinks(bookId);
      expect(backlinks, hasLength(1));
      expect(backlinks.single['source_id'], blockId);
      expect(backlinks.single['type'], 'mention');
    });

    test('stale edges die with their words on the next content update',
        () async {
      const pageId = '0192a000-0000-7000-8000-000000000010';
      const blockId = '0192a000-0000-7000-8000-000000000020';
      const bookId = '0192a000-0000-7000-8000-000000000011';
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000001',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: pageId,
        ),
      ));
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000002',
        opType: 'object.create',
        payload: OperationPayloads.objectCreate(
          objectId: blockId,
          parentId: pageId,
        ),
      ));
      final withMention = {
        'objectId': blockId,
        'contentAst': [
          {
            'type': 'mention',
            'targetNodeId': bookId,
            'text': 'Book',
          },
        ],
      };
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000002',
        opType: 'object.update',
        payload: withMention,
        physical: 2,
      ));
      expect(await cache.backlinks(bookId), hasLength(1));

      // Update without the mention removes the edge (the mark dies with its
      // word — honest lifecycle).
      await appliers.apply(envelope(
        id: '0192a000-0000-7000-8000-000000000003',
        opType: 'object.update',
        payload: {
          'objectId': blockId,
          'contentAst': [
            {'type': 'text', 'text': 'no links here'},
          ],
        },
        physical: 3,
      ));
      expect(await cache.backlinks(bookId), isEmpty);
    });
  });

  group('AstRichText (flat grammar renderer)', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('renders text runs with real mark styling', (tester) async {
      await tester.pumpWidget(wrap(AstRichText(
        source: jsonEncode([
          {'type': 'text', 'text': 'plain '},
          {'type': 'text', 'text': 'bold', 'marks': ['bold']},
          {'type': 'text', 'text': ' code', 'marks': ['code']},
          {'type': 'text', 'text': ' gone', 'marks': ['strike']},
        ]),
      )));
      final rich = tester.widget<RichText>(find.byType(RichText));
      final spans = (rich.text as TextSpan).children!;
      final bold = spans.firstWhere(
        (s) => s is TextSpan && s.style?.fontWeight == FontWeight.w700,
      );
      expect((bold as TextSpan).text, 'bold');
      final code = spans.firstWhere(
        (s) => s is TextSpan && s.style?.fontFamily == 'monospace',
      );
      expect((code as TextSpan).text, ' code');
      final strike = spans.firstWhere(
        (s) =>
            s is TextSpan &&
            s.style?.decoration == TextDecoration.lineThrough,
      );
      expect((strike as TextSpan).text, ' gone');
    });

    testWidgets('mention chip resolves the name and taps the target',
        (tester) async {
      var tapped = '';
      await tester.pumpWidget(wrap(AstRichText(
        source: jsonEncode([
          {
            'type': 'mention',
            'targetNodeId': '0192a000-0000-7000-8000-000000000011',
            'text': 'captured text',
          },
        ]),
        resolveName: (id) => 'Resolved Name',
        onNodeLinkTap: (id) => tapped = id,
      )));
      // displayText absent -> resolved name, never the captured text.
      expect(find.text('Resolved Name'), findsOneWidget);
      await tester.tap(find.text('Resolved Name'));
      expect(tapped, '0192a000-0000-7000-8000-000000000011');
    });

    testWidgets('mention falls back to the raw id when unresolvable',
        (tester) async {
      await tester.pumpWidget(wrap(const AstRichText(
        source: '[{"type":"mention","targetNodeId":"0192a000-0000-7000-8000-000000000099","text":"captured"}]',
      )));
      expect(find.text('0192a000-0000-7000-8000-000000000099'), findsOneWidget);
    });

    testWidgets('class chip renders the class name', (tester) async {
      await tester.pumpWidget(wrap(AstRichText(
        source: jsonEncode([
          {
            'type': 'class_chip',
            'classId': '00000000-0000-0000-0001-000000000025',
          },
        ]),
        resolveName: (id) => 'Book',
      )));
      expect(find.text('Book'), findsOneWidget);
    });

    testWidgets('typed_link renders the marked word underlined',
        (tester) async {
      await tester.pumpWidget(wrap(AstRichText(
        source: jsonEncode([
          {'type': 'text', 'text': 'Kuhn '},
          {
            'type': 'typed_link',
            'verb': 'cites',
            'text': 'cites',
          },
        ]),
      )));
      final rich = tester.widget<RichText>(find.byType(RichText));
      final spans = (rich.text as TextSpan).children!;
      final link = spans.firstWhere(
        (s) => s is TextSpan && s.text == 'cites',
      ) as TextSpan;
      expect(
        link.style?.decoration,
        TextDecoration.underline,
      );
    });

    testWidgets('hard_break flushes the line', (tester) async {
      await tester.pumpWidget(wrap(AstRichText(
        source: jsonEncode([
          {'type': 'text', 'text': 'one'},
          {'type': 'hard_break'},
          {'type': 'text', 'text': 'two'},
        ]),
      )));
      final rich = tester.widget<RichText>(find.byType(RichText));
      final spans = (rich.text as TextSpan).children!;
      expect(
        spans.any((s) => s is TextSpan && s.text == '\n'),
        isTrue,
      );
    });

    testWidgets('quote renders its children indented', (tester) async {
      await tester.pumpWidget(wrap(AstRichText(
        source: jsonEncode([
          {'type': 'text', 'text': 'before '},
          {
            'type': 'quote',
            'children': [
              {'type': 'text', 'text': 'quoted'},
            ],
          },
        ]),
      )));
      // The quote renders as an indented container with a nested RichText
      // carrying the child runs.
      expect(find.byType(RichText), findsNWidgets(2));
      expect(find.byType(Container), findsWidgets);
    });

    testWidgets('block-scale tokens render as labeled placeholders',
        (tester) async {
      await tester.pumpWidget(wrap(AstRichText(
        source: jsonEncode([
          {'type': 'asset_ref', 'assetId': '0192a000-0000-7000-8000-0000000000b1'},
          {'type': 'embed_ref', 'nodeId': '0192a000-0000-7000-8000-0000000000b2'},
          {'type': 'query', 'queryAst': {}},
          {'type': 'whiteboard', 'layout': {}},
          {'type': 'math', 'expression': 'x'},
        ]),
      )));
      expect(find.text('📎 Asset'), findsOneWidget);
      expect(find.text('▶ Embed'), findsOneWidget);
      expect(find.text('🔎 Query'), findsOneWidget);
      expect(find.text('🖼 Whiteboard'), findsOneWidget);
      // math renders as a monospace span. (Placeholder chips are Text
      // widgets, which build their own inner RichText — take the outer one.)
      final rich = tester.widgetList<RichText>(find.byType(RichText)).first;
      final spans = (rich.text as TextSpan).children!;
      final math = spans.firstWhere(
        (span) => span is TextSpan && span.style?.fontFamily == 'monospace',
      ) as TextSpan;
      expect(math.text, 'x');
    });

    testWidgets('legacy v1 documents render through the conversion',
        (tester) async {
      await tester.pumpWidget(wrap(AstRichText(
        source: jsonEncode([
          {
            'type': 'paragraph',
            'children': [
              {'type': 'text', 'text': 'legacy '},
              {
                'type': 'strong',
                'children': [
                  {'type': 'text', 'text': 'bold'},
                ],
              },
              {
                'type': 'node_link',
                'link_id': '0192a000-0000-7000-8000-000000000011:x',
                'ref_type': 'node',
                'label': 'Pill',
              },
            ],
          },
        ]),
        resolveName: (id) => 'Resolved',
      )));
      // The captured label 'Pill' is non-authoritative: the resolved name
      // wins for mentions (auto-rename free).
      expect(find.text('Resolved'), findsOneWidget);
      final rich = tester.widgetList<RichText>(find.byType(RichText)).first;
      final spans = (rich.text as TextSpan).children!;
      final bold = spans.firstWhere(
        (span) => span is TextSpan && span.style?.fontWeight == FontWeight.w700,
      ) as TextSpan;
      expect(bold.text, 'bold');
    });
  });
}
