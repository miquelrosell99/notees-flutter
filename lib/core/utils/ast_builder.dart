import 'dart:convert';

/// Lightweight AST builder/parser for Notees node content.
///
/// The mobile editor edits blocks as plain text with lightweight Markdown-like
/// markers. Before saving, the text is parsed into the backend AST shape so the
/// web app can render links and inline styles correctly.
///
/// Supported syntax:
/// - `**bold**` → strong
/// - `*italic*` → em
/// - `~~strike~~` → strikethrough
/// - `==highlight==` → highlight
/// - `` `code` `` → code
/// - `[[nodeId]]` or `[[nodeId|label]]` → node_link (ref_type: node)
/// - `{{classId}}` or `{{classId|label}}` → node_link (ref_type: class)
class AstBuilder {
  AstBuilder._();

  /// Parses [text] into a one-paragraph AST document.
  static List<Map<String, dynamic>> parseInline(String text) {
    final children = _parseInlineChildren(text);
    if (children.isEmpty) return [];
    return [
      {'type': 'paragraph', 'children': children},
    ];
  }

  /// Serializes an AST document to JSON.
  static String serialize(List<Map<String, dynamic>> ast) => jsonEncode(ast);

  /// Converts an AST document back to the mobile editor's Markdown-like text.
  static String toMarkdown(List<Map<String, dynamic>> ast) {
    final buffer = StringBuffer();
    for (var i = 0; i < ast.length; i++) {
      _writeMarkdown(ast[i], buffer);
      if (i < ast.length - 1) buffer.write('\n');
    }
    return buffer.toString();
  }

  static void _writeMarkdown(dynamic node, StringBuffer buffer, {String? wrapper}) {
    if (node is! Map<String, dynamic>) return;
    final type = node['type'] as String?;

    String inner;
    switch (type) {
      case 'paragraph':
      case 'heading':
        for (final child in (node['children'] as List? ?? [])) {
          _writeMarkdown(child, buffer);
        }
      case 'text':
        buffer.write(node['text'] ?? '');
      case 'code':
        buffer.write('`${node['text'] ?? ''}`');
      case 'strong':
        inner = _collectMarkdown(node['children']);
        buffer.write('**$inner**');
      case 'em':
        inner = _collectMarkdown(node['children']);
        buffer.write('*$inner*');
      case 'strikethrough':
        inner = _collectMarkdown(node['children']);
        buffer.write('~~$inner~~');
      case 'highlight':
        inner = _collectMarkdown(node['children']);
        buffer.write('==$inner==');
      case 'node_link':
        final linkId = node['link_id'] as String? ?? '';
        final target = linkId.split(':').first;
        final label = node['label'] as String?;
        final refType = node['ref_type'] as String? ?? 'node';
        final open = refType == 'class' ? '{{' : '[[';
        final close = refType == 'class' ? '}}' : ']]';
        if (label != null && label.isNotEmpty) {
          buffer.write('$open$target|$label$close');
        } else {
          buffer.write('$open$target$close');
        }
      case 'external_link':
        final url = node['url'] as String? ?? '';
        final text = _collectMarkdown(node['children']);
        buffer.write('[$text]($url)');
      default:
        for (final child in (node['children'] as List? ?? [])) {
          _writeMarkdown(child, buffer);
        }
    }
  }

  static String _collectMarkdown(dynamic nodes) {
    final buffer = StringBuffer();
    if (nodes is List) {
      for (final child in nodes) {
        _writeMarkdown(child, buffer);
      }
    }
    return buffer.toString();
  }

  /// Extracts plain text from an AST document.
  static String toPlainText(List<Map<String, dynamic>> ast) {
    final buffer = StringBuffer();
    for (final block in ast) {
      _writePlainText(block, buffer);
      buffer.write(' ');
    }
    return buffer.toString().trim();
  }

  static void _writePlainText(dynamic node, StringBuffer buffer) {
    if (node is! Map<String, dynamic>) return;
    final type = node['type'] as String?;
    if (type == 'text' || type == 'code') {
      buffer.write(node['text'] ?? '');
    } else if (node['children'] is List) {
      for (final child in node['children'] as List) {
        _writePlainText(child, buffer);
      }
    }
  }

  /// Builds a simple text node.
  static Map<String, dynamic> text(String value) => {'type': 'text', 'text': value};

  /// Builds a node_link AST node.
  static Map<String, dynamic> nodeLink({
    required String targetId,
    String? linkUuid,
    String? label,
    String refType = 'node',
  }) {
    return {
      'type': 'node_link',
      'link_id': linkUuid == null ? targetId : '$targetId:$linkUuid',
      'ref_type': refType,
      if (label != null) 'label': label,
    };
  }

  static final _inlineRe = RegExp(
    r'(?<code>`[^`]+`)'
    r'|(?<bolditalic>\*\*\*(?!\s)[^*]+(?<!\s)\*\*\*)'
    r'|(?<bold>\*\*(?!\s)[^*]+(?<!\s)\*\*)'
    r'|(?<italic>\*(?!\s)[^*]+(?<!\s)\*)'
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
        nodes.add(text(text.substring(pos, start)));
      }

      final raw = match.group(0)!;
      final node = _parseMatch(raw, match);
      if (node != null) {
        nodes.add(node);
      }

      pos = end;
    }

    if (pos < text.length) {
      nodes.add(text(text.substring(pos)));
    }

    return nodes;
  }

  static Map<String, dynamic>? _parseMatch(String raw, RegExpMatch match) {
    if (match.namedGroup('code') != null) {
      return {'type': 'code', 'text': raw.substring(1, raw.length - 1)};
    }
    if (match.namedGroup('bolditalic') != null) {
      final inner = raw.substring(3, raw.length - 3);
      return {
        'type': 'strong',
        'children': [
          {'type': 'em', 'children': _parseInlineChildren(inner)},
        ],
      };
    }
    if (match.namedGroup('bold') != null) {
      final inner = raw.substring(2, raw.length - 2);
      return {'type': 'strong', 'children': _parseInlineChildren(inner)};
    }
    if (match.namedGroup('italic') != null) {
      final inner = raw.substring(1, raw.length - 1);
      return {'type': 'em', 'children': _parseInlineChildren(inner)};
    }
    if (match.namedGroup('strike') != null) {
      final inner = raw.substring(2, raw.length - 2);
      return {'type': 'strikethrough', 'children': _parseInlineChildren(inner)};
    }
    if (match.namedGroup('highlight') != null) {
      final inner = raw.substring(2, raw.length - 2);
      return {'type': 'highlight', 'children': _parseInlineChildren(inner)};
    }
    if (match.namedGroup('nodelink') != null) {
      return _parseLink(raw.substring(2, raw.length - 2), 'node');
    }
    if (match.namedGroup('classlink') != null) {
      return _parseLink(raw.substring(2, raw.length - 2), 'class');
    }
    return null;
  }

  static Map<String, dynamic> _parseLink(String inner, String refType) {
    final parts = inner.split('|');
    final target = parts[0].trim();
    final label = parts.length > 1 ? parts[1].trim() : null;
    return nodeLink(targetId: target, label: label, refType: refType);
  }
}
