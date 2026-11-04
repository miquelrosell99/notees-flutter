import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/utils/uuid7.dart';
import '../../data/local/app_database.dart';
import '../../data/repositories/color_group_store.dart';
import '../../data/repositories/graph_repository.dart';
import '../graph/graph_color_group.dart';
import '../graph/graph_layout.dart';
import '../graph/graph_model.dart';
import 'query_service.dart';
import 'store_change_bus.dart';

/// The graph surface's run site — the QueryService seam's twin. Owns the
/// topology projection + the deterministic layout, the device-local color
/// groups (loaded through the one-time migrations, evaluated first-match-
/// wins over the local query runner), and the store-change bus
/// subscription that keeps both live (the web `useQueryRun` coalesced
/// re-run twin: a short debounce, then a full rebuild — topology, layout,
/// and colors). Offline-local: every read rides the derived store, never
/// the server.
class GraphService extends ChangeNotifier {
  GraphService({
    GraphRepository? graphRepository,
    QueryService? queryService,
    ColorGroupStore? colorGroupStore,
    Stream<void>? storeChanges,
    this.layoutSeed = 42,
  })  : _graphRepository = graphRepository ?? GraphRepository(AppDatabase()),
        _queryService = queryService ?? QueryService(),
        _colorGroupStore = colorGroupStore ?? ColorGroupStore(),
        _storeChanges = storeChanges ?? StoreChangeBus.instance.changes {
    _changeSubscription = _storeChanges.listen((_) => _onStoreChange());
  }

  final GraphRepository _graphRepository;
  final QueryService _queryService;
  final ColorGroupStore _colorGroupStore;
  final Stream<void> _storeChanges;
  StreamSubscription<void>? _changeSubscription;

  /// The layout seed — the same value on every load is what makes the
  /// graph stable between visits.
  final int layoutSeed;

  static const _rebuildDebounce = Duration(milliseconds: 250);

  GraphTopology? _topology;
  Map<String, GraphPoint> _layout = const {};
  List<GraphColorGroup> _groups = const [];
  Map<String, String> _colorAssignments = const {};
  Timer? _rebuildTimer;
  bool _loadInFlight = false;

  /// The loaded topology (null until [load] completes).
  GraphTopology? get topology => _topology;

  /// The deterministic layout positions keyed by node id.
  Map<String, GraphPoint> get layout => _layout;

  /// The color groups in list order — the first-match-wins priority.
  List<GraphColorGroup> get groups => _groups;

  /// The evaluated nodeId → stored color (token or hex) assignment;
  /// nodes absent here keep their own color.
  Map<String, String> get colorAssignments => _colorAssignments;

  /// The group-paint for [nodeId], null when no group matches.
  String? colorFor(String nodeId) => _colorAssignments[nodeId];

  /// Loads the groups (migrating legacy rows) and builds the first
  /// topology + layout + color evaluation. Re-entry safe — concurrent
  /// callers share the in-flight load. The migrated list re-persists
  /// immediately (the web GraphView effect's precedent): legacy rows must
  /// not be re-migrated on every load.
  Future<void> load() async {
    if (_loadInFlight) return;
    _loadInFlight = true;
    try {
      final rawRows = await _colorGroupStore.load();
      _groups = [
        for (final row in rawRows)
          await migrateColorGroup(
            row,
            parseDsl: (dsl) => _queryService.parseQueryLanguage(dsl),
          ),
      ];
      await _colorGroupStore.save(_groups);
      await _rebuild();
    } finally {
      _loadInFlight = false;
    }
  }

  /// Adds a new group or edits the existing [id]: parses the DSL text
  /// through the local query surface (fails loud — the sheet shows the
  /// error), persists the list, and re-evaluates the coloring. The group
  /// keeps its list slot on edit (the slot IS the priority).
  Future<void> saveGroup({
    String? id,
    required String label,
    required String color,
    required String dslText,
  }) async {
    final parsed = await _queryService.parseQueryLanguage(dslText);
    final group = GraphColorGroup(
      id: id ?? Uuid7.generate(),
      label: label.trim().isEmpty ? 'Untitled group' : label.trim(),
      color: color,
      ast: parsed.root,
    );
    final next = [..._groups];
    final index = id == null ? -1 : next.indexWhere((g) => g.id == id);
    if (index >= 0) {
      next[index] = group;
    } else {
      next.add(group);
    }
    _groups = next;
    await _colorGroupStore.save(_groups);
    await _recolor();
    notifyListeners();
  }

  /// Removes the group and re-evaluates — its nodes repaint immediately
  /// (their own color or a later matching group).
  Future<void> removeGroup(String id) async {
    _groups = [for (final g in _groups) if (g.id != id) g];
    await _colorGroupStore.save(_groups);
    await _recolor();
    notifyListeners();
  }

  Future<void> _rebuild() async {
    _topology = await _graphRepository.loadTopology();
    _layout = computeForceLayout(_topology!, seed: layoutSeed);
    await _recolor();
    notifyListeners();
  }

  Future<void> _recolor() async {
    _colorAssignments = await evaluateColorGroups(_groups, (ast) async {
      final nodes = await _queryService.runNodes(ast);
      return [for (final node in nodes) node.uuid];
    });
  }

  /// The store-change bus ride: coalesce bursts (a sync page fans many
  /// notifications into one rebuild) and never rebuild faster than the
  /// debounce — the live-recolor-on-store-change contract.
  void _onStoreChange() {
    _rebuildTimer?.cancel();
    _rebuildTimer = Timer(_rebuildDebounce, () async {
      if (_topology == null) return; // not loaded yet; load() builds
      try {
        await _rebuild();
      } catch (error, stack) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'graph-service',
        ));
      }
    });
  }

  @override
  void dispose() {
    _rebuildTimer?.cancel();
    unawaited(_changeSubscription?.cancel());
    _changeSubscription = null;
    super.dispose();
  }
}
