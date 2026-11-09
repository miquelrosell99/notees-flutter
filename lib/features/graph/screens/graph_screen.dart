import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/routing/router.dart';
import '../../../domain/services/graph_service.dart';
import '../../../domain/services/query_service.dart';
import '../../../shared/widgets/empty_state.dart';
import '../widgets/color_groups_sheet.dart';
import '../widgets/graph_canvas.dart';

/// The graph view: the workspace's pages and classes as a force-directed
/// graph, colored by the device-local query-driven color groups. Offline-
/// local — every read rides the derived store through [GraphService].
class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  late final GraphService _service;

  @override
  void initState() {
    super.initState();
    // The screen owns its service's lifecycle (the feature-local provider
    // idiom); the app-level QueryService is the shared read site.
    _service = GraphService(queryService: context.read<QueryService>());
    unawaited(_service.load());
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<GraphService>.value(
      value: _service,
      child: Consumer<GraphService>(
        builder: (context, service, _) {
          final topology = service.topology;
          return Scaffold(
            appBar: AppBar(
              title: const Text('Graph'),
              actions: [
                IconButton(
                  tooltip: 'Color groups',
                  icon: Icon(MdiIcons.paletteOutline),
                  onPressed: () => ColorGroupsSheet.show(context),
                ),
              ],
            ),
            body: topology == null
                ? const Center(child: CircularProgressIndicator())
                : topology.nodes.isEmpty
                    ? EmptyState(
                        icon: MdiIcons.graphOutline,
                        title: 'Nothing to graph yet',
                        subtitle:
                            'Pages and classes you create will appear here.',
                      )
                    : GraphCanvas(
                        topology: topology,
                        layout: service.layout,
                        colorFor: service.colorFor,
                        onNodeTap: (nodeId) =>
                            context.push('${Routes.editor}/$nodeId'),
                      ),
          );
        },
      ),
    );
  }
}
