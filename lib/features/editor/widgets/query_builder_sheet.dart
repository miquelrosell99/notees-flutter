import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../data/models/node.dart';
import '../../../domain/query/builder_facts.dart';
import '../../../domain/query/query_ast.dart';
import '../../../domain/query/query_filter_model.dart';
import '../../../domain/query/query_filter_query.dart';
import '../../../shared/widgets/bottom_sheet_drag_handle.dart';
import '../../../shared/widgets/node_picker.dart';

/// The node-pick seam the builder's value controls ride (the production
/// implementation opens the fleet [NodePicker]; tests inject a fake).
typedef QueryNodePicker = Future<Node?> Function(NodePickerMode mode);

/// The mobile port of the web's `FilterBlockBuilder` +
/// `filterBlockValueControls.tsx` — the structured query-builder over the
/// v2 draft AST, adapted to the mobile idioms (bottom sheet + chips per the
/// repo's design system, NOT a pixel port of the web's flat column rows).
///
/// The builder edits a DRAFT root group ([FilterQuery.group]); Apply composes
/// it through the prune ([draftOrFactoryAst]) and pops the resulting
/// [QueryAst]. A blocks ⇄ JSON toggle rides the head row: the JSON mode is
/// the EXCHANGE format (the web's raw-AST arm) — it edits the WHOLE token
/// AST verbatim (scope/root/sort/aggregation), which doubles as the mobile
/// aggregation-authoring escape hatch (the full pivot-style aggregation
/// builder is deliberately out of scope; slice 3 already renders
/// aggregation ASTs, the JSON arm authors them).
///
/// The sheet never writes: the caller commits the popped AST through the
/// content-update op path (the web's `updateQueryTokenAst` /
/// `appendQueryToken` seam).
class QueryBuilderSheet extends StatefulWidget {
  const QueryBuilderSheet({
    super.key,
    required this.facts,
    required this.pickNode,
    this.initialAst,
    this.selfNodeId,
  });

  /// The picker-source facts (classes + bound properties) the rows render.
  final BuilderFacts facts;

  /// The node-pick seam (value controls + target picks).
  final QueryNodePicker pickNode;

  /// The token's current AST (null/unspecified = a fresh builder session
  /// over an empty draft).
  final QueryAst? initialAst;

  /// The hosting page's id — the SELF target mode's anchor (null = the Self
  /// mode is not offered, the web's host-less ruling).
  final String? selfNodeId;

  static Future<QueryAst?> show(
    BuildContext context, {
    required BuilderFacts facts,
    required QueryNodePicker pickNode,
    QueryAst? initialAst,
    String? selfNodeId,
  }) {
    return showModalBottomSheet<QueryAst>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => QueryBuilderSheet(
        facts: facts,
        pickNode: pickNode,
        initialAst: initialAst,
        selfNodeId: selfNodeId,
      ),
    );
  }

  @override
  State<QueryBuilderSheet> createState() => _QueryBuilderSheetState();
}

class _QueryBuilderSheetState extends State<QueryBuilderSheet> {
  late FilterQuery _draft;
  String _view = 'blocks';
  final _rawController = TextEditingController();
  String? _rawError;

  /// The display labels the session picked (arbitrary nodes carry no fact
  /// entry; the web resolves via the client, the sheet caches its picks —
  /// unknown ids render their raw id, the honest broken-ref pill).
  final Map<String, String> _pickedLabels = {};

  @override
  void initState() {
    super.initState();
    final initial = widget.initialAst;
    _draft = FilterQuery(
      group: initial?.root ?? const Group(logic: 'and', children: []),
    );
    _rawController.text = const JsonEncoder.withIndent('  ').convert(
          (initial ?? factoryQueryAst).toJson(),
        );
  }

  @override
  void dispose() {
    _rawController.dispose();
    super.dispose();
  }

  void _apply() {
    if (_view == 'raw') {
      Object? parsed;
      try {
        parsed = jsonDecode(_rawController.text);
      } catch (e) {
        setState(() => _rawError = 'Invalid JSON — $e');
        return;
      }
      try {
        Navigator.of(context).pop(QueryAst.parse(parsed));
      } catch (e) {
        setState(() => _rawError = 'Not a query AST — $e');
      }
      return;
    }
    Navigator.of(context).pop(draftOrFactoryAst(_draft));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              const BottomSheetDragHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Query builder',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // The head row carries BOTH switches (the web's
                    // nt-fb__head): the root Match ALL/ANY logic toggle and
                    // the blocks ⇄ JSON exchange toggle.
                    _LogicToggle(
                      logic: _draft.group.logic,
                      onChanged: (logic) => setState(
                        () => _draft = FilterQuery(
                          group: Group(
                            logic: logic,
                            children: _draft.group.children,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: const [
                        ButtonSegment(
                          value: 'blocks',
                          label: Text('Blocks'),
                          icon: Icon(Icons.toys_outlined, size: 16),
                        ),
                        ButtonSegment(
                          value: 'raw',
                          label: Text('JSON'),
                          icon: Icon(Icons.code, size: 16),
                        ),
                      ],
                      selected: {_view},
                      onSelectionChanged: (selection) => setState(
                        () => _view = selection.first,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _view == 'raw'
                    ? _buildRawMode(colors)
                    : SingleChildScrollView(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                        child: _GroupEditor(
                          group: _draft.group,
                          onChanged: (group) => setState(
                            () => _draft = FilterQuery(group: group),
                          ),
                          facts: widget.facts,
                          pickedLabels: _pickedLabels,
                          pickNode: widget.pickNode,
                          selfNodeId: widget.selfNodeId,
                          isRoot: true,
                        ),
                      ),
              ),
              _buildFooter(colors),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRawMode(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Query AST (JSON) — the whole token payload: scope, root, sort, '
            'aggregation.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _rawController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(12),
              ),
              onChanged: (_) => setState(() => _rawError = null),
            ),
          ),
          if (_rawError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _rawError!,
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFooter(ColorScheme colors) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (_view == 'blocks')
              TextButton(
                onPressed: () => setState(
                  () => _draft = FilterQuery(
                    group: const Group(logic: 'and', children: []),
                  ),
                ),
                child: const Text('Clear'),
              ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _apply,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }
}

// --- the group editor ------------------------------------------------------------

class _GroupEditor extends StatelessWidget {
  const _GroupEditor({
    required this.group,
    required this.onChanged,
    required this.facts,
    required this.pickedLabels,
    required this.pickNode,
    this.selfNodeId,
    this.onDelete,
    this.depth = 0,
    this.isRoot = false,
  });

  final Group group;
  final ValueChanged<Group> onChanged;
  final BuilderFacts facts;
  final Map<String, String> pickedLabels;
  final QueryNodePicker pickNode;
  final String? selfNodeId;
  final VoidCallback? onDelete;
  final int depth;

  /// The root level renders its logic toggle in the sheet's head row
  /// (here: a plain column, no header chrome), matching the web's bare root.
  final bool isRoot;

  void _patch({String? logic, List<QueryAstChild>? children}) => onChanged(
        Group(logic: logic ?? group.logic, children: children ?? group.children),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final borderSide = BorderSide(
      color: colors.outline.withAlpha((0.2 * 255).round()),
    );

    final children = <Widget>[
      for (var index = 0; index < group.children.length; index++)
        _buildChild(context, index, colors, borderSide),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isRoot) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              _LogicToggle(
                logic: group.logic,
                onChanged: (logic) => _patch(logic: logic),
              ),
              const SizedBox(width: 8),
              Text(
                group.children.isEmpty
                    ? 'Empty group'
                    : '${group.children.length} condition${group.children.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Remove group',
                onPressed: onDelete,
              ),
            ],
          ),
        ],
        Container(
          decoration: isRoot
              ? null
              : BoxDecoration(
                  border: Border(left: BorderSide(color: colors.outlineVariant)),
                ),
          padding: EdgeInsets.only(left: isRoot ? 0 : 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final child in children) ...[
                child,
                const SizedBox(height: 8),
              ],
              _AddConditionButton(
                onAdd: (entry) => onChanged(withAddedEntry(group, entry)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChild(
    BuildContext context,
    int index,
    ColorScheme colors,
    BorderSide borderSide,
  ) {
    final child = group.children[index];
    void replace(QueryAstChild next) => _patch(
          children: [
            for (var i = 0; i < group.children.length; i++)
              i == index ? next : group.children[i],
          ],
        );
    void delete() => _patch(
          children: [
            for (var i = 0; i < group.children.length; i++)
              if (i != index) group.children[i],
          ],
        );

    if (child is Group) {
      return _GroupEditor(
        group: child,
        onChanged: replace,
        facts: facts,
        pickedLabels: pickedLabels,
        pickNode: pickNode,
        selfNodeId: selfNodeId,
        onDelete: delete,
        depth: depth + 1,
      );
    }
    if (child is Not && child.child is Group) {
      return _NotGroupEditor(
        not: child,
        onChanged: (next) => replace(next),
        onDelete: delete,
        facts: facts,
        pickedLabels: pickedLabels,
        pickNode: pickNode,
        selfNodeId: selfNodeId,
        depth: depth + 1,
      );
    }
    return _ConditionRow(
      child: child,
      onChanged: replace,
      onDelete: delete,
      facts: facts,
      pickedLabels: pickedLabels,
      pickNode: pickNode,
      selfNodeId: selfNodeId,
    );
  }
}

class _NotGroupEditor extends StatelessWidget {
  const _NotGroupEditor({
    required this.not,
    required this.onChanged,
    required this.onDelete,
    required this.facts,
    required this.pickedLabels,
    required this.pickNode,
    required this.depth,
    this.selfNodeId,
  });

  final Not not;
  final ValueChanged<Not> onChanged;
  final VoidCallback onDelete;
  final BuilderFacts facts;
  final Map<String, String> pickedLabels;
  final QueryNodePicker pickNode;
  final String? selfNodeId;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final child = not.child;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: colors.error.withAlpha((0.12 * 255).round()),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'NOT',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.error,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: child is Group
              ? _GroupEditor(
                  group: child,
                  onChanged: (group) => onChanged(Not(child: group)),
                  facts: facts,
                  pickedLabels: pickedLabels,
                  pickNode: pickNode,
                  selfNodeId: selfNodeId,
                  onDelete: onDelete,
                  depth: depth,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

// --- the condition row -------------------------------------------------------------

class _ConditionRow extends StatefulWidget {
  const _ConditionRow({
    required this.child,
    required this.onChanged,
    required this.onDelete,
    required this.facts,
    required this.pickedLabels,
    required this.pickNode,
    this.selfNodeId,
  });

  final QueryAstChild child;
  final ValueChanged<QueryAstChild> onChanged;
  final VoidCallback onDelete;
  final BuilderFacts facts;
  final Map<String, String> pickedLabels;
  final QueryNodePicker pickNode;
  final String? selfNodeId;

  @override
  State<_ConditionRow> createState() => _ConditionRowState();
}

class _ConditionRowState extends State<_ConditionRow> {
  late final TextEditingController _textController;
  late final TextEditingController _fromController;
  late final TextEditingController _toController;
  late final TextEditingController _timestampController;

  @override
  void initState() {
    super.initState();
    final view = blockView(widget.child);
    final condition = view?.condition;
    _textController = TextEditingController(
      text: switch (condition) {
        ContentCondition() => condition.value ?? '',
        NameCondition() => condition.value ?? '',
        PropertyCondition() => condition.value?.toString() ?? '',
        _ => '',
      },
    );
    _fromController = TextEditingController(
      text: switch (condition) {
        PropertyCondition() => condition.from?.toString() ?? '',
        DateCondition() => condition.from ?? '',
        _ => '',
      },
    );
    _toController = TextEditingController(
      text: switch (condition) {
        PropertyCondition() => condition.to?.toString() ?? '',
        DateCondition() => condition.to ?? '',
        _ => '',
      },
    );
    _timestampController = TextEditingController(
      text: condition is DateCondition ? condition.timestamp ?? '' : '',
    );
  }

  @override
  void didUpdateWidget(_ConditionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Echo guard: only overwrite the controller when the model moved
    // underneath (a different row's edit), never on this row's own keystroke.
    final condition = blockView(widget.child)?.condition;
    final text = switch (condition) {
      ContentCondition() => condition.value ?? '',
      NameCondition() => condition.value ?? '',
      PropertyCondition() => condition.value?.toString() ?? '',
      _ => null,
    };
    if (text != null && text != _textController.text) {
      _textController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _fromController.dispose();
    _toController.dispose();
    _timestampController.dispose();
    super.dispose();
  }

  void _replaceCondition(Condition next) {
    final view = blockView(widget.child);
    widget.onChanged(view?.negated == true ? Not(child: next) : next);
  }

  void _replaceChild(QueryAstChild next) => widget.onChanged(next);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final view = blockView(widget.child);
    if (view == null) return const SizedBox.shrink();
    final condition = view.condition;
    final family = familyOf(condition);
    final label = familyLabels[family] ?? family;
    final operatorOpts = operatorOptions(family, condition, widget.facts);
    final memberFamily = condition is MemberCondition &&
            family != ConditionKinds.type &&
            family != ConditionKinds.placement
        ? condition.family
        : null;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: colors.outline.withAlpha((0.2 * 255).round()),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (family == ConditionKinds.property)
                Expanded(
                  child: _PropertySchemaPick(
                    condition: condition as PropertyCondition,
                    facts: widget.facts,
                    onChanged: _replaceCondition,
                  ),
                )
              else
                Flexible(
                  child: Text(
                    view.negated ? 'NOT $label' : label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (operatorOpts.isNotEmpty) ...[
                const SizedBox(width: 8),
                _OperatorDropdown(
                  options: operatorOpts,
                  value: operatorOf(condition, view.negated),
                  onChanged: (op) => _replaceChild(applyOperator(condition, op)),
                ),
              ],
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Remove condition',
                onPressed: widget.onDelete,
              ),
            ],
          ),
          _ConditionValue(
            condition: condition,
            negated: view.negated,
            family: family,
            facts: widget.facts,
            pickedLabels: widget.pickedLabels,
            pickNode: widget.pickNode,
            textController: _textController,
            fromController: _fromController,
            toController: _toController,
            timestampController: _timestampController,
            onReplaceCondition: _replaceCondition,
          ),
          if (memberFamily != null) ...[
            const SizedBox(height: 4),
            _MemberModeSwitch(
              condition: condition as MemberCondition,
              selfNodeId: widget.selfNodeId,
              onChanged: _replaceChild,
            ),
            if (_memberMode(condition) == 'query')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _GroupEditor(
                  group: (condition.target as QueryTarget).root,
                  onChanged: (group) => _replaceChild(
                    MemberCondition(
                      family: condition.family,
                      op: condition.op,
                      target: QueryTarget(root: group),
                    ),
                  ),
                  facts: widget.facts,
                  pickedLabels: widget.pickedLabels,
                  pickNode: widget.pickNode,
                  selfNodeId: widget.selfNodeId,
                  depth: 1,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

String _memberMode(MemberCondition condition) {
  final target = condition.target;
  if (condition.op == 'in' ||
      condition.op == 'not-in' ||
      condition.op == 'exact') {
    if (target is QueryTarget) return 'query';
    if (target is SelfTarget) return 'self';
  }
  return 'manual';
}

class _MemberModeSwitch extends StatelessWidget {
  const _MemberModeSwitch({
    required this.condition,
    required this.onChanged,
    this.selfNodeId,
  });

  final MemberCondition condition;
  final ValueChanged<QueryAstChild> onChanged;
  final String? selfNodeId;

  @override
  Widget build(BuildContext context) {
    final mode = _memberMode(condition);
    final chips = <Widget>[
      ChoiceChip(
        label: const Text('Manual'),
        selected: mode == 'manual',
        visualDensity: VisualDensity.compact,
        onSelected: (_) => _switchTo('manual'),
      ),
      ChoiceChip(
        label: const Text('Query'),
        selected: mode == 'query',
        visualDensity: VisualDensity.compact,
        onSelected: (_) => _switchTo('query'),
      ),
      // The Self mode needs a hosting page to resolve against; a row already
      // IN Self mode keeps its option even host-less (the chip must show
      // its value).
      if (selfNodeId != null || mode == 'self')
        ChoiceChip(
          label: const Text('Self'),
          selected: mode == 'self',
          visualDensity: VisualDensity.compact,
          onSelected: (_) => _switchTo('self'),
        ),
    ];
    return Wrap(spacing: 8, runSpacing: 4, children: chips);
  }

  void _switchTo(String nextMode) {
    // The mode switch rebuilds ONLY the target — the operator (in / not-in)
    // survives the mode change verbatim. A set row (no target) first
    // re-materializes a membership op, preserving its polarity; the current
    // ids carry into Manual where the row had them.
    final carriedIds = condition.target is IdsTarget
        ? (condition.target! as IdsTarget).ids
        : const <String>[];
    final inOp =
        condition.op == 'not-in' || condition.op == 'not-exists' ? 'not-in' : 'in';
    final next = switch (nextMode) {
      'query' => MemberCondition(
          family: condition.family,
          op: inOp,
          target: const QueryTarget(root: Group(logic: 'and', children: [])),
        ),
      'self' => MemberCondition(
          family: condition.family,
          op: inOp,
          target: const SelfTarget(),
        ),
      _ => MemberCondition(
          family: condition.family,
          op: inOp,
          target: IdsTarget(ids: [...carriedIds]),
        ),
    };
    onChanged(next);
  }
}

// --- the shared small controls -------------------------------------------------------

class _LogicToggle extends StatelessWidget {
  const _LogicToggle({required this.logic, required this.onChanged});

  final String logic;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      segments: const [
        ButtonSegment(value: 'and', label: Text('ALL')),
        ButtonSegment(value: 'or', label: Text('ANY')),
      ],
      selected: {logic},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

class _OperatorDropdown extends StatelessWidget {
  const _OperatorDropdown({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<OperatorOption> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: options.any((option) => option.value == value) ? value : null,
        hint: const Text('Operator'),
        isDense: true,
        borderRadius: BorderRadius.circular(12),
        items: [
          for (final option in options)
            DropdownMenuItem(value: option.value, child: Text(option.label)),
        ],
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    );
  }
}

class _PropertySchemaPick extends StatelessWidget {
  const _PropertySchemaPick({
    required this.condition,
    required this.facts,
    required this.onChanged,
  });

  final PropertyCondition condition;
  final BuilderFacts facts;
  final ValueChanged<PropertyCondition> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: condition.schemaId.isEmpty ? '' : condition.schemaId,
        isExpanded: true,
        isDense: true,
        hint: const Text('Pick a property'),
        borderRadius: BorderRadius.circular(12),
        items: [
          const DropdownMenuItem(value: '', child: Text('Pick a property')),
          for (final property in facts.boundProperties)
            DropdownMenuItem(value: property.id, child: Text(property.name)),
        ],
        onChanged: (value) {
          if (value == null) return;
          // Picking a different property resets the value (it was typed for
          // the old type). A boolean schema seeds the truth value — the
          // register ruling: the value column IS the predicate, so a freshly
          // picked boolean property reads "is true", never a blank value.
          final schema = facts.propertyById(value);
          onChanged(
            PropertyCondition(
              schemaId: value,
              op: 'eq',
              value: schema?.type == 'boolean' ? true : '',
            ),
          );
        },
      ),
    );
  }
}

class _AddConditionButton extends StatelessWidget {
  const _AddConditionButton({required this.onAdd});

  final ValueChanged<String> onAdd;

  Future<void> _openMenu(BuildContext context) async {
    final theme = Theme.of(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => SafeArea(
        // Eager (non-lazy) column: the register is small and every entry
        // must exist for finders and a11y, whatever the viewport height.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in filterKindOptions)
                ListTile(
                  dense: true,
                  leading: Icon(_iconFor(option.icon), size: 20),
                  title: Text(option.label),
                  subtitle: Text(
                    option.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  onTap: () => Navigator.of(context).pop(option.value),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onAdd(picked);
  }

  /// The mdi names ride as data; the sheet maps the register's icons to
  /// glyphs where a natural MdiIcons member exists and falls back to a
  /// generic filter glyph (the register data stays web-faithful).
  static IconData _iconFor(String mdi) => switch (mdi) {
        'mdi mdi-tag-outline' => MdiIcons.tagOutline,
        'mdi mdi-shape-outline' => MdiIcons.shapeOutline,
        'mdi mdi-format-align-left' => MdiIcons.formatAlignLeft,
        'mdi mdi-text-box-outline' => MdiIcons.textBoxOutline,
        'mdi mdi-code-braces' => MdiIcons.codeBraces,
        'mdi mdi-tag-multiple-outline' => MdiIcons.tagMultipleOutline,
        'mdi mdi-link-variant' => MdiIcons.linkVariant,
        'mdi mdi-link-plus' => MdiIcons.linkPlus,
        'mdi mdi-file-tree-outline' => MdiIcons.fileTreeOutline,
        'mdi mdi-file-tree' => MdiIcons.fileTree,
        'mdi mdi-arrow-decision-outline' => MdiIcons.arrowDecisionOutline,
        'mdi mdi-page-layout-body' => MdiIcons.pageLayoutBody,
        'mdi mdi-source-branch' => MdiIcons.sourceBranch,
        'mdi mdi-arrow-collapse-up' => MdiIcons.arrowCollapseUp,
        'mdi mdi-image-outline' => MdiIcons.imageOutline,
        'mdi mdi-page-layout-header' => MdiIcons.pageLayoutHeader,
        'mdi mdi-repeat-variant' => MdiIcons.repeatVariant,
        'mdi mdi-calendar-arrow-right' => MdiIcons.calendarArrowRight,
        'mdi mdi-calendar-edit' => MdiIcons.calendarEdit,
        'mdi mdi-set-all' => MdiIcons.setAll,
        'mdi mdi-set-center' => MdiIcons.setCenter,
        'mdi mdi-cancel' => MdiIcons.cancel,
        _ => MdiIcons.filterVariant,
      };

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => _openMenu(context),
      icon: const Icon(Icons.add, size: 18),
      label: const Text('Add condition'),
    );
  }
}

// --- the per-family value controls ------------------------------------------------

class _ConditionValue extends StatelessWidget {
  const _ConditionValue({
    required this.condition,
    required this.negated,
    required this.family,
    required this.facts,
    required this.pickedLabels,
    required this.pickNode,
    required this.textController,
    required this.fromController,
    required this.toController,
    required this.timestampController,
    required this.onReplaceCondition,
  });

  final Condition condition;
  final bool negated;
  final String family;
  final BuilderFacts facts;
  final Map<String, String> pickedLabels;
  final QueryNodePicker pickNode;
  final TextEditingController textController;
  final TextEditingController fromController;
  final TextEditingController toController;
  final TextEditingController timestampController;
  final ValueChanged<Condition> onReplaceCondition;

  @override
  Widget build(BuildContext context) {
    final condition = this.condition;
    switch (condition) {
      case MemberCondition():
        final target = condition.target;
        if (condition.op == 'exists' || condition.op == 'not-exists') {
          return const SizedBox.shrink();
        }
        if (target is QueryTarget) {
          return _ValueHint(text: 'matching', icon: MdiIcons.filterVariant);
        }
        if (target is SelfTarget) {
          return _ValueHint(text: 'this page', icon: MdiIcons.crosshairs);
        }
        final ids = (target as IdsTarget).ids;
        final single = family == 'parent' ||
            family == 'page' ||
            family == 'root' ||
            condition.op == 'exact';
        return _IdPicks(
          ids: ids,
          single: single,
          addLabel: switch (family) {
            'class' => 'Add class',
            'tags' => 'Add tag',
            'parent' => 'Add parent',
            'page' => 'Add page',
            'root' => 'Add root',
            'child' => 'Add child',
            _ => 'Add node',
          },
          classesOnly: family == 'class',
          labels: pickedLabels,
          classNames: facts.classNames,
          pickNode: pickNode,
          onChanged: (next) => onReplaceCondition(
            MemberCondition(
              family: condition.family,
              op: condition.op,
              target: IdsTarget(ids: next),
            ),
          ),
        );
      case ContentCondition():
      case NameCondition():
        final nameRow = condition is NameCondition;
        final textOp = nameRow
            ? condition.op
            : (condition as ContentCondition).op;
        return TextField(
          controller: textController,
          decoration: InputDecoration(
            isDense: true,
            hintText: nameRow ? 'Title' : 'Text',
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
          ),
          onChanged: (value) => onReplaceCondition(
            nameRow
                ? NameCondition(op: textOp, value: value)
                : ContentCondition(op: textOp, value: value),
          ),
        );
      case PropertyCondition():
        return _PropertyValue(
          condition: condition,
          facts: facts,
          pickedLabels: pickedLabels,
          pickNode: pickNode,
          textController: textController,
          fromController: fromController,
          toController: toController,
          onReplaceCondition: onReplaceCondition,
        );
      case DateCondition():
        if (condition.op == 'between') {
          return Row(
            children: [
              Expanded(
                child: _SmallField(
                  controller: fromController,
                  hint: 'from {today}',
                  onChanged: (value) => onReplaceCondition(
                    DateCondition(
                      field: condition.field,
                      op: 'between',
                      from: value,
                      to: condition.to,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SmallField(
                  controller: toController,
                  hint: 'to {today}',
                  onChanged: (value) => onReplaceCondition(
                    DateCondition(
                      field: condition.field,
                      op: 'between',
                      from: condition.from,
                      to: value,
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        if (condition.op == 'within') {
          return _PeriodPick(
            value: condition.period ?? 'today',
            onChanged: (period) => onReplaceCondition(
              DateCondition(field: condition.field, op: 'within', period: period),
            ),
          );
        }
        return _SmallField(
          controller: timestampController,
          hint: '{today} or 2026-10-04',
          onChanged: (value) => onReplaceCondition(
            DateCondition(field: condition.field, op: condition.op, timestamp: value),
          ),
        );
      case NodeFieldCondition():
        if (condition.field == 'isClass') {
          return _ValueDropdown(
            value: condition.value ?? 'true',
            aria: 'Type',
            options: const [
              (value: 'true', label: 'A class'),
              (value: 'false', label: 'Not a class'),
            ],
            onChanged: (value) => onReplaceCondition(
              NodeFieldCondition(field: condition.field, op: condition.op, value: value),
            ),
          );
        }
        if (condition.field == 'isEmbedded') {
          return _ValueDropdown(
            value: condition.value ?? 'false',
            aria: 'Structural role',
            options: const [
              (value: 'true', label: 'Block (embedded in body)'),
              (value: 'false', label: 'Page (standalone)'),
            ],
            onChanged: (value) => onReplaceCondition(
              NodeFieldCondition(field: condition.field, op: condition.op, value: value),
            ),
          );
        }
        // coverAsset / bannerAsset / aliasedNode — the operator IS the
        // condition; no value control.
        return const SizedBox.shrink();
    }
  }
}

class _PropertyValue extends StatelessWidget {
  const _PropertyValue({
    required this.condition,
    required this.facts,
    required this.pickedLabels,
    required this.pickNode,
    required this.textController,
    required this.fromController,
    required this.toController,
    required this.onReplaceCondition,
  });

  final PropertyCondition condition;
  final BuilderFacts facts;
  final Map<String, String> pickedLabels;
  final QueryNodePicker pickNode;
  final TextEditingController textController;
  final TextEditingController fromController;
  final TextEditingController toController;
  final ValueChanged<Condition> onReplaceCondition;

  @override
  Widget build(BuildContext context) {
    if (condition.schemaId.isEmpty) {
      return const _ValueHint(
        text: 'Pick a property to set its operator and value',
        icon: Icons.code,
      );
    }
    final schema = facts.propertyById(condition.schemaId);
    final type = schema?.type ?? 'text';
    final numeric = type == 'number' || type == 'integer';
    final dateLike = type == 'datetime';
    final nodeTyped = type == 'object' || (schema?.targetClassFilter ?? []).isNotEmpty;

    final children = <Widget>[];
    if (condition.op == 'between') {
      children.add(
        Row(
          children: [
            Expanded(
              child: _SmallField(
                controller: fromController,
                hint: 'from',
                numeric: numeric,
                onChanged: (value) => onReplaceCondition(
                  PropertyCondition(
                    schemaId: condition.schemaId,
                    op: 'between',
                    from: numeric ? num.tryParse(value) ?? value : value,
                    to: condition.to,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SmallField(
                controller: toController,
                hint: 'to',
                numeric: numeric,
                onChanged: (value) => onReplaceCondition(
                  PropertyCondition(
                    schemaId: condition.schemaId,
                    op: 'between',
                    from: condition.from,
                    to: numeric ? num.tryParse(value) ?? value : value,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    } else if (condition.op == 'within') {
      children.add(
        _PeriodPick(
          value: condition.period ?? 'today',
          onChanged: (period) => onReplaceCondition(
            PropertyCondition(
              schemaId: condition.schemaId,
              op: 'within',
              period: period,
            ),
          ),
        ),
      );
    } else if (condition.op != 'exists' && type == 'select') {
      children.add(
        _ValueDropdown(
          value: condition.value is String ? condition.value! as String : '',
          aria: 'Value',
          placeholder: 'Pick an option',
          options: [
            for (final option in schema?.options ?? const <BuilderPropertyOption>[])
              (value: option.id, label: option.label),
          ],
          onChanged: (value) => onReplaceCondition(
            PropertyCondition(
              schemaId: condition.schemaId,
              op: condition.op,
              value: value,
            ),
          ),
        ),
      );
    } else if (type == 'boolean') {
      // The boolean value selector IS the predicate — live on the eq row
      // AND the set bits (picking true/false from an "is set" row
      // re-materializes the eq row: is-true ≡ is set + true).
      children.add(
        _ValueDropdown(
          value: condition.value is bool ? (condition.value! as bool).toString() : '',
          aria: 'Value',
          options: const [
            (value: 'true', label: 'True'),
            (value: 'false', label: 'False'),
          ],
          onChanged: (value) => onReplaceCondition(
            applyBooleanValue(condition, value == 'true'),
          ),
        ),
      );
    } else if (condition.op != 'exists' && nodeTyped) {
      children.add(
        _NodeValuePick(
          condition: condition,
          pickedLabels: pickedLabels,
          pickNode: pickNode,
          onReplaceCondition: onReplaceCondition,
        ),
      );
    } else if (condition.op != 'exists') {
      children.add(
        TextField(
          controller: textController,
          keyboardType: numeric ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(
            isDense: true,
            hintText: dateLike ? '{today} or 2026-10-04' : 'Value',
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
          ),
          onChanged: (value) => onReplaceCondition(
            PropertyCondition(
              schemaId: condition.schemaId,
              op: condition.op,
              value: numeric ? num.tryParse(value) ?? value : value,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final child in children) ...[
          child,
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _NodeValuePick extends StatelessWidget {
  const _NodeValuePick({
    required this.condition,
    required this.pickedLabels,
    required this.pickNode,
    required this.onReplaceCondition,
  });

  final PropertyCondition condition;
  final Map<String, String> pickedLabels;
  final QueryNodePicker pickNode;
  final ValueChanged<Condition> onReplaceCondition;

  String _nodeId() {
    final value = condition.value;
    if (value is Map && value['nodeId'] is String) return value['nodeId'] as String;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final nodeId = _nodeId();
    return OutlinedButton.icon(
      onPressed: () async {
        final node = await pickNode(NodePickerMode.any);
        if (node == null) return;
        pickedLabels[node.uuid] = node.displayName.isNotEmpty
            ? node.displayName
            : node.uuid;
        onReplaceCondition(
          PropertyCondition(
            schemaId: condition.schemaId,
            op: condition.op,
            value: {'nodeId': node.uuid},
          ),
        );
      },
      icon: const Icon(Icons.search, size: 16),
      label: Text(
        nodeId.isEmpty
            ? 'Pick a node…'
            : (pickedLabels[nodeId] ?? nodeId),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _IdPicks extends StatelessWidget {
  const _IdPicks({
    required this.ids,
    required this.single,
    required this.addLabel,
    required this.classesOnly,
    required this.labels,
    required this.classNames,
    required this.pickNode,
    required this.onChanged,
  });

  final List<String> ids;
  final bool single;
  final String addLabel;
  final bool classesOnly;
  final Map<String, String> labels;
  final Map<String, String> classNames;
  final QueryNodePicker pickNode;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final id in ids)
          InputChip(
            visualDensity: VisualDensity.compact,
            label: Text(labels[id] ?? classNames[id] ?? id),
            onDeleted: () => onChanged(ids.where((other) => other != id).toList()),
          ),
        // The single-slot register (parent/page/root, the class "is" arm):
        // the add chip hides while a value rides — clear via the pill's ×
        // first (no silent replace).
        if (!(single && ids.isNotEmpty))
          ActionChip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(Icons.add, size: 16, color: colors.primary),
            label: Text(addLabel),
            onPressed: () async {
              final node = await pickNode(
                classesOnly ? NodePickerMode.classNode : NodePickerMode.any,
              );
              if (node == null) return;
              labels[node.uuid] = node.displayName.isNotEmpty
                  ? node.displayName
                  : node.uuid;
              if (!ids.contains(node.uuid)) onChanged([...ids, node.uuid]);
            },
          ),
      ],
    );
  }
}

class _SmallField extends StatelessWidget {
  const _SmallField({
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.numeric = false,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final bool numeric;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      onChanged: onChanged,
    );
  }
}

class _ValueDropdown extends StatelessWidget {
  const _ValueDropdown({
    required this.value,
    required this.aria,
    required this.options,
    required this.onChanged,
    this.placeholder,
  });

  final String value;
  final String aria;
  final List<({String value, String label})> options;
  final ValueChanged<String> onChanged;
  final String? placeholder;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: options.any((option) => option.value == value) ? value : null,
        hint: Text(placeholder ?? aria),
        isDense: true,
        borderRadius: BorderRadius.circular(12),
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option.value,
              child: Text(option.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    );
  }
}

class _PeriodPick extends StatelessWidget {
  const _PeriodPick({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const periods = [
    (value: 'today', label: 'Today'),
    (value: 'this_week', label: 'This week'),
    (value: 'this_month', label: 'This month'),
    (value: 'this_year', label: 'This year'),
  ];

  @override
  Widget build(BuildContext context) {
    return _ValueDropdown(
      value: value,
      aria: 'Period',
      options: periods,
      onChanged: onChanged,
    );
  }
}

class _ValueHint extends StatelessWidget {
  const _ValueHint({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: colors.onSurfaceVariant),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
        ),
      ],
    );
  }
}
