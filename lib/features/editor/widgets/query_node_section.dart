import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../core/utils/ast_stringifier.dart';
import '../../../core/utils/node_display_name.dart';
import '../../../data/models/node.dart';
import '../../../domain/query/query_ast.dart';
import '../../../domain/query/query_placeholders.dart';
import '../../../domain/query/query_runner.dart';
import '../../../domain/services/query_service.dart';
import '../../../domain/services/store_change_bus.dart';

/// The `query` content token's live section — the mobile port of the web
/// `QueryNodeSection` + `useQueryRun` (`apps/web/src/ui/QueryNodeSection.tsx`,
/// `queryRun.ts`). The block stays a normal, typeable row marked by its
/// content; the FIRST `query` token in the block's content stream carries
/// the query AST as payload and this section renders the live results BELOW
/// the row:
///
///  - runs the token's AST through the local QueryService/compiler — local
///    execution only, no server reads, offline-correct;
///  - [selfNodeId] (the HOSTING PAGE's node id) is part of the run's
///    identity and rides CompileOptions as the `self` member-target anchor —
///    the compiler fails loud without a host, so the id must always be
///    threaded;
///  - coalesced live re-runs on store changes: a notification while a run is
///    in flight marks the section dirty and schedules exactly ONE trailing
///    run, so a burst costs at most two executions (the web's rule); the
///    last result caches between runs and deletions/renames converge
///    without a manual refresh;
///  - a run whose (astKey, version, selfNodeId) identity is already current
///    is skipped outright.
class QueryNodeSection extends StatefulWidget {
  const QueryNodeSection({
    super.key,
    required this.source,
    required this.selfNodeId,
    required this.queryService,
    this.onOpenNode,
    this.onEditQuery,
    this.storeChanges,
  });

  /// The hosting block's content document (the `node.name` JSON, or an
  /// already-decoded token list). The first `query` token's `queryAst` is
  /// the payload; a block without a token is an unspecified query.
  final dynamic source;

  /// The hosting PAGE's node id — the `self` member-target anchor (the
  /// containing page of the query block, never the block itself).
  final String selfNodeId;

  /// The run-site seam (slice 1): owns the local store + compiler.
  final QueryService queryService;

  /// Render-cascade navigation: a result-row tap opens the node's page.
  final ValueChanged<String>? onOpenNode;

  /// The authoring affordance (slice 4): when threaded, the unspecified
  /// state renders a tappable "Set a query" affordance and the result
  /// states carry an edit button opening the query builder; null = the
  /// read-only projection (no builder chrome).
  final VoidCallback? onEditQuery;

  /// The store-change subscription the coalesced re-run rides. Defaults to
  /// [StoreChangeBus.instance] (every local apply funnel notifies).
  final Stream<void>? storeChanges;

  @override
  State<QueryNodeSection> createState() => _QueryNodeSectionState();
}

class _QueryNodeSectionState extends State<QueryNodeSection> {
  /// The render window (the web's QUERY_RESULT_CAP).
  static const int _resultCap = 200;

  StreamSubscription<void>? _storeSub;

  /// The store version — bumped on every store-change notification, part of
  /// the run identity (the web hook's `version` state).
  int _version = 0;
  bool _running = false;
  bool _dirty = false;
  String? _lastAstKey;
  int _lastVersion = -1;
  String? _lastSelfNodeId;

  /// The last result (caches between runs): a plain query's rows, an
  /// aggregation's grid, or the invalid-query error.
  List<Node>? _rows;
  AggregateResult? _grid;
  String? _error;

  int _limit = _resultCap;
  String? _limitAstKey;

  @override
  void initState() {
    super.initState();
    _storeSub = _changes.listen(_onStoreChanged);
    _sync();
  }

  Stream<void> get _changes =>
      widget.storeChanges ?? StoreChangeBus.instance.changes;

  @override
  void didUpdateWidget(QueryNodeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeChanges != widget.storeChanges) {
      _storeSub?.cancel();
      _storeSub = _changes.listen(_onStoreChanged);
    }
    _sync();
  }

  @override
  void dispose() {
    _storeSub?.cancel();
    super.dispose();
  }

  void _onStoreChanged(void _) {
    if (!mounted) return;
    setState(() => _version += 1);
    _sync();
  }

  /// The useQueryRun effect port: run when the (astKey, version,
  /// selfNodeId) identity changes; a run in flight marks intervening
  /// changes dirty and the finally schedules exactly one trailing run.
  void _sync() {
    final token = _firstQueryToken();
    final rawAst = token == null ? null : token['queryAst'];
    final astKey = jsonEncode(rawAst ?? null);
    final selfNodeId = widget.selfNodeId;
    if (token == null || _isUnspecifiedQueryAst(rawAst)) {
      // Unspecified: never run, and clear a stale result so a query emptied
      // after a run renders the empty state, not its last result.
      _lastAstKey = astKey;
      _lastVersion = _version;
      _lastSelfNodeId = selfNodeId;
      _setResult(rows: null, grid: null, error: null);
      return;
    }
    if (_lastAstKey == astKey &&
        _lastVersion == _version &&
        _lastSelfNodeId == selfNodeId) {
      return; // already current
    }
    if (_running) {
      _dirty = true;
      return;
    }
    unawaited(_execute(astKey, rawAst, selfNodeId));
  }

  Future<void> _execute(String astKey, Object? rawAst, String selfNodeId) async {
    _running = true;
    final runVersion = _version;
    try {
      // The strict parse IS the run: a malformed AST surfaces as the
      // invalid-query state (loose-token parse parity with parseRunAst).
      final parsed = QueryAst.parse(rawAst);
      if (parsed.aggregation != null) {
        final grid = await widget.queryService.runAggregate(
          parsed,
          options: CompileOptions(selfNodeId: selfNodeId),
        );
        if (!mounted) return;
        _setResult(rows: null, grid: grid, error: null);
      } else {
        final rows = await widget.queryService.runNodes(
          parsed,
          options: CompileOptions(selfNodeId: selfNodeId),
        );
        if (!mounted) return;
        _setResult(rows: rows, grid: null, error: null);
      }
      _lastAstKey = astKey;
      _lastVersion = runVersion;
      _lastSelfNodeId = selfNodeId;
    } catch (e) {
      if (!mounted) return;
      _setResult(rows: null, grid: null, error: e.toString());
      // The failed identity is consumed: a retry needs a new version bump.
      _lastAstKey = astKey;
      _lastVersion = runVersion;
      _lastSelfNodeId = selfNodeId;
    } finally {
      _running = false;
      if (_dirty) {
        // One trailing run for the changes that landed mid-flight; the
        // version bump re-arms _sync with a fresh identity.
        _dirty = false;
        if (mounted) setState(() => _version += 1);
        _sync();
      }
    }
  }

  void _setResult({
    required List<Node>? rows,
    required AggregateResult? grid,
    required String? error,
  }) {
    setState(() {
      _rows = rows;
      _grid = grid;
      _error = error;
    });
  }

  Map<String, dynamic>? _firstQueryToken() {
    final List<Map<String, dynamic>> tokens;
    try {
      tokens = contentTokensFromSource(widget.source);
    } catch (_) {
      return null;
    }
    for (final token in tokens) {
      if (token['type'] == 'query') return token;
    }
    return null;
  }

  /// Port of the web's isUnspecifiedQueryAst: parses and specifies NOTHING
  /// (entire-workspace scope, a bare AND group with zero conditions, no
  /// aggregation). A scope-only AST is deliberate and still runs; an
  /// unparseable AST is not unspecified — the invalid-query state names it.
  bool _isUnspecifiedQueryAst(Object? raw) {
    final QueryAst parsed;
    try {
      parsed = QueryAst.parse(raw);
    } catch (_) {
      return false;
    }
    if (parsed.aggregation != null) return false;
    if (parsed.scope is! EntireWorkspaceScope) return false;
    return parsed.root.children.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bodyStyle = Theme.of(context).textTheme.bodyMedium;
    final dimStyle = bodyStyle?.copyWith(color: colors.onSurfaceVariant);

    final token = _firstQueryToken();
    final rawAst = token == null ? null : token['queryAst'];
    if (token == null || _isUnspecifiedQueryAst(rawAst)) {
      final text = Text('Set a query to see results.', style: dimStyle);
      // The authoring seam turns the resting state into the builder's door
      // (the web's "Set a query" intent — the class marks the block, the
      // first Apply creates the payload token).
      if (widget.onEditQuery == null) return text;
      return InkWell(
        onTap: widget.onEditQuery,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(child: text),
              Tooltip(
                message: 'Set a query',
                child: Icon(
                  MdiIcons.pencilOutline,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final error = _error;
    final body = _buildBody(colors, dimStyle, bodyStyle, rawAst, error);
    if (widget.onEditQuery == null) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Spacer(),
            Tooltip(
              message: 'Edit query',
              child: InkWell(
                onTap: widget.onEditQuery,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    MdiIcons.pencilOutline,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
        body,
      ],
    );
  }

  Widget _buildBody(
    ColorScheme colors,
    TextStyle? dimStyle,
    TextStyle? bodyStyle,
    Object? rawAst,
    String? error,
  ) {
    if (error != null) {
      return Tooltip(
        message: error,
        child: Text(
          'invalid query',
          style: dimStyle?.copyWith(color: colors.error),
        ),
      );
    }
    final grid = _grid;
    if (grid != null) return _buildAggregateGrid(grid, colors, bodyStyle);
    final rows = _rows;
    if (rows == null) return const SizedBox.shrink();
    if (rows.isEmpty) return Text('No results.', style: dimStyle);

    // The render window resets when the query itself changes (a different
    // query starts back at the default window).
    final astKey = jsonEncode(rawAst ?? null);
    final limit = _limitAstKey == astKey ? _limit : _resultCap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final node in rows.take(limit))
          _buildRow(node, colors, bodyStyle),
        if (rows.length > limit)
          TextButton(
            onPressed: () => setState(() {
              _limit = limit + _resultCap;
              _limitAstKey = astKey;
            }),
            child: Text('${rows.length - limit} more — load more'),
          ),
      ],
    );
  }

  /// The web query-node row chrome: the node's title, open on tap.
  Widget _buildRow(Node node, ColorScheme colors, TextStyle? style) {
    final title = node.displayName.isNotEmpty
        ? node.displayName
        : deriveDisplayName(node.name);
    return InkWell(
      onTap: widget.onOpenNode == null
          ? null
          : () => widget.onOpenNode!(node.uuid),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              MdiIcons.chevronRight,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  /// The aggregation grid: the compiler's column order, one text row per
  /// group (the web's nt-query-table, windowed to the same cap).
  Widget _buildAggregateGrid(
    AggregateResult grid,
    ColorScheme colors,
    TextStyle? style,
  ) {
    final borderSide = BorderSide(color: colors.outlineVariant, width: 0.5);
    Widget cell(Object? value, {required bool header}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          _formatCell(value),
          style: style?.copyWith(
            fontWeight: header ? FontWeight.w600 : null,
            color: header ? colors.onSurfaceVariant : null,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        border: TableBorder.symmetric(inside: borderSide),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: [
          TableRow(
            children: [
              for (final column in grid.columns) cell(column, header: true),
            ],
          ),
          for (final row in grid.rows)
            TableRow(
              children: [
                for (final value in row) cell(value, header: false),
              ],
            ),
        ],
      ),
    );
  }

  /// Grid cell rendering parity with the web's formatAggregateCell:
  /// null reads as a dash, objects as JSON.
  String _formatCell(Object? value) {
    if (value == null) return '—';
    if (value is Map || value is List) return jsonEncode(value);
    return value.toString();
  }
}
