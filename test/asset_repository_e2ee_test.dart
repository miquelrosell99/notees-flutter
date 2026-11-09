@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/crypto/crypto_custody.dart';
import 'package:notees/data/repositories/asset_repository.dart';
import 'package:notees/domain/models/relay/asset_crypto.dart';
import 'package:notees/domain/models/relay/payload_crypto.dart';

/// Asset I/O against the shipped server routes (`POST /api/assets`, `GET
/// /api/assets/:id`, `/info`): uploads seal + declare (`encrypted` /
/// `mimeType` / `iv`) when custody holds the active workspace's key and keep
/// the plaintext path when keyless; downloads open sealed bytes through the
/// custody key — IV from the caller, else the `x-notees-asset-iv` header,
/// else /info — and fail honest (StateError) when sealed without one.
///
/// The scrypt KDF (N=131072) is deliberately expensive; the master record is
/// built once for the whole suite.
void main() {
  const password = 'correct horse battery staple';
  const workspaceId = '10000000-0000-4000-8000-0000000000a1';
  const assetId = '20000000-0000-4000-8000-0000000000b1';

  late final KdfRecord kdfRecord;

  setUpAll(() async {
    kdfRecord = await createKdfRecord(generateMasterKey(), password);
  });

  tearDown(() {
    clearCryptoCustody();
  });

  /// Scripts the relay key routes for [workspaceId]: GET 404 (no stored
  /// key), PUT stores. Generation path only — first-write-wins is custody's
  /// own suite's job.
  Dio keyDio() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/workspaces/$workspaceId/key') {
            if (options.method == 'GET') {
              handler.reject(DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 404),
                type: DioExceptionType.badResponse,
              ));
              return;
            }
            handler.resolve(Response(requestOptions: options, statusCode: 204));
            return;
          }
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'unexpected request: ${options.method} ${options.path}',
          ));
        },
      ),
    );
    return dio;
  }

  /// Dio that answers the shipped asset routes, capturing every request
  /// into [captured]. Upload answers a camelCase 201 row; download serves
  /// [blob], carrying [ivHeader] as `x-notees-asset-iv` when given; /info
  /// answers [infoIv] (omitted when null).
  Dio assetDio(
    List<RequestOptions> captured, {
    Uint8List? blob,
    String? ivHeader,
    String? infoIv,
  }) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured.add(options);
          if (options.path == '/api/assets' && options.method == 'POST') {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 201,
              data: <String, dynamic>{
                'assetId': assetId,
                'hash': 'aa' * 32,
                'mimeType': 'image/png',
                'size': 9,
                'originalName': 'photo.png',
                'refs': <String>[],
              },
            ));
            return;
          }
          if (options.path == '/api/assets/$assetId/info') {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'assetId': assetId,
                'hash': 'aa' * 32,
                'mimeType': 'image/png',
                'size': 9,
                'originalName': 'photo.png',
                'refs': <String>[],
                'iv': ?infoIv,
              },
            ));
            return;
          }
          if (options.path == '/api/assets/$assetId' &&
              options.method == 'GET') {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              headers: ivHeader == null
                  ? null
                  : Headers.fromMap(
                      {'x-notees-asset-iv': <String>[ivHeader]}),
              data: blob ?? Uint8List.fromList([1, 2, 3]),
            ));
            return;
          }
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'unexpected request: ${options.method} ${options.path}',
          ));
        },
      ),
    );
    return dio;
  }

  /// Installs custody: master + generated workspace key for [workspaceId].
  Future<SecretKey> installWorkspaceKey() async {
    await deriveMasterKey(password, kdfRecord.toJson());
    final key = await ensureWorkspaceKey(keyDio(), workspaceId);
    noteActiveWorkspace(workspaceId);
    return key;
  }

  /// Drains a multipart part to bytes (dio 5.7+ finalize is a plain stream).
  Future<Uint8List> readPart(MultipartFile part) async {
    final chunks = await part.finalize().toList();
    final total = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final chunk in chunks) {
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return out;
  }

  File writeTempPng(Uint8List bytes) {
    final file = File(
      '${Directory.systemTemp.path}/notees_asset_repo_test_${bytes.length}.png',
    );
    file.writeAsBytesSync(bytes);
    addTearDown(file.delete);
    return file;
  }

  group('uploadFile (POST /api/assets)', () {
    test('keyless: plaintext part, no encrypted/mimeType/iv fields',
        () async {
      final captured = <RequestOptions>[];
      final plain = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 7, 8, 9]);
      final file = writeTempPng(plain);

      await AssetRepository(dio: assetDio(captured)).uploadFile(file);

      final form = captured.single.data! as FormData;
      final fieldNames = form.fields.map((e) => e.key).toList();
      expect(fieldNames, isNot(contains('encrypted')));
      expect(fieldNames, isNot(contains('mimeType')));
      expect(fieldNames, isNot(contains('iv')));
      expect(fieldNames, isNot(contains('objectId')));
      final part = form.files.single.value;
      expect(await readPart(part), plain);
    });

    test('keyed: seals the bytes and declares encrypted/mimeType/iv',
        () async {
      final workspaceKey = await installWorkspaceKey();
      final captured = <RequestOptions>[];
      final plain =
          Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 250, 251]);
      final file = writeTempPng(plain);

      await AssetRepository(dio: assetDio(captured)).uploadFile(file);

      final form = captured.single.data! as FormData;
      final fields = Map.fromEntries(form.fields);
      expect(fields['encrypted'], '1');
      expect(fields['mimeType'], 'image/png');
      final iv = Uint8List.fromList(b64uDecode(fields['iv']!));
      expect(iv, hasLength(12));

      final part = form.files.single.value;
      final blob = await readPart(part);
      // tag‖ct layout: opens with the declared external IV.
      expect(blob.length, 16 + plain.length);
      expect(await decryptAssetBytes(workspaceKey, iv, blob), plain);
    });

    test('attach: existingNodeUuid/parentUuid ride as the objectId field',
        () async {
      final captured = <RequestOptions>[];
      final file = writeTempPng(Uint8List.fromList([1, 2, 3]));

      await AssetRepository(dio: assetDio(captured)).uploadFile(
        file,
        existingNodeUuid: '30000000-0000-4000-8000-0000000000c1',
      );

      final form = captured.single.data! as FormData;
      final fields = Map.fromEntries(form.fields);
      expect(fields['objectId'], '30000000-0000-4000-8000-0000000000c1');
    });
  });

  group('downloadBytes (GET /api/assets/:id)', () {
    test('plaintext asset (no IV anywhere) passes through', () async {
      final captured = <RequestOptions>[];
      final blob = Uint8List.fromList([10, 20, 30]);

      final bytes = await AssetRepository(dio: assetDio(captured, blob: blob))
          .downloadBytes(assetId);

      expect(bytes, blob);
      // Header absent ⇒ the /info fallback was consulted and found no iv.
      expect(captured.map((o) => o.path), contains('/api/assets/$assetId/info'));
    });

    test('sealed asset opens from the x-notees-asset-iv header', () async {
      final workspaceKey = await installWorkspaceKey();
      final plain = Uint8List.fromList(List<int>.generate(100, (i) => i));
      final sealed = await encryptAssetBytes(workspaceKey, plain);
      final captured = <RequestOptions>[];

      final bytes = await AssetRepository(
        dio: assetDio(
          captured,
          blob: sealed.blob,
          ivHeader: b64uEncode(sealed.iv),
        ),
      ).downloadBytes(assetId);

      expect(bytes, plain);
      // The header answered: no /info round-trip.
      expect(
        captured.map((o) => o.path),
        isNot(contains('/api/assets/$assetId/info')),
      );
    });

    test('sealed asset falls back to /info for the IV', () async {
      final workspaceKey = await installWorkspaceKey();
      final plain = Uint8List.fromList([5, 6, 7, 8]);
      final sealed = await encryptAssetBytes(workspaceKey, plain);
      final captured = <RequestOptions>[];

      final bytes = await AssetRepository(
        dio: assetDio(
          captured,
          blob: sealed.blob,
          infoIv: b64uEncode(sealed.iv),
        ),
      ).downloadBytes(assetId);

      expect(bytes, plain);
    });

    test('sealed asset opens from a caller-supplied IV', () async {
      final workspaceKey = await installWorkspaceKey();
      final plain = Uint8List.fromList([42]);
      final sealed = await encryptAssetBytes(workspaceKey, plain);
      final captured = <RequestOptions>[];

      final bytes = await AssetRepository(
        dio: assetDio(captured, blob: sealed.blob),
      ).downloadBytes(assetId, iv: b64uEncode(sealed.iv));

      expect(bytes, plain);
      // Caller-supplied IV wins: neither header nor /info needed.
      expect(captured, hasLength(1));
    });

    test('sealed asset without a key throws StateError (honest fallback)',
        () async {
      final workspaceKey = generateWorkspaceKey();
      final plain = Uint8List.fromList([5, 6, 7]);
      final sealed = await encryptAssetBytes(workspaceKey, plain);
      final captured = <RequestOptions>[];

      expect(
        AssetRepository(
          dio: assetDio(
            captured,
            blob: sealed.blob,
            ivHeader: b64uEncode(sealed.iv),
          ),
        ).downloadBytes(assetId),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('fetchAssetInfo (GET /api/assets/:id/info)', () {
    test('parses the camelCase row incl. the iv', () async {
      final captured = <RequestOptions>[];
      final dio = assetDio(captured, infoIv: 'QUJDREVGR0hJSg');

      final info = await AssetRepository(dio: dio).fetchAssetInfo(assetId);

      expect(info.assetId, assetId);
      expect(info.filename, 'photo.png');
      expect(info.mimeType, 'image/png');
      expect(info.category, 'image');
      expect(info.iv, 'QUJDREVGR0hJSg');
    });
  });
}
