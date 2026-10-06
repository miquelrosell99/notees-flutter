import 'dart:convert';

import '../../domain/models/content/content_token.dart';

/// Builder/parser for Notees block content in the flat token grammar
/// (SCHEMA.md "Content grammar" — the port of content-mark.ts).
///
/// The mobile editor edits blocks as plain text with lightweight Markdown-like
/// markers; before saving, the text is parsed into the flat token stream so
/// the web app and the relay speak one grammar. The grammar has no block-level
/// segments: newlines inside a block become `hard_break` tokens, headings do
/// not exist (a literal `# ` stays text), and inline styles are `marks` on
/// text runs rather than nested nodes.
///
/// Supported syntax:
/// - `**bold**` → text run with the `bold` mark
/// - `*italic*` → `italic` mark
/// - `__underline__` → `highlight` mark (the mark set has no underline)
/// - `~~strike~~` → `strike` mark
/// - `==highlight==` → `highlight` mark
/// - `` `code` `` → `code` mark
/// - `[[nodeId]]` or `[[nodeId|label]]` → mention token
/// - `{{classId}}` or `{{classId|label}}` → class_chip token
/// - newlines → hard_break tokens
class AstBuilder {
  AstBuilder._();

  /// Parses [text] into the flat token stream.
  static List<Map<String, dynamic>> parseInline(String text) {
    final tokens = <Map<String, dynamic>>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) tokens.add(const {'type': 'hard_break'});
      tokens.addAll(_parseInlineChildren(lines[i]));
    }
    return tokens;
  }

  /// Serializes a token stream to JSON.
  static String serialize(List<Map<String, dynamic>> ast) => jsonEncode(ast);

  /// Builds a simple text token.
  static Map<String, dynamic> text(String value) => {
    'type': 'text',
    'text': value,
  };

  /// Builds a mention token (the node_link replacement).
  static Map<String, dynamic> nodeLink({
    required String targetId,
    String? linkUuid,
    String? label,
    String refType = 'node',
  }) {
    if (refType == 'class') {
      return {
        'type': 'class_chip',
        'classId': targetId,
        if (label != null && label.isNotEmpty) 'displayText': label,
      };
    }
    return {
      'type': 'mention',
      'targetNodeId': targetId,
      'text': label ?? targetId,
      if (linkUuid != null && linkUuid.isNotEmpty) 'linkId': linkUuid,
    };
  }

  /// Converts a token stream back to the mobile editor's Markdown-like text.
  ///
  /// hard_break tokens flush the line ('\n'); mention chips round-trip to
  /// `[[target|text]]`, class chips to `{{classId|displayText}}`.
  static String toMarkdown(List<Map<String, dynamic>> ast) {
    final buffer = StringBuffer();
    for (final token in ast) {
      _writeMarkdown(token, buffer);
    }
    return buffer.toString();
  }

  static void _writeMarkdown(Map<String, dynamic> token, StringBuffer buffer) {
    switch (token['type']) {
      case 'hard_break':
        buffer.write('\n');
      case 'text':
        final text = token['text'] as String? ?? '';
        final marks = ((token['marks'] as List<dynamic>?) ?? const [])
            .cast<String>();
        var rendered = text;
        if (marks.contains('code')) rendered = '`$rendered`';
        if (marks.contains('bold')) rendered = '**$rendered**';
        if (marks.contains('italic')) rendered = '*$rendered*';
        if (marks.contains('strike')) rendered = '~~$rendered~~';
        if (marks.contains('highlight')) rendered = '==$rendered==';
        buffer.write(rendered);
      case 'mention':
        final target = token['targetNodeId'] as String? ?? '';
        final text = token['text'] as String? ?? '';
        buffer.write(text.isNotEmpty ? '[[$target|$text]]' : '[[$target]]');
      case 'class_chip':
        final classId = token['classId'] as String? ?? '';
        final display = token['displayText'] as String?;
        buffer.write(
          display != null && display.isNotEmpty
              ? '{{$classId|$display}}'
              : '{{$classId}}',
        );
      case 'typed_link':
        buffer.write(token['text'] as String? ?? '');
      case 'external_link':
        buffer.write('[${token['text'] ?? ''}](${token['href'] ?? ''})');
      case 'math':
        buffer.write('\$${token['expression'] ?? ''}\$');
      case 'quote':
        for (final child
            in (token['children'] as List<dynamic>? ?? const <dynamic>[])) {
          if (child is Map<String, dynamic>) _writeMarkdown(child, buffer);
        }
      case 'asset_ref':
      case 'embed_ref':
      case 'query':
      case 'whiteboard':
        // Block-scale placeholders: the editor text form keeps a label so
        // the token is not silently lost on re-save.
        buffer.write('[${token['type']}]');
      default:
        final text = token['text'];
        if (text is String) buffer.write(text);
    }
  }

  /// Extracts plain text from a token stream (the excerpt derivation).
  static String toPlainText(List<Map<String, dynamic>> ast) =>
      plainTextExcerpt(parseContentAst(ast));

  static final _inlineRe = RegExp(
    r'(?<code>`[^`]+`)'
    r'|(?<bolditalic>\*\*\*(?!\s)[^*]+(?<!\s)\*\*\*)'
    r'|(?<bold>\*\*(?!\s)[^*]+(?<!\s)\*\*)'
    r'|(?<italic>\*(?!\s)[^*]+(?<!\s)\*)'
    r'|(?<underline>__(?!\s)[^_]+(?<!\s)__)'
    r'|(?<strike>~~(?!\s)[^~]+(?<!\s)~~)'
    r'|(?<highlight>==(?!\s)[^=]+(?<!\s)==)'
    r'|(?<nodelink>\[\[[^\]]+\]\])'
    r'|(?<classlink>\{\{[^\}]+\}\})',
  );

  static List<Map<String, dynamic>> _parseInlineChildren(String text) {
    final nodes = <Map<String, dynamic>>[];
    var pos = 0;

    for (final match in _inlineRe.allMatches(text)) {
      final start = match.start;
      final end = match.end;

      if (start > pos) {
        nodes.add(AstBuilder.text(text.substring(pos, start)));
      }

      final raw = match.group(0)!;
      final produced = _parseMatch(raw, match);
      if (produced != null) {
        nodes.addAll(produced);
      }

      pos = end;
    }

    if (pos < text.length) {
      nodes.add(AstBuilder.text(text.substring(pos)));
    }

    return _mergeAdjacentText(nodes);
  }

  /// Merges adjacent plain text runs produced by the split so the stream
  /// stays compact (the grammar has no run boundaries to preserve).
  static List<Map<String, dynamic>> _mergeAdjacentText(
    List<Map<String, dynamic>> nodes,
  ) {
    final merged = <Map<String, dynamic>>[];
    for (final node in nodes) {
      final last = merged.isEmpty ? null : merged.last;
      if (last != null &&
          last['type'] == 'text' &&
          node['type'] == 'text' &&
          (last['marks'] as List?)?.isEmpty != false &&
          (node['marks'] as List?)?.isEmpty != false) {
        last['text'] = '${last['text']}${node['text']}';
      } else {
        merged.add(Map<String, dynamic>.from(node));
      }
    }
    return merged;
  }

  static List<Map<String, dynamic>>? _parseMatch(
    String raw,
    RegExpMatch match,
  ) {
    if (match.namedGroup('code') != null) {
      return [
        {
          'type': 'text',
          'text': raw.substring(1, raw.length - 1),
          'marks': const ['code'],
        },
      ];
    }
    if (match.namedGroup('bolditalic') != null) {
      return _markedText(raw.substring(3, raw.length - 3), const [
        'bold',
        'italic',
      ]);
    }
    if (match.namedGroup('bold') != null) {
      return _markedText(raw.substring(2, raw.length - 2), const ['bold']);
    }
    if (match.namedGroup('italic') != null) {
      return _markedText(raw.substring(1, raw.length - 1), const ['italic']);
    }
    if (match.namedGroup('underline') != null) {
      return _markedText(raw.substring(2, raw.length - 2), const ['highlight']);
    }
    if (match.namedGroup('strike') != null) {
      return _markedText(raw.substring(2, raw.length - 2), const ['strike']);
    }
    if (match.namedGroup('highlight') != null) {
      return _markedText(raw.substring(2, raw.length - 2), const ['highlight']);
    }
    if (match.namedGroup('nodelink') != null) {
      return [_parseLink(raw.substring(2, raw.length - 2), 'node')];
    }
    if (match.namedGroup('classlink') != null) {
      return [_parseLink(raw.substring(2, raw.length - 2), 'class')];
    }
    return null;
  }

  /// Parses a marked span's inner text with the full inline grammar so
  /// `**[[id|x]]**` composes; the marks ride along on every produced text
  /// run while pills (mention/class chips) pass through unstyled.
  static List<Map<String, dynamic>> _markedText(
    String inner,
    List<String> marks,
  ) {
    final children = _parseInlineChildren(inner);
    final out = <Map<String, dynamic>>[];
    for (final child in children) {
      if (child['type'] == 'text') {
        final existing =
            ((child['marks'] as List<dynamic>?) ?? const <dynamic>[])
                .cast<String>();
        out.add({
          'type': 'text',
          'text': child['text'],
          'marks': [...existing, ...marks],
        });
      } else {
        out.add(child);
      }
    }
    return out;
  }

  static Map<String, dynamic> _parseLink(String inner, String refType) {
    final parts = inner.split('|');
    final target = parts[0].trim();
    final label = parts.length > 1 ? parts[1].trim() : null;
    return nodeLink(targetId: target, label: label, refType: refType);
  }
}
