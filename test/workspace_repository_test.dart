import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/repositories/workspace_repository.dart';

void main() {
  /// A Dio whose interceptor answers requests from [script] and records every
  /// request's method, path, and body for assertions.
  (Dio dio, List<({String method, String path, Object? body})>) scriptedDio(
    Object? Function(RequestOptions options) script,
  ) {
    final requests = <({String method, String path, Object? body})>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://notees.example.com/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add((method: options.method, path: options.path, body: options.data));
          final data = script(options);
          handler.resolve(Response(
            requestOptions: options,
            data: data,
            statusCode: 200,
          ));
        },
      ),
    );
    return (dio, requests);
  }

  group('WorkspaceRepository', () {
    test('listWorkspaces maps the server membership view', () async {
      final (dio, requests) = scriptedDio((options) => {
            'workspaces': [
              {
                'id': 'ws-1',
                'name': 'Personal',
                'role': 'owner',
                'createdAt': 1700000000000,
                'envelopeCount': 12,
                'latestSeq': 40,
              },
              {
                'id': 'ws-2',
                'name': null,
                'role': 'member',
                'createdAt': 1700000100000,
                'envelopeCount': 0,
                'latestSeq': 0,
              },
            ],
          });

      final workspaces = await WorkspaceRepository(dio: dio).listWorkspaces();

      expect(requests.single.method, 'GET');
      expect(requests.single.path, '/workspaces');
      expect(workspaces, hasLength(2));
      expect(workspaces[0].uuid, 'ws-1');
      expect(workspaces[0].name, 'Personal');
      expect(workspaces[0].isOwner, isTrue);
      expect(workspaces[0].createdAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(workspaces[0].envelopeCount, 12);
      expect(workspaces[0].latestSeq, 40);
      // Server name|null → display fallback, the web client's label.
      expect(workspaces[1].displayName, 'Workspace');
      expect(workspaces[1].isOwner, isFalse);
    });

    test('createWorkspace posts an empty body when unnamed', () async {
      final (dio, requests) = scriptedDio((options) => {
            'id': 'ws-new',
            'name': null,
            'role': 'owner',
          });

      final created =
          await WorkspaceRepository(dio: dio).createWorkspace();

      expect(requests.single.method, 'POST');
      expect(requests.single.path, '/workspaces');
      expect(requests.single.body, isEmpty);
      expect(created.uuid, 'ws-new');
      expect(created.displayName, 'Workspace');
    });

    test('createWorkspace sends the name when given', () async {
      final (dio, requests) = scriptedDio((options) => {
            'id': 'ws-new',
            'name': 'Research',
            'role': 'owner',
          });

      final created = await WorkspaceRepository(dio: dio)
          .createWorkspace(name: 'Research');

      expect(requests.single.body, {'name': 'Research'});
      expect(created.name, 'Research');
    });

    test('renameWorkspace patches the name', () async {
      final (dio, requests) = scriptedDio((options) => {
            'id': 'ws-1',
            'name': 'Renamed',
          });

      final renamed = await WorkspaceRepository(dio: dio)
          .renameWorkspace('ws-1', 'Renamed');

      expect(requests.single.method, 'PATCH');
      expect(requests.single.path, '/workspaces/ws-1');
      expect(requests.single.body, {'name': 'Renamed'});
      expect(renamed.name, 'Renamed');
    });
  });
}
