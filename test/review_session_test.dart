import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:notees/core/constants/system.dart';
import 'package:notees/core/secure/secure_storage.dart';
import 'package:notees/core/utils/ast_builder.dart';
import 'package:notees/data/local/app_database.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/models/relay/operation_envelope.dart';
import 'package:notees/data/models/server_profile.dart';
import 'package:notees/data/repositories/node_cache_repository.dart';
import 'package:notees/data/repositories/node_repository.dart';
import 'package:notees/data/repositories/prefs_repository.dart';
import 'package:notees/data/repositories/server_repository.dart';
import 'package:notees/data/repositories/workspace_repository.dart';
import 'package:notees/domain/models/search_filters.dart';
import 'package:notees/domain/services/srs.dart';
import 'package:notees/domain/services/sync_v2_service.dart';
import 'package:notees/features/auth/providers/auth_provider.dart';
import 'package:notees/features/cards/screens/review_session_screen.dart';
import 'package:notees/features/editor/widgets/ast_rich_text.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The review session (`ReviewSession.tsx` parity): front → reveal →
/// grade → advance, the front-only empty state, the summary screen, the
/// empty session, and the vanished-node drop. A fake repository keeps the
/// widget zone free of sqflite (which never completes inside testWidgets'
/// fake-async zone — the hub tests seed in setUp for the same reason).

/// One recorded reviewCard call.
class ReviewCall {
  ReviewCall({
    required this.cardId,
    required this.stateAfter,
    required this.algorithm,
    required this.sessionId,
    required this.grade,
    required this.stateBefore,
  });

  final String cardId;
  final CardSrsState stateAfter;
  final SrsAlgorithm algorithm;
  final String sessionId;
  final CardGrade grade;
  final CardSrsState stateBefore;
}

class FakeCardsRepository extends NodeRepository {
  FakeCardsRepository() : super(dio: Dio(), syncService: null);

  final nodes = <String, Node>{};
  final props = <String, List<EffectiveProperty>>{};
  final childMap = <String, List<Node>>{};
  final reviews = <ReviewCall>[];

  @override
  Future<List<Node>> searchWithFilters(SearchFilters filters) async =>
      nodes.values.where((node) => node.classesUuid.contains(SystemClassUuids.card)).toList();

  @override
  Future<List<EffectiveProperty>> fetchEffectiveProperties(String nodeUuid) async =>
      props[nodeUuid] ?? const [];

  @override
  Future<Node?> getCachedNode(String uuid) async => nodes[uuid];

  @override
  Future<List<Node>> getChildren(String parentUuid) async => childMap[parentUuid] ?? const [];

  @override
  Future<void> reviewCard({
    required String cardId,
    required CardSrsState stateAfter,
    required SrsAlgorithm algorithm,
    required String sessionId,
    required CardGrade grade,
    required CardSrsState stateBefore,
    required DateTime reviewedAt,
  }) async {
    reviews.add(ReviewCall(
      cardId: cardId,
      stateAfter: stateAfter,
      algorithm: algorithm,
      sessionId: sessionId,
      grade: grade,
      stateBefore: stateBefore,
    ));
  }
}

class FakePrefsRepository extends PrefsRepository {
  FakePrefsRepository() : super(dio: Dio(), prefs: _fakePrefs);

  @override
  Future<SrsAlgorithm> getCardsAlgorithm() async => SrsAlgorithm.fsrs;
}

late SharedPreferences _fakePrefs;

// --- The NON-INJECTED production path: a fake cache/service layer over a
// real (never-queried) ffi database, so the screen self-provisions its
// repositories from a stubbed AuthProvider without touching sqflite inside
// the widget zone.

OperationEnvelope _dummyEnvelope(String opType, Map<String, dynamic> payload) =>
    OperationEnvelope(
      id: '60000000-0000-4000-8000-000000000001',
      workspaceId: '10000000-0000-4000-8000-000000000001',
      actorId: '40000000-0000-4000-8000-000000000001',
      deviceId: '40000000-0000-4000-8000-000000000001',
      hlc: const Hlc(physical: 0, logical: 0),
      affectedNodeIds: const [],
      opType: opType,
      payload: payload,
      timestamp: '2026-10-28T00:00:00.000Z',
    );

class FakeReviewCache extends NodeCacheRepository {
  FakeReviewCache() : super(_harnessDb);

  final nodes = <String, Node>{};
  final props = <String, List<EffectiveProperty>>{};
  final children = <String, List<Node>>{};

  @override
  Future<Node?> getByUuid(String uuid) async => nodes[uuid];

  @override
  Future<List<EffectiveProperty>> getEffectiveProperties(String uuid) async =>
      props[uuid] ?? const [];

  @override
  Future<List<Node>> getChildren(String parentUuid) async =>
      children[parentUuid] ?? const [];
}

class FakeReviewSyncService extends SyncV2Service {
  FakeReviewSyncService({required super.dio})
      : fakeCache = FakeReviewCache(),
        super(
          database: _harnessDb,
          clientId: '40000000-0000-4000-8000-000000000001',
        );

  final FakeReviewCache fakeCache;

  /// Recorded `property.set` payloads (the idx-addressed grade writes).
  final sets = <Map<String, dynamic>>[];

  /// Recorded `(opType, payload)` envelopes (chain creates + card.review).
  final emitted = <(String, Map<String, dynamic>)>[];

  @override
  NodeCacheRepository get cache => fakeCache;

  @override
  Future<Node?> getCachedNode(String uuid) async => fakeCache.nodes[uuid];

  @override
  Future<OperationEnvelope> setPropertyValue({
    required String objectId,
    required String propertySchemaId,
    required dynamic value,
    int idx = 0,
  }) async {
    sets.add(<String, dynamic>{
      'objectId': objectId,
      'propertySchemaId': propertySchemaId,
      'value': value,
      'idx': idx,
    });
    return _dummyEnvelope('property.set', const <String, dynamic>{});
  }

  @override
  Future<OperationEnvelope> emitLocal({
    required String opType,
    required Map<String, dynamic> payload,
    required List<String> affectedNodeIds,
  }) async {
    emitted.add((opType, payload));
    return _dummyEnvelope(opType, payload);
  }
}

/// A stubbed [AuthProvider] whose dio serves `/me/prefs` and whose
/// syncService is the fake layer — the production seams the non-injected
/// screen path self-provisions from.
class StubbedAuth extends AuthProvider {
  StubbedAuth({
    required super.serverRepository,
    required super.secureStorage,
    required super.prefs,
    required this.fakeDio,
    required this.fakeSync,
  });

  final Dio fakeDio;
  final SyncV2Service fakeSync;

  @override
  bool get loading => false;

  @override
  bool get isAuthenticated => true;

  @override
  bool get isLocalMode => false;

  @override
  ServerProfile? get activeServer => ServerProfile(
      id: 'server-1', url: 'https://notees.example.com', nickname: 'Test');

  @override
  Dio? get dio => fakeDio;

  @override
  SyncV2Service? get syncService => fakeSync;

  @override
  bool get onboardingCompleted => true;

  @override
  String? get activeWorkspaceId => 'ws-owner';

  @override
  List<Workspace>? get workspaces => [Workspace(uuid: 'ws-owner', name: 'Personal', role: 'owner')];

  @override
  bool get hasValidWorkspace => true;
}

late AppDatabase _harnessDb;


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cardA = '30000000-0000-4000-8000-00000000000a';
  const cardB = '30000000-0000-4000-8000-00000000000b';
  const childA = '30000000-0000-4000-8000-0000000000aa';

  EffectiveProperty row(String schemaId, dynamic value) => EffectiveProperty(
        propertySchemaId: schemaId,
        idx: 0,
        elementId: 'el-$schemaId',
        schema: null,
        value: value,
        metadata: null,
        source: 'authored',
        boundBy: null,
        hideWhenEmpty: null,
        display: null,
      );

  Node cardNode(String uuid, String title) => Node(
        id: 0,
        uuid: uuid,
        name: AstBuilder.serialize(AstBuilder.parseInline(title)),
        displayName: title,
        classesUuid: const [SystemClassUuids.card],
      );

  late FakeCardsRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _fakePrefs = await SharedPreferences.getInstance();
    repository = FakeCardsRepository();
  });

  /// Card A: due today, reps 5 (a grade of Again counts a lapse), one
  /// embedded child (the answer). Card B: fresh, front-only.
  void seedTwoCards() {
    repository
      ..nodes[cardA] = cardNode(cardA, 'Card A front')
      ..nodes[cardB] = cardNode(cardB, 'Card B front')
      ..props[cardA] = [
        row(SystemPropertyUuids.cardDue, '2026-10-28'),
        row(SystemPropertyUuids.cardReps, 5),
        row(SystemPropertyUuids.cardInterval, 21),
      ]
      ..props[cardB] = const []
      ..childMap[cardA] = [cardNode(childA, 'The answer')];
  }

  late GoRouter router;

  Future<void> pumpSession(
    WidgetTester tester, {
    List<String>? cardIds,
    String? label,
  }) async {
    router = GoRouter(
      initialLocation: '/cards',
      routes: [
        GoRoute(
          path: '/cards',
          builder: (context, state) => const Scaffold(body: Text('back-at-hub')),
        ),
        GoRoute(
          path: '/review',
          builder: (context, state) => ReviewSessionScreen(
            cardIds: cardIds,
            label: label,
            repository: repository,
            prefsRepository: FakePrefsRepository(),
          ),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    router.push('/review');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
  }

  testWidgets('front → reveal → grade → advance; lapses counted; summary; back to hub',
      (tester) async {
    seedTwoCards();
    await pumpSession(tester, cardIds: const [cardA, cardB], label: 'All cards');

    // Front: the card's own content only, header context, no grade bar.
    expect(find.text('1 of 2 · All cards'), findsOneWidget);
    expect(find.byType(AstRichText), findsOneWidget);
    expect(find.text('Reveal'), findsOneWidget);
    expect(find.text('Again'), findsNothing);

    // Reveal: the back = the node row + its embedded child.
    await tester.tap(find.text('Reveal'));
    await tester.pump();
    expect(find.byType(AstRichText), findsNWidgets(2));
    expect(find.text('No answer on this card'), findsNothing);
    expect(find.text('Again'), findsOneWidget);

    // Grade Good on card A (fsrs default from the fake prefs).
    await tester.tap(find.text('Good'));
    await tester.pump();
    await tester.pump();
    expect(repository.reviews, hasLength(1));
    expect(repository.reviews.single.cardId, cardA);
    expect(repository.reviews.single.grade, CardGrade.good);
    expect(repository.reviews.single.algorithm, SrsAlgorithm.fsrs);
    // One sessionId grades the whole session together.
    final sessionId = repository.reviews.single.sessionId;
    expect(sessionId, isNotEmpty);

    // Advanced to card B (fresh → Again is NOT a lapse).
    expect(find.text('2 of 2 · All cards'), findsOneWidget);
    await tester.tap(find.text('Reveal'));
    await tester.pump();
    await tester.tap(find.text('Again'));
    await tester.pump();
    await tester.pump();
    expect(repository.reviews, hasLength(2));
    expect(repository.reviews.last.sessionId, sessionId);

    // Summary: 2 reviewed, no lapse line (B was fresh).
    expect(find.text('2 cards reviewed'), findsOneWidget);
    expect(find.textContaining('lapse'), findsNothing);

    await tester.tap(find.text('Back to cards'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('back-at-hub'), findsOneWidget);
  });

  testWidgets('a reviewed card with prior reps graded Again counts a lapse',
      (tester) async {
    seedTwoCards();
    await pumpSession(tester, cardIds: const [cardA], label: 'Single card');

    await tester.tap(find.text('Reveal'));
    await tester.pump();
    await tester.tap(find.text('Again'));
    await tester.pump();
    await tester.pump();

    expect(find.text('1 card reviewed'), findsOneWidget);
    expect(find.text('1 lapse'), findsOneWidget);
  });

  testWidgets('front-only card: the back names its emptiness, grading still works',
      (tester) async {
    seedTwoCards();
    await pumpSession(tester, cardIds: const [cardB], label: 'Single card');

    await tester.tap(find.text('Reveal'));
    await tester.pump();
    expect(find.text('No answer on this card'), findsOneWidget);
    expect(find.text('Again'), findsOneWidget);

    await tester.tap(find.text('Easy'));
    await tester.pump();
    await tester.pump();
    expect(repository.reviews.single.cardId, cardB);
    expect(find.text('1 card reviewed'), findsOneWidget);
  });

  testWidgets('a vanished hand-off node is dropped from the queue', (tester) async {
    seedTwoCards();
    await pumpSession(
      tester,
      cardIds: const [cardA, '30000000-0000-4000-8000-00000000ffff'],
      label: 'All cards',
    );

    expect(find.text('1 of 1 · All cards'), findsOneWidget);
  });

  testWidgets('empty queue: the web copy and a back action', (tester) async {
    seedTwoCards();
    await pumpSession(tester, cardIds: const [], label: 'All cards');

    expect(find.text('Nothing to review'), findsOneWidget);
    expect(
      find.text('No cards are due. New cards appear here once the card class is assigned.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Back to cards'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('back-at-hub'), findsOneWidget);
  });
  group('non-injected production path (C1)', () {
    const cardC = '30000000-0000-4000-8000-00000000000c';
    late FakeReviewSyncService fakeSync;
    var prefsGets = 0;

    Dio prefsDio() {
      final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            prefsGets += 1;
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: const {'cardsAlgorithm': 'sm2'},
            ));
          },
        ),
      );
      return dio;
    }

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      sqfliteFfiInit();
      final ffiDb = await databaseFactoryFfi.openDatabase(
        ':memory:',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      _harnessDb = AppDatabase.fromDatabase(ffiDb);
      await _harnessDb.initializeSchema();
      addTearDown(() async {
        await _harnessDb.close();
        AppDatabase.reset();
      });
      fakeSync = FakeReviewSyncService(dio: prefsDio());
      prefsGets = 0;
      // One reviewed-before card: reps 5, no due (a Good grade moves ease).
      fakeSync.fakeCache.nodes[cardC] = cardNode(cardC, 'Card C front');
      fakeSync.fakeCache.props[cardC] = [
        row(SystemPropertyUuids.cardReps, 5),
        row(SystemPropertyUuids.cardInterval, 21),
        row(SystemPropertyUuids.cardEase, 1.35),
      ];
    });

    testWidgets('the hub pref (sm2) reaches the grade computation — the '
        'session self-provisions its prefs repository from AuthProvider',
        (tester) async {
      final auth = StubbedAuth(
        serverRepository: ServerRepository(prefs: _fakePrefs),
        secureStorage: const SecureStorage(),
        prefs: _fakePrefs,
        fakeDio: prefsDio(),
        fakeSync: fakeSync,
      );
      final router = GoRouter(
        initialLocation: '/cards',
        routes: [
          GoRoute(
            path: '/cards',
            builder: (context, state) => const Scaffold(body: Text('back-at-hub')),
          ),
          GoRoute(
            path: '/review',
            builder: (context, state) => const ReviewSessionScreen(
              cardIds: [cardC],
              label: 'Single card',
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthProvider>.value(
          value: auth,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      router.push('/review');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      // The session self-provisioned PrefsRepository read the pref.
      expect(prefsGets, greaterThanOrEqualTo(1));
      expect(find.text('1 of 1 · Single card'), findsOneWidget);

      await tester.tap(find.text('Reveal'));
      await tester.pump();
      await tester.tap(find.text('Good'));
      await tester.pump();
      await tester.pump();

      // sm2 evidence in the grade writes: cardEase moves, the fsrs fields
      // are NEVER written (the mid-deck contract, not inverted).
      final schemas = fakeSync.sets.map((set) => set['propertySchemaId'] as String).toSet();
      expect(schemas, contains(SystemPropertyUuids.cardDue));
      expect(schemas, contains(SystemPropertyUuids.cardReps));
      expect(schemas, contains(SystemPropertyUuids.cardInterval));
      expect(schemas, contains(SystemPropertyUuids.cardEase));
      expect(schemas, isNot(contains(SystemPropertyUuids.cardDifficulty)));
      expect(schemas, isNot(contains(SystemPropertyUuids.cardStability)));

      // The history envelope records WHICH scheduler ran.
      final review = fakeSync.emitted.firstWhere((entry) => entry.$1 == 'card.review');
      expect(review.$2['algorithm'], 'sm2');
      expect(review.$2['grade'], 'good');
      expect(find.text('1 card reviewed'), findsOneWidget);
    });
  });
}
