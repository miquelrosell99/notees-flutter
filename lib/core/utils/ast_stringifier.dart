/// Converts Notees node names (stored as JSON AST documents) into plain text.
///
/// The backend stores every node `name` as a JSON-encoded AST, so the mobile
/// app must never render `name` directly. This helper extracts readable text
/// from that AST for use as a fallback when the backend does not provide a
/// resolved `display_name`.
///
/// Notees
/// Copyright (C) 2026 Miquel Rosell Tarragó
/// AGPL-3.0 – see LICENSE.
library;

import 'dart:convert';

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

/// Extracts plain text from a Notees AST document.
///
/// Returns an empty string for null/empty input. If [source] is not valid
/// AST JSON, it is returned as-is so non-AST names still display.
String astToPlainText(String? source) {
  if (source == null || source.isEmpty) {
    return '';
  }

  final dynamic parsed = _tryParseJson(source);
  if (parsed == null) {
    // Not JSON — treat as a legacy plain-text name.
    return source.trim();
  }

  final blocks = parsed is List ? unwrapCrdtContentAst(parsed) : <dynamic>[];
  final buffer = StringBuffer();

  for (var i = 0; i < blocks.length; i++) {
    final block = blocks[i];
    if (block is! Map<String, dynamic>) continue;

    final text = _renderBlock(block);
    if (text.isNotEmpty) {
      if (buffer.isNotEmpty) {
        buffer.write(' ');
      }
      buffer.write(text);
    }
  }

  return _collapseWhitespace(buffer.toString());
}

dynamic _tryParseJson(String source) {
  try {
    return jsonDecode(source);
  } on FormatException {
    return null;
  }
}

String _renderBlock(Map<String, dynamic> block) {
  final type = block['type'] as String?;

  switch (type) {
    case 'paragraph':
    case 'heading':
      return _renderInlineSequence(block['children']);
    case 'whiteboard':
      return _renderWhiteboard(block);
    case 'query':
      return '';
    default:
      return '';
  }
}

String _renderWhiteboard(Map<String, dynamic> block) {
  final data = block['data'];
  if (data is! Map<String, dynamic>) return '';

  final elements = data['elements'];
  if (elements is! List) return '';

  final parts = <String>[];
  for (final element in elements) {
    if (element is! Map<String, dynamic>) continue;
    final etype = element['type'] as String?;
    final text = element['text'];
    if ((etype == 'text' || etype == 'shape') && text is String && text.isNotEmpty) {
      parts.add(text);
    }
  }

  return parts.join(' ');
}

String _renderInlineSequence(dynamic children) {
  if (children is! List) return '';

  final buffer = StringBuffer();
  for (final child in children) {
    if (child is Map<String, dynamic>) {
      buffer.write(_renderInline(child));
    }
  }
  return buffer.toString();
}

String _renderInline(Map<String, dynamic> node) {
  final type = node['type'] as String?;

  switch (type) {
    case 'text':
      final text = node['text'];
      return text is String ? text : '';
    case 'hard_break':
      return ' ';
    case 'strong':
    case 'em':
    case 'strikethrough':
    case 'highlight':
    case 'underline':
      return _renderInlineSequence(node['children']);
    case 'code':
      final text = node['text'];
      return text is String ? text : '';
    case 'math':
      final expression = node['expression'];
      return expression is String ? expression : '';
    case 'external_link':
      return _renderInlineSequence(node['children']);
    case 'node_link':
      final label = node['label'];
      if (label is String && label.isNotEmpty) {
        return label;
      }
      return '…';
    case 'user_mention':
      final label = node['label'];
      return label is String ? '@$label' : '';
    default:
      return '';
  }
}

String _collapseWhitespace(String text) {
  final result = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return result;
}
