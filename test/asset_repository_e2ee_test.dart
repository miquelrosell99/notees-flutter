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

/// Asset I/O sealing (plan 05): uploads seal + declare (`encrypted` /
/// `mimeType` / `iv`) when custody holds the active workspace's key and keep
/// the plaintext path when keyless; downloads open sealed bytes through the
/// custody key and fail honest (StateError) when sealed without one.
///
/// The scrypt KDF (N=131072) is deliberately expensive; the master record is
/// built once for the whole suite.
void main() {
  const password = 'correct horse battery staple';
  const workspaceId = '10000000-0000-4000-8000-0000000000a1';

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

  /// Dio that answers asset upload (echoing a canned asset row) and asset
  /// download (serving [blob] for GET /assets/<uuid>), capturing every
  /// request into [captured].
  Dio assetDio(List<RequestOptions> captured, {Uint8List? blob}) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured.add(options);
          if (options.path == '/assets/upload' && options.method == 'POST') {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'uuid': '20000000-0000-4000-8000-0000000000b1',
                'node_uuid': '20000000-0000-4000-8000-0000000000b2',
                'filename': 'photo.png',
                'content_type': 'image/png',
                'category': 'image',
                'size_bytes': 0,
                'url': '/assets/20000000-0000-4000-8000-0000000000b1',
              },
            ));
            return;
          }
          if (options.path.startsWith('/assets/') &&
              options.method == 'GET' &&
              !options.path.endsWith('/info')) {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
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

  group('uploadFile', () {
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
  });

  group('downloadBytes', () {
    const uuid = '20000000-0000-4000-8000-0000000000b1';

    test('plaintext asset (iv null) passes through', () async {
      final captured = <RequestOptions>[];
      final blob = Uint8List.fromList([10, 20, 30]);

      final bytes = await AssetRepository(dio: assetDio(captured, blob: blob))
          .downloadBytes(uuid, iv: null);

      expect(bytes, blob);
    });

    test('sealed asset opens with the custody workspace key', () async {
      final workspaceKey = await installWorkspaceKey();
      final plain = Uint8List.fromList(List<int>.generate(100, (i) => i));
      final sealed = await encryptAssetBytes(workspaceKey, plain);
      final captured = <RequestOptions>[];

      final bytes = await AssetRepository(
        dio: assetDio(captured, blob: sealed.blob),
      ).downloadBytes(uuid, iv: b64uEncode(sealed.iv));

      expect(bytes, plain);
    });

    test('sealed asset without a key throws StateError (honest fallback)',
        () async {
      final workspaceKey = generateWorkspaceKey();
      final plain = Uint8List.fromList([5, 6, 7]);
      final sealed = await encryptAssetBytes(workspaceKey, plain);
      final captured = <RequestOptions>[];

      expect(
        AssetRepository(dio: assetDio(captured, blob: sealed.blob))
            .downloadBytes(uuid, iv: b64uEncode(sealed.iv)),
        throwsA(isA<StateError>()),
      );
    });
  });
}
