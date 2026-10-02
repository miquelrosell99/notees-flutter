import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/node_display_name.dart';
import '../../../data/models/node.dart';
import '../../../data/repositories/node_repository.dart';
import '../../auth/providers/auth_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../../../shared/views/node_list_view.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/fleet_card.dart';
import '../../../shared/widgets/motion.dart';
import '../../../shared/widgets/node_actions.dart';
import '../../../shared/widgets/section_header.dart';
import '../../../shared/widgets/skeletons.dart';

/// The Home tab: a glanceable quick-reference surface, one scroll with four
/// compact sections (Today, Favorites, Recent, Inbox), each skipped when
/// empty. Organization stays in the web app; the mobile shell only surfaces
/// what is needed for quick reference and quick input.
///
/// Every section loads best-effort: a failed section degrades to empty and
/// never breaks Home, and an entirely empty Home shows a single quiet empty
/// state instead of error chrome.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  /// Reloads home data. Called by the shell after a successful quick capture
  /// so the new note shows up in the Inbox section immediately.
  void reload() => _loadHome();

  Node? _todayJournal;
  List<Node> _favorites = [];
  List<Node> _recents = [];
  List<Node> _inbox = [];
  Set<String> _favoriteUuids = {};
  bool _initialized = false;

  late final NodeActions _actions;

  @override
  void initState() {
    super.initState();
    _actions = NodeActions(
      isFavorite: (node) => _favoriteUuids.contains(node.uuid),
      onFavoriteChanged: (node, favorite) {
        setState(() {
          if (favorite) {
            _favoriteUuids.add(node.uuid);
          } else {
            _favoriteUuids.remove(node.uuid);
          }
        });
      },
      onReload: _loadHome,
    );
    _loadHome();
  }

  /// Best-effort wrapper: a failed fetch degrades to an empty section instead
  /// of failing the other sections.
  Future<List<Node>> _guard(Future<List<Node>> future) =>
      future.catchError((_) => <Node>[]);

  Future<void> _loadHome() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;
    final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);

    // Today resolves quietly: the row only appears once the daily note is
    // known, with no spinner chrome of its own.
    final Future<Node?> today = repo
        .getOrCreateDailyJournal(DateTime.now())
        .then<Node?>((journal) => journal)
        .catchError((_) => null);
    final results = await Future.wait([
      today,
      _guard(repo.fetchFavorites(limit: 5)),
      _guard(repo.fetchRecentPages(limit: 8)),
      _guard(repo.fetchInboxContent().then((content) => content.node.children)),
      repo
          .fetchFavoriteUuids()
          .then((uuids) => uuids.toSet())
          .catchError((_) => <String>{}),
    ]);
    if (!mounted) return;
    setState(() {
      _todayJournal = results[0] as Node?;
      _favorites = results[1] as List<Node>;
      _recents = results[2] as List<Node>;
      _inbox = results[3] as List<Node>;
      _favoriteUuids = results[4] as Set<String>;
      _initialized = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _loadHome,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _initialized
              ? _buildContent(settings.dateFormat)
              : const CardListSkeleton(key: ValueKey('home-loading')),
        ),
      ),
    );
  }

  Widget _buildContent(String dateFormat) {
    final todayJournal = _todayJournal;
    final sections = <Widget>[
      if (todayJournal != null) _buildTodayCard(todayJournal),
      if (_favorites.isNotEmpty)
        _buildSection(
          MdiIcons.star,
          'Favorites',
          _favorites.take(5).toList(),
          dateFormat,
        ),
      if (_recents.isNotEmpty)
        _buildSection(
          MdiIcons.clockOutline,
          'Recent',
          _recents.take(5).toList(),
          dateFormat,
        ),
      if (_inbox.isNotEmpty)
        _buildSection(
          MdiIcons.inboxOutline,
          'Inbox',
          _inbox.take(5).toList(),
          dateFormat,
        ),
    ];

    if (sections.isEmpty) {
      return ListView(
        key: const ValueKey('home-empty'),
        children: [
          EmptyState(icon: MdiIcons.inboxOutline, title: 'Nothing here yet'),
        ],
      );
    }

    return ListView(
      key: const ValueKey('home-content'),
      padding: const EdgeInsets.all(20),
      children: [
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0) const SizedBox(height: 28),
          staggered(i, sections[i]),
        ],
      ],
    );
  }

  /// Single quiet row opening today's daily note in the editor.
  Widget _buildTodayCard(Node journal) {
    final colors = Theme.of(context).colorScheme;
    return FleetCard(
      onTap: () => _actions.open(context, journal),
      child: ListTile(
        leading: Icon(MdiIcons.calendarOutline, color: colors.onSurfaceVariant),
        title: Text(DateFormat.yMMMMEEEEd().format(DateTime.now())),
        subtitle: Text(
          resolveNodeDisplayName(journal, dateFormat: context.read<SettingsProvider>().dateFormat),
        ),
        trailing: Icon(MdiIcons.chevronRight, color: colors.onSurfaceVariant),
      ),
    );
  }

  Widget _buildSection(
    IconData icon,
    String label,
    List<Node> nodes,
    String dateFormat,
  ) {
    return FleetCard(
      child: Column(
        children: [
          SectionHeader(icon: icon, label: label),
          const Divider(height: 1),
          NodeListView(
            nodes: nodes,
            onNodeTap: (node) => _actions.open(context, node),
            onNodeLongPress: (node) => _actions.showActions(context, node),
            shrinkWrap: true,
            favoriteUuids: _favoriteUuids,
            onFavoriteToggle: (node) => _actions.toggleFavorite(context, node),
            onArchive: (node) => _actions.archive(context, node),
            dateFormat: dateFormat,
            continuous: true,
          ),
        ],
      ),
    );
  }
}
