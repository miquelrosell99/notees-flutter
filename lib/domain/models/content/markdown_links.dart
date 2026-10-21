/// Markdown-link splitting for plain text tokens — the Dart port of
/// `packages/domain/src/markdownLinks.ts`, the canonical parser for the
/// retired `external_link` token's replacement (SCHEMA.md "Content
/// grammar": links live as markdown `[label](href)` spans inside `text`
/// tokens, parsed at render time).
///
/// Imports and external writers can only place raw text in a page title (the
/// store flattens rich tokens on document-chrome nodes), so this shape is the
/// one link format that survives every boundary. The parse is deliberately
/// conservative: the label holds no `]` or newline, the href holds no
/// whitespace or parentheses, and only http/https/mailto hrefs become
/// anchors — anything else (unclosed brackets, `javascript:` schemes,
/// relative paths) stays literal text, never a link.
library;

/// One segment of a split text run: plain [MarkdownPlainText] text or a
/// linkable [MarkdownLink] anchor.
sealed class MarkdownTextSegment {
  const MarkdownTextSegment();

  /// The visible label.
  String get text;
}

class MarkdownPlainText extends MarkdownTextSegment {
  const MarkdownPlainText(this.text);

  @override
  final String text;
}

class MarkdownLink extends MarkdownTextSegment {
  const MarkdownLink({required this.text, required this.href});

  @override
  final String text;
  final String href;
}

final _markdownLinkRe = RegExp(r'\[([^\]\n]+)\]\(([^()\s]+)\)');

/// Scheme allow-list — the security-relevant part of the decision: a
/// non-http(s)/mailto href must never become a clickable anchor (a
/// `javascript:` href in an <a> attribute is executable on click).
String? _linkableHref(String href) =>
    RegExp(r'^(https?://|mailto:)', caseSensitive: false).hasMatch(href)
    ? href
    : null;

/// Splits [text] into plain and link segments per the render grammar.
List<MarkdownTextSegment> splitMarkdownLinks(String text) {
  final segments = <MarkdownTextSegment>[];
  var cursor = 0;
  for (final match in _markdownLinkRe.allMatches(text)) {
    final raw = match.group(0)!;
    final label = match.group(1) ?? '';
    final href = match.group(2) ?? '';
    if (match.start > cursor) {
      segments.add(MarkdownPlainText(text.substring(cursor, match.start)));
    }
    final safeHref = _linkableHref(href);
    if (safeHref != null) {
      segments.add(MarkdownLink(text: label, href: safeHref));
    } else {
      segments.add(MarkdownPlainText(raw));
    }
    cursor = match.end;
  }
  if (segments.isEmpty) return [MarkdownPlainText(text)];
  if (cursor < text.length) {
    segments.add(MarkdownPlainText(text.substring(cursor)));
  }
  return segments;
}
