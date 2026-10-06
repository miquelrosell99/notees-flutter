import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/ast_stringifier.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/domain/models/content/content_token.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/domain/services/relay_appliers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Acceptance for the content-grammar lockstep entries:
///
///  - `code_block` `{language?, text}` — strict lowercase language hint,
///    verbatim text, no nested tokens; a PROMOTION SURVIVOR (block→page
///    stringification keeps it — a code page is a real surface);
///  - `hr` `{type}` — carries no payload; deliberately NOT a promotion
///    survivor (a rule in a page title is meaningless);
///  - `embed_ref.view` — the strict `"embed" | "small_card" | "wide_card"`
///    enum, absent = the full transclusion.
///
/// Replays the three canonical fixtures (code-block, hr, embed-ref-view)
/// through the appliers, including the promotion stringification paths.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  const fixturesDir = 'test/fixtures/wire';

  List<Map<String, dynamic>> loadFixture(String name) =>
      ((jsonDecode(File('$fixturesDir/$name').readAsStringSync())
              as Map<String, dynamic>)['envelopes'] as List<dynamic>)
          .cast<Map<String, dynamic>>();

  List<OperationEnvelope> fixtureEnvelopes(String name) =>
      loadFixture(name).map(OperationEnvelope.fromJson).toList();

  group('code_block + hr + embed_ref.view token model', () {
    test('code_block round-trips with and without the language hint', () {
      const withLang = CodeBlockToken(language: 'python', text: "print('hi')");
      expect(
        ContentToken.fromJson(withLang.toJson()),
        isA<CodeBlockToken>()
            .having((t) => t.language, 'language', 'python')
            .having((t) => t.text, 'text', "print('hi')"),
      );
      const plain = CodeBlockToken(text: 'plain snippet');
      final json = plain.toJson();
      expect(json.containsKey('language'), isFalse);
      final restored = ContentToken.fromJson(json) as CodeBlockToken;
      expect(restored.language, isNull);
      expect(restored.text, 'plain snippet');
    });

    test('code_block strict grammar: language tag, text bound, key set',
        () {
      expect(() => CodeBlockToken.fromJson({'type': 'code_block'}),
          throwsFormatException);
      expect(
        () => CodeBlockToken.fromJson({
          'type': 'code_block',
          'text': 'x',
          'language': 'Python',
        }),
        throwsFormatException,
        reason: 'the hint tag is strict lowercase',
      );
      expect(
        () => CodeBlockToken.fromJson({
          'type': 'code_block',
          'text': 'x',
          'language': 'has space',
        }),
        throwsFormatException,
      );
      expect(
        ContentToken.fromJson({
          'type': 'code_block',
          'text': 'x',
          'language': 'c++',
        }),
        isA<CodeBlockToken>(),
        reason: '+ and # are legal hint chars',
      );
      expect(
        () => CodeBlockToken.fromJson({
          'type': 'code_block',
          'text': 'x',
          'mermaid': true,
        }),
        throwsFormatException,
        reason: 'strict key set (zod .strict() parity)',
      );
      expect(
        () => CodeBlockToken.fromJson({
          'type': 'code_block',
          'text': 'x' * 65537,
        }),
        throwsFormatException,
        reason: 'text is capped at 65536 chars',
      );
    });

    test('hr is a bare {type} token with a strict key set', () {
      expect(const HrToken().toJson(), {'type': 'hr'});
      expect(ContentToken.fromJson(const {'type': 'hr'}), isA<HrToken>());
      expect(
        () => HrToken.fromJson({'type': 'hr', 'thickness': 2}),
        throwsFormatException,
      );
    });

    test('embed_ref.view: absent = full transclusion; strict enum otherwise',
        () {
      final absent = EmbedRefToken.fromJson({
        'type': 'embed_ref',
        'nodeId': '0192a000-0000-7000-8000-000000000640',
      });
      expect(absent.view, isNull);
      final small = EmbedRefToken.fromJson({
        'type': 'embed_ref',
        'nodeId': '0192a000-0000-7000-8000-000000000640',
        'view': 'small_card',
      });
      expect(small.view, 'small_card');
      expect(small.toJson()['view'], 'small_card');
      final wide = EmbedRefToken.fromJson({
        'type': 'embed_ref',
        'nodeId': '0192a000-0000-7000-8000-000000000640',
        'view': 'wide_card',
      });
      expect(wide.view, 'wide_card');
      expect(
        () => EmbedRefToken.fromJson({
          'type': 'embed_ref',
          'nodeId': '0192a000-0000-7000-8000-000000000640',
          'view': 'thumbnail',
        }),
        throwsFormatException,
      );
    });

    test('code_block/hr join the flat stream (no legacy conversion)', () {
      final stream = normalizeContentAst([
        {'type': 'text', 'text': 'a'},
        {'type': 'code_block', 'text': 'x = 1'},
        {'type': 'hr'},
        {'type': 'text', 'text': 'b'},
      ]);
      expect(
        stream.map((t) => t['type']).toList(),
        ['text', 'code_block', 'hr', 'text'],
      );
    });

    test('stringifyContentAst: code_block survives, hr flattens away', () {
      final flattened = stringifyContentAst([
        {'type': 'text', 'text': 'before'},
        {'type': 'code_block', 'language': 'python', 'text': "print('hi')"},
        {'type': 'text', 'text': 'after'},
        {'type': 'hr'},
      ]);
      expect(
        flattened,
        [
          {'type': 'text', 'text': 'before after'},
          {
            'type': 'code_block',
            'language': 'python',
            'text': "print('hi')",
          },
        ],
      );
      // A code-only page keeps the block (a code page is a real surface)...
      expect(
        stringifyContentAst([
          {'type': 'code_block', 'text': 'snippet'},
        ]),
        [
          {'type': 'code_block', 'text': 'snippet'},
        ],
      );
      // ...an hr-only page stringifies to nothing (no prose, no survivor).
      expect(stringifyContentAst(const [{'type': 'hr'}]), isEmpty);
    });

    test('plainTextExcerpt skips structural tokens (both new ones)', () {
      expect(
        plainTextExcerpt(parseContentAst([
          {'type': 'text', 'text': 'above'},
          {'type': 'code_block', 'text': 'ignored'},
          {'type': 'hr'},
          {'type': 'text', 'text': 'below'},
        ])),
        'above below',
      );
    });
  });

  group('content fixtures replay', () {
    late AppDatabase database;
    late NodeCacheRepository cache;
    late RelayAppliers appliers;

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

    test('code-block fixture: the survivor rides the promotion', () async {
      for (final envelope in fixtureEnvelopes('code-block.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      const block = '0192a000-0000-7000-8000-000000000621';
      const codeOnly = '0192a000-0000-7000-8000-000000000623';
      // Promotion (object.update presentAsMain=true) stringified the rich
      // stream: prose folded to one leading text run, the code_block kept.
      expect(
        jsonDecode((await cache.getByUuid(block))!.name),
        [
          {'type': 'text', 'text': 'before after'},
          {
            'type': 'code_block',
            'language': 'python',
            'text': "print('hi')\nprint('bye')",
          },
        ],
      );
      expect(
        (await cache.getByUuid(block))!.displayName,
        'before after',
      );
      // The code-only block stays an inline child (the fixture promotes
      // only …621): the verbatim token round-trips with no synthetic prose
      // — the survivor-through-promotion assertion is …621 above.
      expect(
        jsonDecode((await cache.getByUuid(codeOnly))!.name),
        [
          {'type': 'code_block', 'text': 'plain snippet'},
        ],
      );
    });

    test('hr fixture: the rule flattens out of the promoted title', () async {
      for (final envelope in fixtureEnvelopes('hr.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      const block = '0192a000-0000-7000-8000-000000000631';
      const hrOnly = '0192a000-0000-7000-8000-000000000633';
      expect(
        jsonDecode((await cache.getByUuid(block))!.name),
        [
          {'type': 'text', 'text': 'above below'},
        ],
      );
      // The hr-only block stays an inline child (the fixture promotes only
      // …631), so its stream rides through verbatim — the flatten-only
      // assertion for an hr-only page lives in the unit test above.
      expect(
        jsonDecode((await cache.getByUuid(hrOnly))!.name),
        [
          {'type': 'hr'},
        ],
      );
    });

    test('embed-ref-view fixture: card views land verbatim, absent = full',
        () async {
      for (final envelope in fixtureEnvelopes('embed-ref-view.json')) {
        expect(await appliers.apply(envelope), isTrue);
      }
      const hostBlock = '0192a000-0000-7000-8000-000000000642';
      expect(
        jsonDecode((await cache.getByUuid(hostBlock))!.name),
        [
          {
            'type': 'embed_ref',
            'nodeId': '0192a000-0000-7000-8000-000000000640',
          },
          {
            'type': 'embed_ref',
            'nodeId': '0192a000-0000-7000-8000-000000000640',
            'view': 'wide_card',
          },
        ],
      );
    });
  });
}
