import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/node_display_name.dart';
import '../../../data/models/node.dart';
import '../../../data/repositories/local_recents_repository.dart';
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

/// Composes the Today card's content peek from the daily note's child
/// blocks: the first non-empty block texts (max 3), joined into one quiet
/// passage. Empty when the note has no body yet.
String composeTodayPeek(List<Node> children) {
  final parts = children
      .map((child) => resolveNodeDisplayName(child))
      .where((text) => text.isNotEmpty && text != 'Untitled')
      .take(3)
      .toList();
  return parts.join(' · ');
}

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
  String? _todayPeek;
  List<Node> _favorites = [];
  List<Node> _recents = [];
  List<Node> _inbox = [];
  Set<String> _favoriteUuids = {};
  bool _initialized = false;

  late final NodeActions _actions;
  late final LocalRecentsRepository _localRecents;

  @override
  void initState() {
    super.initState();
    _localRecents = LocalRecentsRepository(
      context.read<AuthProvider>().prefs,
    );
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
      onOpened: (node) => _localRecents.recordOpen(node.uuid),
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

    // Local recents (device-side opens) merge ahead of the server list: the
    // server's recents order by write_date, which an open does not change.
    var recents = results[2] as List<Node>;
    final localUuids = _localRecents.uuids;
    if (localUuids.isNotEmpty) {
      try {
        final localNodes = await repo.fetchNodesByUuids(localUuids);
        final byUuid = {for (final n in localNodes) n.uuid: n};
        final local = <Node>[
          for (final uuid in localUuids)
            if (byUuid[uuid] != null &&
                !byUuid[uuid]!.isArchived &&
                !byUuid[uuid]!.isDeleted)
              byUuid[uuid]!,
        ];
        if (local.isNotEmpty) {
          final seen = local.map((n) => n.uuid).toSet();
          recents = [
            ...local,
            ...recents.where((n) => !seen.contains(n.uuid)),
          ];
        }
      } catch (_) {
        // Local recents are a convenience; the server list still renders.
      }
    }

    final journal = results[0] as Node?;
    setState(() {
      _todayJournal = journal;
      _todayPeek = null;
      _favorites = results[1] as List<Node>;
      _recents = recents;
      _inbox = results[3] as List<Node>;
      _favoriteUuids = results[4] as Set<String>;
      _initialized = true;
    });
    if (journal != null) _loadTodayPeek(journal.uuid);
  }

  /// Loads the daily note's body preview (its child blocks' text). Quiet and
  /// unawaited: the Today row already renders; the peek fades in when ready.
  Future<void> _loadTodayPeek(String uuid) async {
    try {
      final auth = context.read<AuthProvider>();
      if (auth.dio == null) return;
      final repo = NodeRepository(dio: auth.dio!, syncService: auth.syncService);
      final content = await repo.fetchPageContent(uuid);
      if (!mounted || _todayJournal?.uuid != uuid) return;
      final peek = composeTodayPeek(content.node.children);
      if (peek.isNotEmpty) setState(() => _todayPeek = peek);
    } catch (_) {
      // The peek is a convenience; its absence keeps the row quiet.
    }
  }

  /// Pull-to-refresh: push the outbox and catch up with the relay first, then
  /// reload. Sync failures degrade silently — the indicator settles and Home
  /// shows whatever data loaded.
  Future<void> _refresh() async {
    try {
      final sync = context.read<AuthProvider>().syncService;
      if (sync != null) {
        await sync.flush();
        await sync.pull();
      }
    } catch (_) {}
    await _loadHome();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      // Home has no AppBar; SafeArea keeps the first section below the
      // status-bar inset (maintainBottomViewPadding preserves the nav-bar
      // padding the ListView already accounts for).
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _initialized
                ? _buildContent(settings.dateFormat)
                : const CardListSkeleton(key: ValueKey('home-loading')),
          ),
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
        padding: const EdgeInsets.all(20),
        children: [
          _buildHeader(),
          EmptyState(icon: MdiIcons.inboxOutline, title: 'Nothing here yet'),
        ],
      );
    }

    return ListView(
      key: const ValueKey('home-content'),
      padding: const EdgeInsets.all(20),
      children: [
        _buildHeader(),
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0) const SizedBox(height: 28),
          staggered(i, sections[i]),
        ],
      ],
    );
  }

  /// Quiet anchor at the top of the list (Home has no AppBar).
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        'Home',
        style: Theme.of(context).textTheme.titleLarge,
      ),
    );
  }

  /// Single quiet row opening today's daily note in the editor.
  Widget _buildTodayCard(Node journal) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final peek = _todayPeek;
    final title = resolveNodeDisplayName(
      journal,
      dateFormat: context.read<SettingsProvider>().dateFormat,
    );
    return FleetCard(
      onTap: () => _actions.open(context, journal),
      child: ListTile(
        isThreeLine: peek != null,
        leading: Icon(MdiIcons.calendarOutline, color: colors.onSurfaceVariant),
        title: Text(DateFormat.yMMMMEEEEd().format(DateTime.now())),
        // Title and peek share a two-line budget so the row stays three
        // lines tall at most.
        subtitle: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: peek == null
              ? Text(title, key: const ValueKey('today-subtitle'))
              : Text.rich(
                  key: const ValueKey('today-subtitle-peek'),
                  TextSpan(
                    children: [
                      TextSpan(text: title),
                      TextSpan(
                        text: '\n$peek',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
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
