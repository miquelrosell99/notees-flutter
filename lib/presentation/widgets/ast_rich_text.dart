import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Renders a Notees JSON AST node name as styled rich text.
///
/// When a block is not being edited, this avoids showing raw Markdown-like
/// source such as `[[uuid|label]]` or `**bold**`. Node links are rendered as
/// tappable chips and inline styles use the current theme.
class AstRichText extends StatelessWidget {
  const AstRichText({
    super.key,
    required this.source,
    this.onNodeLinkTap,
    this.onExternalLinkTap,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.ellipsis,
  });

  /// JSON-encoded AST document (the backend `node.name` value).
  final String source;

  /// Called when the user taps a node/class link. Receives the target id.
  final ValueChanged<String>? onNodeLinkTap;

  /// Called when the user taps an external link. Receives the URL.
  final ValueChanged<String>? onExternalLinkTap;

  /// Base text style. Defaults to the ambient body style.
  final TextStyle? style;

  final int? maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    final defaultStyle = style ?? DefaultTextStyle.of(context).style;
    final spans = _buildSpans(context, source, defaultStyle);

    return RichText(
      maxLines: maxLines,
      overflow: overflow,
      text: TextSpan(
        style: defaultStyle,
        children: spans,
      ),
    );
  }

  List<InlineSpan> _buildSpans(BuildContext context, String source, TextStyle base) {
    final ast = _tryParseAst(source);
    if (ast == null || ast.isEmpty) {
      return [const TextSpan(text: '')];
    }

    final spans = <InlineSpan>[];
    for (final block in ast) {
      spans.addAll(_buildBlockSpans(context, block, base));
    }
    return spans;
  }

  List<Map<String, dynamic>>? _tryParseAst(String source) {
    try {
      final parsed = jsonDecode(source);
      if (parsed is List) {
        return parsed.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return null;
  }

  List<InlineSpan> _buildBlockSpans(BuildContext context, Map<String, dynamic> block, TextStyle base) {
    final type = block['type'] as String?;
    switch (type) {
      case 'paragraph':
      case 'heading':
        final children = block['children'];
        if (children is! List) return [const TextSpan(text: '')];
        final level = type == 'heading' ? (block['level'] as int? ?? 1) : null;
        final style = level != null
            ? base.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: (base.fontSize ?? 16) + (4 - level.clamp(1, 3)) * 2,
              )
            : base;
        final inline = <InlineSpan>[];
        for (final child in children) {
          if (child is Map<String, dynamic>) {
            inline.addAll(_buildInlineSpans(context, child, style));
          }
        }
        return inline;
      default:
        return [const TextSpan(text: '')];
    }
  }

  List<InlineSpan> _buildInlineSpans(BuildContext context, Map<String, dynamic> node, TextStyle base) {
    final type = node['type'] as String?;
    final colors = Theme.of(context).colorScheme;

    switch (type) {
      case 'text':
        final text = node['text'] as String? ?? '';
        return [TextSpan(text: text, style: base)];
      case 'hard_break':
        return [const TextSpan(text: ' ')];
      case 'code':
        final text = node['text'] as String? ?? '';
        return [
          TextSpan(
            text: text,
            style: base.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const ['monospace'],
              backgroundColor: colors.surfaceContainerHighest,
            ),
          ),
        ];
      case 'strong':
        return _wrapChildren(context, node, base.copyWith(fontWeight: FontWeight.w700));
      case 'em':
        return _wrapChildren(context, node, base.copyWith(fontStyle: FontStyle.italic));
      case 'underline':
        return _wrapChildren(context, node, base.copyWith(decoration: TextDecoration.underline));
      case 'strikethrough':
        return _wrapChildren(context, node, base.copyWith(decoration: TextDecoration.lineThrough));
      case 'highlight':
        return _wrapChildren(
          context,
          node,
          base.copyWith(backgroundColor: colors.tertiaryContainer.withAlpha((0.5 * 255).round())),
        );
      case 'external_link':
        final url = node['url'] as String? ?? '';
        final children = node['children'];
        final labelSpans = <InlineSpan>[];
        if (children is List) {
          for (final child in children) {
            if (child is Map<String, dynamic>) {
              labelSpans.addAll(_buildInlineSpans(context, child, base));
            }
          }
        }
        return [
          TextSpan(
            children: labelSpans.isNotEmpty ? labelSpans : [TextSpan(text: url, style: base)],
            style: base.copyWith(
              color: colors.primary,
              decoration: TextDecoration.underline,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () {
                if (url.isNotEmpty) {
                  onExternalLinkTap?.call(url);
                }
              },
          ),
        ];
      case 'node_link':
        final linkId = node['link_id'] as String? ?? '';
        final target = linkId.split(':').first;
        final label = node['label'] as String? ?? target;
        final refType = node['ref_type'] as String? ?? 'node';
        final isClass = refType == 'class';
        return [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              button: true,
              label: 'Link to $label',
              child: GestureDetector(
                onTap: target.isNotEmpty ? () => onNodeLinkTap?.call(target) : null,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isClass ? colors.secondaryContainer : colors.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    label,
                    style: base.copyWith(
                      color: isClass ? colors.onSecondaryContainer : colors.onPrimaryContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ];
      case 'user_mention':
        final label = node['label'] as String? ?? '';
        return [TextSpan(text: '@$label', style: base.copyWith(color: colors.primary))];
      default:
        return _wrapChildren(context, node, base);
    }
  }

  List<InlineSpan> _wrapChildren(BuildContext context, Map<String, dynamic> node, TextStyle style) {
    final children = node['children'];
    final spans = <InlineSpan>[];
    if (children is List) {
      for (final child in children) {
        if (child is Map<String, dynamic>) {
          spans.addAll(_buildInlineSpans(context, child, style));
        }
      }
    }
    return spans;
  }
}
