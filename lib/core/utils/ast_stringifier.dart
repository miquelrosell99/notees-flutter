/// Content-stream normalization and plain-text derivation for Notees node
/// content (stored as JSON in the node `name` slot).
///
/// The wire/local format is the flat token stream (SCHEMA.md "Content
/// grammar"); rows written before the port still carry the legacy nested block
/// AST (paragraph/heading children with strong/em/strikethrough/highlight/
/// underline mark nodes and node_link pills). [normalizeContentAst] detects
/// the shape and converts legacy documents to flat tokens so the renderer,
/// the excerpt derivation, and the edge derivation all speak one grammar.
///
/// Notees
/// Copyright (C) 2026 Miquel Rosell Tarragó
/// AGPL-3.0 – see LICENSE.
library;

import 'dart:convert';

import '../../domain/models/content/content_token.dart';

/// Unwraps the CRDT text wrapper around a stored AST document.
///
/// The web inline editor saves content by serializing the real AST to JSON
/// and storing that JSON string inside the node's text CRDT, so the derived
/// content column can be `[{type:'text', text:'[<real AST>]'}]` (or the same
/// string inside a single-paragraph block). When the single block wraps a
/// JSON AST string, return the inner document; otherwise return [ast]
/// unchanged. Mirrors the web client's `unwrapCrdtContentAst`.
List<dynamic> unwrapCrdtContentAst(List<dynamic> ast) {
  if (ast.length != 1) return ast;
  final block = ast[0];
  String? wrappedText;
  if (block is Map && block['type'] == 'text' && block['text'] is String) {
    wrappedText = block['text'] as String;
  } else if (block is Map &&
      block['type'] == 'paragraph' &&
      block['children'] is List &&
      (block['children'] as List).length == 1) {
    final child = (block['children'] as List).first;
    if (child is Map && child['type'] == 'text' && child['text'] is String) {
      wrappedText = child['text'] as String;
    }
  }
  if (wrappedText == null || wrappedText.isEmpty) return ast;
  final inner = _tryParseJson(wrappedText);
  return inner is List && inner.isNotEmpty ? inner : ast;
}

/// True when [ast] is already a flat token stream (top-level tokens with
/// `type` discriminators).
bool isFlatTokenStream(List<dynamic> ast) {
  if (ast.isEmpty) return true;
  const flatTypes = {
    'text',
    'typed_link',
    'mention',
    'class_chip',
    'external_link',
    'math',
    'hard_break',
    'asset_ref',
    'embed_ref',
    'query',
    'whiteboard',
    'quote',
    'code_block',
    'hr',
  };
  for (final entry in ast) {
    if (entry is! Map<String, dynamic>) return false;
    final type = entry['type'];
    if (type is! String || !flatTypes.contains(type)) return false;
  }
  return true;
}

/// Normalizes a stored content document to the flat token stream:
/// unwraps CRDT-wrapped rows, detects legacy nested AST documents and
/// converts them (marks, node_link pills, code/math), and passes flat
/// streams through unchanged.
List<Map<String, dynamic>> normalizeContentAst(List<dynamic> ast) {
  final unwrapped = unwrapCrdtContentAst(ast);
  if (isFlatTokenStream(unwrapped)) {
    return unwrapped.whereType<Map<String, dynamic>>().toList();
  }
  return legacyAstToTokens(unwrapped);
}

/// Converts a legacy nested AST document into the flat token stream.
///
/// Mapping decisions:
///  - paragraph/heading children flatten into the same stream (the grammar
///    has no block-level segments; heading levels do not exist in the grammar
///    and their text is kept verbatim);
///  - strong/em/strikethrough/underline/highlight mark nodes fold into
///    `marks` on text runs (underline → highlight: the mark set has no
///    underline); nested marks merge;
///  - node_link pills become `mention` tokens (target from the link_id's
///    `target` prefix; ref_type class → `class_chip`);
///  - code nodes become text runs with the `code` mark; math nodes, external
///    links, and hard breaks map one-to-one; user_mention degrades to a
///    plain '@label' text run (the grammar has no user token).
List<Map<String, dynamic>> legacyAstToTokens(List<dynamic> ast) {
  final out = <Map<String, dynamic>>[];
  for (final block in ast) {
    if (block is! Map<String, dynamic>) continue;
    _convertBlock(block, out, {});
  }
  return out;
}

void _convertBlock(
  Map<String, dynamic> block,
  List<Map<String, dynamic>> out,
  Set<String> inheritedMarks,
) {
  switch (block['type']) {
    case 'paragraph':
    case 'heading':
      for (final child in (block['children'] as List? ?? const [])) {
        if (child is Map<String, dynamic>) {
          _convertInline(child, out, inheritedMarks);
        }
      }
    case 'text':
      // Bare document-level text leaf.
      final text = block['text'];
      if (text is String) {
        out.add(_textToken(text, inheritedMarks));
      }
    case 'whiteboard':
      final data = block['data'];
      if (data is Map<String, dynamic>) {
        out.add({'type': 'whiteboard', 'layout': data});
      }
    case 'query':
      final data = block['data'];
      out.add({
        'type': 'query',
        'queryAst': data is Map<String, dynamic> ? data : const {},
      });
    default:
      // Unknown legacy block: try its children so no text is lost. A childless
      // unknown block with inline text (e.g. a future flat token seen by an
      // old client) degrades to that text instead of vanishing.
      final children = block['children'] as List? ?? const [];
      if (children.isEmpty) {
        final text = block['text'];
        if (text is String && text.isNotEmpty) {
          out.add(_textToken(text, inheritedMarks));
        }
      }
      for (final child in children) {
        if (child is Map<String, dynamic>) {
          _convertInline(child, out, inheritedMarks);
        }
      }
  }
}

void _convertInline(
  Map<String, dynamic> node,
  List<Map<String, dynamic>> out,
  Set<String> inheritedMarks,
) {
  switch (node['type']) {
    case 'text':
      final text = node['text'];
      if (text is String) {
        out.add(_textToken(text, inheritedMarks));
      }
    case 'hard_break':
      out.add(const {'type': 'hard_break'});
    case 'strong':
      _convertChildren(node, out, inheritedMarks, 'bold');
    case 'em':
      _convertChildren(node, out, inheritedMarks, 'italic');
    case 'strikethrough':
      _convertChildren(node, out, inheritedMarks, 'strike');
    case 'underline':
    case 'highlight':
      _convertChildren(node, out, inheritedMarks, 'highlight');
    case 'code':
      final text = node['text'];
      out.add(
        _textToken(text is String ? text : '', {...inheritedMarks, 'code'}),
      );
    case 'math':
      final expression = node['expression'];
      out.add({
        'type': 'math',
        'expression': expression is String ? expression : '',
      });
    case 'external_link':
      final url = node['url'];
      out.add({
        'type': 'external_link',
        'href': url is String ? url : '',
        'text': _collectPlain(node),
      });
    case 'node_link':
      final linkId = node['link_id'] as String? ?? '';
      final target = linkId.split(':').first;
      final label = node['label'] as String? ?? '';
      final refType = node['ref_type'] as String? ?? 'node';
      if (refType == 'class') {
        out.add({
          'type': 'class_chip',
          'classId': target,
          if (label.isNotEmpty) 'displayText': label,
        });
      } else {
        out.add({
          'type': 'mention',
          'targetNodeId': target,
          'text': label.isEmpty ? target : label,
        });
      }
    case 'user_mention':
      final label = node['label'];
      out.add(_textToken('@${label is String ? label : ''}', inheritedMarks));
    default:
      for (final child in (node['children'] as List? ?? const [])) {
        if (child is Map<String, dynamic>) {
          _convertInline(child, out, inheritedMarks);
        }
      }
  }
}

void _convertChildren(
  Map<String, dynamic> node,
  List<Map<String, dynamic>> out,
  Set<String> inheritedMarks,
  String mark,
) {
  final merged = {...inheritedMarks, mark};
  for (final child in (node['children'] as List? ?? const [])) {
    if (child is Map<String, dynamic>) {
      _convertInline(child, out, merged);
    }
  }
}

Map<String, dynamic> _textToken(String text, Set<String> marks) {
  final valid = marks.where(kContentMarks.contains).toList(growable: false);
  return {'type': 'text', 'text': text, if (valid.isNotEmpty) 'marks': valid};
}

String _collectPlain(Map<String, dynamic> node) {
  final buffer = StringBuffer();
  void walk(Map<String, dynamic> n) {
    final text = n['text'];
    if (text is String) buffer.write(text);
    for (final child in (n['children'] as List? ?? const [])) {
      if (child is Map<String, dynamic>) walk(child);
    }
  }

  walk(node);
  return buffer.toString();
}

/// Parses a stored content document (serialized JSON or decoded list) into
/// the flat token stream. Null/invalid input yields an empty stream;
/// legacy plain-text content becomes a single text run.
List<Map<String, dynamic>> contentTokensFromSource(dynamic source) {
  if (source == null) return const [];
  if (source is String) {
    if (source.isEmpty) return const [];
    final parsed = _tryParseJson(source);
    if (parsed is! List) {
      // Legacy plain-text name.
      return [
        {'type': 'text', 'text': source},
      ];
    }
    return normalizeContentAst(parsed);
  }
  if (source is List) return normalizeContentAst(source);
  return const [];
}

/// The excerpt over a stored content document: unwraps, normalizes
/// (legacy-converting), and derives plain text per plainTextExcerpt.
String contentSourceToExcerpt(dynamic source) =>
    plainTextExcerpt(parseContentAst(contentTokensFromSource(source)));

/// Flattens any token stream to text-only content (pages and classes carry
/// text-only content — SCHEMA.md "title-is-content"). Port of
/// `stringifyContentAst` in `packages/domain/src/node.ts`: block-scale
/// structural widgets (whiteboard, query, code_block — B3) survive
/// as tokens — they are displays/source, not prose — and everything else
/// folds into a single leading text run of the plain-text excerpt.
/// `hr` (B5) is deliberately NOT a survivor: it carries no prose.
/// Used by the appliers when a block's (possibly rich) content lands on a
/// page/class node.
List<Map<String, dynamic>> stringifyContentAst(
  List<Map<String, dynamic>> ast,
) {
  final out = <Map<String, dynamic>>[
    for (final token in ast)
      if (token['type'] == 'whiteboard' ||
          token['type'] == 'query' ||
          token['type'] == 'code_block')
        token,
  ];
  final text = plainTextExcerpt(parseContentAst(ast)).trim();
  if (text.isNotEmpty) out.insert(0, {'type': 'text', 'text': text});
  return out;
}

/// Extracts plain text from a Notees content document.
///
/// Backwards-compatible entry point: accepts the serialized JSON in the node
/// `name` slot, a decoded document, or legacy plain text.
String astToPlainText(dynamic source) {
  if (source == null || (source is String && source.isEmpty)) return '';
  return contentSourceToExcerpt(source);
}

dynamic _tryParseJson(String source) {
  try {
    return jsonDecode(source);
  } on FormatException {
    return null;
  }
}
