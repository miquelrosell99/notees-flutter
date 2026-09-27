import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/ast_stringifier.dart';
import '../../../core/utils/color_presets.dart';

/// Renders a Notees block content document (the v2 flat token stream,
/// serialized to JSON in the node `name` slot) as styled rich text.
///
/// Legacy v1 nested AST documents are converted on the fly
/// ([normalizeContentAst]), so rows written before the port render through
/// the same path. Resolution rules (mirroring the GTK renderer):
///
///  - `mention`: [resolveName]'s current target name wins (auto-rename
///    free), then the raw target id — the captured `text` is
///    non-authoritative; `displayText` overrides both;
///  - `class_chip`: render-only — `displayText` ?? resolved class name ??
///    raw class id; chips never mutate class assignments;
///  - `typed_link`: the marked word renders underlined with the verb (free
///    string or property-schema binding) carried in semantics;
///  - block-scale tokens (`asset_ref`/`embed_ref`/`query`/`whiteboard`)
///    render as labeled placeholders until the mobile client grows real
///    views.
class AstRichText extends StatelessWidget {
  const AstRichText({
    super.key,
    required this.source,
    this.onNodeLinkTap,
    this.onNodeLinkLongPress,
    this.onExternalLinkTap,
    this.resolveName,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.ellipsis,
    this.linkColors,
  });

  /// JSON-encoded content document (the `node.name` value) or an
  /// already-decoded token list.
  final dynamic source;

  /// Called when the user taps a mention/class chip. Receives the target id.
  final ValueChanged<String>? onNodeLinkTap;

  /// Called when the user long-presses a chip. Receives the raw target id
  /// and the rendered label so the parent editor can show a context menu.
  final void Function(String linkId, String label)? onNodeLinkLongPress;

  /// Called when the user taps an external link. Receives the URL.
  final ValueChanged<String>? onExternalLinkTap;

  /// Resolves a mention target / class id to its current display name.
  /// Return null (or leave unset) to fall back to the raw id.
  final String? Function(String id)? resolveName;

  /// Base text style. Defaults to the ambient body style.
  final TextStyle? style;

  final int? maxLines;
  final TextOverflow overflow;

  /// Data colors for link targets (node/class uuid → color), resolved from
  /// the page tree and the workspace's classes. When a target has a color,
  /// its chip fills with it (mirrors the web app's pills).
  final Map<String, Color>? linkColors;

  @override
  Widget build(BuildContext context) {
    final defaultStyle = style ?? DefaultTextStyle.of(context).style;
    final tokens = contentTokensFromSource(source);
    if (tokens.isEmpty) {
      return RichText(
        maxLines: maxLines,
        overflow: overflow,
        text: TextSpan(style: defaultStyle, text: ''),
      );
    }
    final spans = _buildTokenSpans(context, tokens, defaultStyle);
    return RichText(
      maxLines: maxLines,
      overflow: overflow,
      text: TextSpan(style: defaultStyle, children: spans),
    );
  }

  List<InlineSpan> _buildTokenSpans(
    BuildContext context,
    List<Map<String, dynamic>> tokens,
    TextStyle base,
  ) {
    final spans = <InlineSpan>[];
    for (final token in tokens) {
      spans.addAll(_buildTokenSpan(context, token, base));
    }
    return spans;
  }

  List<InlineSpan> _buildTokenSpan(
    BuildContext context,
    Map<String, dynamic> token,
    TextStyle base,
  ) {
    final colors = Theme.of(context).colorScheme;
    switch (token['type']) {
      case 'text':
        return [
          TextSpan(
            text: token['text'] as String? ?? '',
            style: _applyMarks(
              base,
              ((token['marks'] as List<dynamic>?) ?? const []).cast<String>(),
              colors,
            ),
          ),
        ];
      case 'hard_break':
        // Shift+enter line jump flushes the rendered line.
        return const [TextSpan(text: '\n')];
      case 'typed_link':
        return [
          TextSpan(
            text: token['text'] as String? ?? '',
            style: base.copyWith(
              decoration: TextDecoration.underline,
              decorationColor: colors.tertiary,
              color: colors.tertiary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ];
      case 'mention':
        final target = token['targetNodeId'] as String? ?? '';
        final label = token['displayText'] as String? ?? _resolve(target);
        return [
          _chipSpan(
            context,
            base: base,
            label: label,
            targetId: target,
            fill: linkColors?[target] ?? colors.primaryContainer,
            foreground: linkColors?[target] != null
                ? ColorPresets.foregroundFor(linkColors![target]!)
                : colors.onPrimaryContainer,
          ),
        ];
      case 'class_chip':
        final classId = token['classId'] as String? ?? '';
        final label = token['displayText'] as String? ?? _resolve(classId);
        return [
          _chipSpan(
            context,
            base: base,
            label: label,
            targetId: classId,
            fill: linkColors?[classId] ?? colors.secondaryContainer,
            foreground: linkColors?[classId] != null
                ? ColorPresets.foregroundFor(linkColors![classId]!)
                : colors.onSecondaryContainer,
          ),
        ];
      case 'external_link':
        final href = token['href'] as String? ?? '';
        final text = token['text'] as String? ?? href;
        return [
          TextSpan(
            text: text,
            style: base.copyWith(
              color: colors.primary,
              decoration: TextDecoration.underline,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () {
                if (href.isNotEmpty) onExternalLinkTap?.call(href);
              },
          ),
        ];
      case 'math':
        return [
          TextSpan(
            text: token['expression'] as String? ?? '',
            style: _monospace(base, colors),
          ),
        ];
      case 'quote':
        final children = <InlineSpan>[];
        for (final child
            in (token['children'] as List<dynamic>? ?? const <dynamic>[])) {
          if (child is Map<String, dynamic>) {
            children.addAll(_buildTokenSpan(context, child, base));
          }
        }
        return [
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: colors.outlineVariant, width: 3),
                ),
              ),
              padding: const EdgeInsets.only(left: 8),
              child: RichText(
                text: TextSpan(style: base, children: children),
              ),
            ),
          ),
        ];
      case 'asset_ref':
        return [_placeholderSpan(context, base, colors, 'asset', '📎')];
      case 'embed_ref':
        return [_placeholderSpan(context, base, colors, 'embed', '▶')];
      case 'query':
        return [_placeholderSpan(context, base, colors, 'query', '🔎')];
      case 'whiteboard':
        return [_placeholderSpan(context, base, colors, 'whiteboard', '🖼')];
      default:
        return [
          TextSpan(
            text: token['text'] is String ? token['text'] as String : '',
            style: base,
          ),
        ];
    }
  }

  String _resolve(String id) {
    if (id.isEmpty) return id;
    final resolver = resolveName;
    if (resolver == null) return id;
    try {
      return resolver(id) ?? id;
    } catch (_) {
      return id;
    }
  }

  InlineSpan _chipSpan(
    BuildContext context, {
    required TextStyle base,
    required String label,
    required String targetId,
    required Color fill,
    required Color foreground,
  }) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Semantics(
        button: true,
        label: 'Link to $label',
        child: GestureDetector(
          onTap:
              targetId.isNotEmpty ? () => onNodeLinkTap?.call(targetId) : null,
          onLongPress: targetId.isNotEmpty
              ? () => onNodeLinkLongPress?.call(targetId, label)
              : null,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style: base.copyWith(
                color: foreground,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  InlineSpan _placeholderSpan(
    BuildContext context,
    TextStyle base,
    ColorScheme colors,
    String kind,
    String emoji,
  ) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '$emoji ${kind[0].toUpperCase()}${kind.substring(1)}',
          style: base.copyWith(color: colors.onSurfaceVariant),
        ),
      ),
    );
  }

  TextStyle _applyMarks(TextStyle base, List<String> marks, ColorScheme colors) {
    var style = base;
    if (marks.contains('code')) {
      style = _monospace(style, colors);
    }
    if (marks.contains('bold')) {
      style = style.copyWith(fontWeight: FontWeight.w700);
    }
    if (marks.contains('italic')) {
      style = style.copyWith(fontStyle: FontStyle.italic);
    }
    final decorations = <TextDecoration>[
      if (style.decoration != null && style.decoration != TextDecoration.none)
        style.decoration!,
      if (marks.contains('strike')) TextDecoration.lineThrough,
    ];
    if (marks.contains('highlight')) {
      style = style.copyWith(
        backgroundColor: colors.tertiaryContainer.withAlpha(
          (0.5 * 255).round(),
        ),
      );
    }
    return style.copyWith(
      decoration: decorations.isEmpty
          ? null
          : TextDecoration.combine(decorations),
    );
  }

  TextStyle _monospace(TextStyle base, ColorScheme colors) => base.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const ['monospace'],
        backgroundColor: colors.surfaceContainerHighest,
      );
}
