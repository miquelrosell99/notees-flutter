/// Flat content-token model — the Dart port of
/// `packages/protocol/src/content-mark.ts` (SCHEMA.md "Content grammar"
/// is normative).
///
/// A block node's content is ONE flat, ordered token array. There are no
/// block-level "segments": paragraph spacing, quotes, queries, whiteboards,
/// assets, and embeds are all tokens in the same stream. `quote` is the only
/// nested token (inline children).
library;

import 'dart:convert';

/// The mark names (content-mark.ts MARKS): attributes on text runs.
const List<String> kContentMarks = [
  'bold',
  'italic',
  'strike',
  'highlight',
  'code',
];

/// One token of the flat content stream.
sealed class ContentToken {
  const ContentToken();

  /// The wire `type` discriminator.
  String get type;

  Map<String, dynamic> toJson();

  /// Parses one token map, dispatching on `type`. Unknown shapes become
  /// [UnsupportedToken] so a newer stream degrades to placeholders instead
  /// of crashing the renderer. Known types with MALFORMED shapes fail loud
  /// (FormatException) per the strict content grammar —
  /// `code_block`/`hr`/`embed_ref.view` are strict entries (a malformed known
  /// token is a wire violation, not a forward-compat case).
  factory ContentToken.fromJson(Map<String, dynamic> json) {
    return switch (json['type']) {
      'text' => TextToken.fromJson(json),
      'typed_link' => TypedLinkToken.fromJson(json),
      'mention' => MentionToken.fromJson(json),
      'class_chip' => ClassChipToken.fromJson(json),
      'external_link' => ExternalLinkToken.fromJson(json),
      'math' => MathToken.fromJson(json),
      'hard_break' => const HardBreakToken(),
      'asset_ref' => AssetRefToken.fromJson(json),
      'embed_ref' => EmbedRefToken.fromJson(json),
      'query' => QueryToken.fromJson(json),
      'whiteboard' => WhiteboardToken.fromJson(json),
      'quote' => QuoteToken.fromJson(json),
      'code_block' => CodeBlockToken.fromJson(json),
      'hr' => HrToken.fromJson(json),
      _ => UnsupportedToken(json),
    };
  }
}

/// A run of styled (or plain) text. [marks] carries a subset of
/// [kContentMarks] in first-applied order.
class TextToken extends ContentToken {
  const TextToken({required this.text, this.marks = const []});

  final String text;
  final List<String> marks;

  @override
  String get type => 'text';

  bool get isPlain => marks.isEmpty;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'text',
    'text': text,
    if (marks.isNotEmpty) 'marks': marks,
  };

  factory TextToken.fromJson(Map<String, dynamic> json) => TextToken(
    text: json['text'] as String? ?? '',
    marks: ((json['marks'] as List<dynamic>?) ?? const [])
        .cast<String>()
        .where(kContentMarks.contains)
        .toList(),
  );
}

/// Per-value qualifiers on a typed-link mark (RECORD, DON'T RESOLSE data).
class TypedLinkMetadata {
  const TypedLinkMetadata({this.locator, this.candidateSpans = const []});

  /// e.g. PDF page/section, auto-filled from the current selection.
  final String? locator;

  /// Ordered nearest-first candidate target ids — recorded at capture.
  final List<String> candidateSpans;

  Map<String, dynamic> toJson() => {
    if (locator != null) 'locator': locator,
    if (candidateSpans.isNotEmpty) 'candidateSpans': candidateSpans,
  };

  factory TypedLinkMetadata.fromJson(Map<String, dynamic> json) =>
      TypedLinkMetadata(
        locator: json['locator'] as String?,
        candidateSpans: ((json['candidateSpans'] as List<dynamic>?) ?? const [])
            .cast<String>(),
      );
}

/// Free verb, or bound to a property schema (create-and-bind gesture).
sealed class TypedLinkVerb {
  const TypedLinkVerb();

  /// The wire form: a plain string or `{"propertySchemaId": ...}`.
  dynamic toJson();

  /// The verb for display/tooltip purposes.
  String get display;

  factory TypedLinkVerb.fromJson(dynamic raw) => switch (raw) {
    String s => FreeVerb(s),
    Map<String, dynamic> m => BoundVerb(m['propertySchemaId'] as String),
    _ => const FreeVerb(''),
  };
}

class FreeVerb extends TypedLinkVerb {
  const FreeVerb(this.verb);
  final String verb;

  @override
  dynamic toJson() => verb;
  @override
  String get display => verb;
}

class BoundVerb extends TypedLinkVerb {
  const BoundVerb(this.propertySchemaId);
  final String propertySchemaId;

  @override
  dynamic toJson() => {'propertySchemaId': propertySchemaId};
  @override
  String get display => propertySchemaId;
}

/// A typed link — a MARK on a prose word (01-knowledge-model.md): nothing
/// is inserted; the marked word is the annotation and dies with its word.
class TypedLinkToken extends ContentToken {
  const TypedLinkToken({required this.verb, required this.text, this.metadata});

  final TypedLinkVerb verb;

  /// The marked word exactly as written.
  final String text;
  final TypedLinkMetadata? metadata;

  @override
  String get type => 'typed_link';

  @override
  Map<String, dynamic> toJson() => {
    'type': 'typed_link',
    'verb': verb.toJson(),
    'text': text,
    if (metadata != null) 'metadata': metadata!.toJson(),
  };

  factory TypedLinkToken.fromJson(Map<String, dynamic> json) => TypedLinkToken(
    verb: TypedLinkVerb.fromJson(json['verb']),
    text: json['text'] as String? ?? '',
    metadata: json['metadata'] is Map<String, dynamic>
        ? TypedLinkMetadata.fromJson(json['metadata'] as Map<String, dynamic>)
        : null,
  );
}

/// A mention of another node. [text] is the captured surface form
/// (non-authoritative; display resolves the target's current name).
/// [linkId] is the optional stable per-link instance id (node_link key).
class MentionToken extends ContentToken {
  const MentionToken({
    required this.targetNodeId,
    required this.text,
    this.displayText,
    this.linkId,
  });

  final String targetNodeId;
  final String text;
  final String? displayText;
  final String? linkId;

  @override
  String get type => 'mention';

  @override
  Map<String, dynamic> toJson() => {
    'type': 'mention',
    'targetNodeId': targetNodeId,
    'text': text,
    if (displayText != null) 'displayText': displayText,
    if (linkId != null) 'linkId': linkId,
  };

  factory MentionToken.fromJson(Map<String, dynamic> json) => MentionToken(
    targetNodeId: json['targetNodeId'] as String? ?? '',
    text: json['text'] as String? ?? '',
    displayText: json['displayText'] as String?,
    linkId: json['linkId'] as String?,
  );
}

/// RENDER-ONLY reference to a class node: inserting or deleting a chip does
/// NOT mutate the block's class ids (owner decision, 2026-09-25).
class ClassChipToken extends ContentToken {
  const ClassChipToken({required this.classId, this.displayText});

  final String classId;
  final String? displayText;

  @override
  String get type => 'class_chip';

  @override
  Map<String, dynamic> toJson() => {
    'type': 'class_chip',
    'classId': classId,
    if (displayText != null) 'displayText': displayText,
  };

  factory ClassChipToken.fromJson(Map<String, dynamic> json) => ClassChipToken(
    classId: json['classId'] as String? ?? '',
    displayText: json['displayText'] as String?,
  );
}

class ExternalLinkToken extends ContentToken {
  const ExternalLinkToken({required this.href, required this.text});

  final String href;
  final String text;

  @override
  String get type => 'external_link';

  @override
  Map<String, dynamic> toJson() => {
    'type': 'external_link',
    'href': href,
    'text': text,
  };

  factory ExternalLinkToken.fromJson(Map<String, dynamic> json) =>
      ExternalLinkToken(
        href: json['href'] as String? ?? '',
        text: json['text'] as String? ?? '',
      );
}

class MathToken extends ContentToken {
  const MathToken({required this.expression});

  final String expression;

  @override
  String get type => 'math';

  @override
  Map<String, dynamic> toJson() => {'type': 'math', 'expression': expression};

  factory MathToken.fromJson(Map<String, dynamic> json) =>
      MathToken(expression: json['expression'] as String? ?? '');
}

/// Shift+enter line jump inside a block. Enter always creates a new node;
/// there is no paragraph concept within a block.
class HardBreakToken extends ContentToken {
  const HardBreakToken();

  @override
  String get type => 'hard_break';

  @override
  Map<String, dynamic> toJson() => {'type': 'hard_break'};
}

class AssetRefToken extends ContentToken {
  const AssetRefToken({required this.assetId});

  final String assetId;

  @override
  String get type => 'asset_ref';

  @override
  Map<String, dynamic> toJson() => {'type': 'asset_ref', 'assetId': assetId};

  factory AssetRefToken.fromJson(Map<String, dynamic> json) =>
      AssetRefToken(assetId: json['assetId'] as String? ?? '');
}

/// Embed — RENDER THE LIVE SUBTREE, NEVER A CLONE (cycle guard is a
/// renderer obligation). Rendered as a labeled placeholder here.
///
/// [view] (B8, additive 2026-10-04 lockstep) selects the
/// presentation on the mention↔embed spectrum: absent (or the explicit
/// "embed") = the full live transclusion; "small_card" / "wide_card" = the
/// intermediate bounded identity cards (cards never transclude). Unknown
/// values are rejected outright by the strict grammar.
class EmbedRefToken extends ContentToken {
  const EmbedRefToken({required this.nodeId, this.view});

  final String nodeId;
  final String? view;

  @override
  String get type => 'embed_ref';

  /// The strict view vocabulary (content-mark.ts EMBED_VIEW_MODES).
  static const viewModes = {'embed', 'small_card', 'wide_card'};

  @override
  Map<String, dynamic> toJson() => {
    'type': 'embed_ref',
    'nodeId': nodeId,
    if (view != null) 'view': view,
  };

  factory EmbedRefToken.fromJson(Map<String, dynamic> json) {
    final view = json['view'];
    if (view != null &&
        (view is! String || !viewModes.contains(view))) {
      throw FormatException(
        'embed_ref.view must be one of embed|small_card|wide_card',
      );
    }
    return EmbedRefToken(
      nodeId: json['nodeId'] as String? ?? '',
      view: view as String?,
    );
  }
}

/// Block-scale: a code block (B3, strict grammar). [text] is the
/// verbatim source (the grammar stores it plain — no nested tokens);
/// [language] is an OPTIONAL hint tag (free lowercase string — "python",
/// "typescript", "mermaid", …) for renderers; absent = plain text. A
/// PROMOTION SURVIVOR alongside whiteboard/query: block→page/class
/// promotion stringifies rich tokens to text-only content but keeps
/// code_block tokens (a code page is a real surface — flattening would
/// destroy the source).
class CodeBlockToken extends ContentToken {
  const CodeBlockToken({required this.text, this.language});

  final String text;
  final String? language;

  @override
  String get type => 'code_block';

  /// Strict language-hint tag: lowercase letters, digits, +, #, -.
  static final _languagePattern = RegExp(r'^[a-z0-9+#-]{1,64}$');

  @override
  Map<String, dynamic> toJson() => {
    'type': 'code_block',
    if (language != null) 'language': language,
    'text': text,
  };

  factory CodeBlockToken.fromJson(Map<String, dynamic> json) {
    for (final key in json.keys) {
      if (key != 'type' && key != 'language' && key != 'text') {
        throw FormatException('code_block: unknown key $key');
      }
    }
    final text = json['text'];
    if (text is! String || text.length > 65536) {
      throw FormatException(
        'code_block.text must be a string of at most 65536 chars',
      );
    }
    final language = json['language'];
    if (language != null &&
        (language is! String || !_languagePattern.hasMatch(language))) {
      throw FormatException(
        'code_block.language must be a lowercase hint tag (a-z 0-9 + # -)',
      );
    }
    return CodeBlockToken(text: text, language: language);
  }
}

/// Block-scale: a horizontal rule (B5) — the layout
/// divider token. Carries no payload. Deliberately NOT a promotion survivor:
/// an hr holds no prose, so block→page promotion stringifies it away (a
/// rule in a page title is meaningless).
class HrToken extends ContentToken {
  const HrToken();

  @override
  String get type => 'hr';

  @override
  Map<String, dynamic> toJson() => {'type': 'hr'};

  factory HrToken.fromJson(Map<String, dynamic> json) {
    for (final key in json.keys) {
      if (key != 'type') {
        throw FormatException('hr: unknown key $key');
      }
    }
    return const HrToken();
  }
}

/// Block-scale: live query view (queryAst is the versioned QueryAST model).
class QueryToken extends ContentToken {
  const QueryToken({required this.queryAst, this.view});

  final Map<String, dynamic> queryAst;
  final Map<String, dynamic>? view;

  @override
  String get type => 'query';

  @override
  Map<String, dynamic> toJson() => {
    'type': 'query',
    'queryAst': queryAst,
    if (view != null) 'view': view,
  };

  factory QueryToken.fromJson(Map<String, dynamic> json) => QueryToken(
    queryAst: (json['queryAst'] as Map<String, dynamic>?) ?? const {},
    view: json['view'] as Map<String, dynamic>?,
  );
}

/// Block-scale: whiteboard layout (shapes/strokes/viewport keyed by node id).
class WhiteboardToken extends ContentToken {
  const WhiteboardToken({required this.layout});

  final Map<String, dynamic> layout;

  @override
  String get type => 'whiteboard';

  @override
  Map<String, dynamic> toJson() => {'type': 'whiteboard', 'layout': layout};

  factory WhiteboardToken.fromJson(Map<String, dynamic> json) =>
      WhiteboardToken(
        layout: (json['layout'] as Map<String, dynamic>?) ?? const {},
      );
}

/// The only nested token: a quote contains inline tokens.
class QuoteToken extends ContentToken {
  const QuoteToken({this.children = const []});

  final List<ContentToken> children;

  @override
  String get type => 'quote';

  @override
  Map<String, dynamic> toJson() => {
    'type': 'quote',
    'children': [for (final child in children) child.toJson()],
  };

  factory QuoteToken.fromJson(Map<String, dynamic> json) => QuoteToken(
    children: [
      for (final child in (json['children'] as List<dynamic>? ?? const []))
        if (child is Map<String, dynamic>) ContentToken.fromJson(child),
    ],
  );
}

/// A token type this client does not know (forward compatibility): renders
/// as a labeled placeholder.
class UnsupportedToken extends ContentToken {
  const UnsupportedToken(this.raw);

  final Map<String, dynamic> raw;

  @override
  String get type => raw['type'] as String? ?? 'unsupported';

  @override
  Map<String, dynamic> toJson() => raw;
}

/// A parsed content stream: `ContentAst` in the spec.
typedef ContentAst = List<ContentToken>;

/// Parses a serialized content stream (or an already-decoded list) into
/// tokens. Non-object entries are skipped; a null input yields an empty
/// stream.
ContentAst parseContentAst(dynamic raw) {
  if (raw is String) {
    try {
      raw = _decode(raw);
    } on FormatException {
      // Legacy plain-text content: a single text run.
      return raw.isEmpty ? const [] : [TextToken(text: raw)];
    }
  }
  if (raw is! List) return const [];
  return [
    for (final entry in raw)
      if (entry is Map<String, dynamic>) ContentToken.fromJson(entry),
  ];
}

dynamic _decode(String source) => jsonDecode(source);

/// Plaintext excerpt derivation (port of
/// `packages/domain/src/node.ts` plainTextExcerpt): text and typed-link
/// runs contribute their text, mentions their displayText (captured text
/// when absent), math its expression, quotes recurse, and hard_break becomes
/// a space; whitespace collapses to single spaces.
///
/// Plaintext is DERIVED from stored content, never stored as truth.
String plainTextExcerpt(ContentAst? tokens) {
  if (tokens == null) return '';
  final parts = <String>[];
  void walk(List<ContentToken> stream) {
    for (final token in stream) {
      switch (token) {
        case TextToken(text: final text):
          parts.add(text);
        case TypedLinkToken(text: final text):
          parts.add(text);
        case MentionToken(displayText: final display?):
          parts.add(display);
        case MentionToken(text: final text):
          parts.add(text);
        case MathToken(expression: final expression):
          parts.add(expression);
        case QuoteToken(children: final children):
          walk(children);
        case HardBreakToken():
          parts.add(' ');
        default:
          break;
      }
    }
  }

  walk(tokens);
  return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
