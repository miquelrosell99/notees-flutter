import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../data/repositories/relay_client.dart';
import '../../domain/models/relay/payload_crypto.dart';
import '../secure/secure_storage.dart';

/// Crypto custody — client-side key custody for the E2EE boundary
/// (`apps/web/src/core/crypto-custody.ts` port).
///
/// The account master key lives in a module-level single slot (one account
/// per session), unwrapped from the login response's kdf record at auth
/// time — and PERSISTED at derive time in OS-keystore-backed secure storage
/// (the `master_key` record, mirroring the web client's IndexedDB
/// `notees-custody` persistence; owner decision 2026-11-04, replacing the
/// earlier memory-only ruling so a signed-in session survives an app
/// restart without re-unlocking). Raw workspace keys stay memory-only and
/// are cleared on sign-out. [ensureWorkspaceKey] fetches the wrapped key
/// (unwrap) or generates + wraps + stores one (404), returning the
/// workspace key for the sync service's boundary setter.
///
/// A session whose sign-in carries no kdf record (keyless operator setups)
/// simply never installs a master: every workspace stays in the locked
/// semantic (remote `$e` envelopes skip with a counted warning, local
/// writes stay plaintext) until a password sign-in derives the master. A
/// session restored from a stored token attempts [restoreMasterKeyFromStorage]
/// to re-hydrate the persisted master; the restore is silent on absence.

SecretKey? _masterKey;

/// The workspace the session currently has open (noted by the auth provider
/// on every active-workspace switch, keyless sessions included).
String? _activeWorkspaceId;

/// Raw workspace keys, in memory only, keyed by workspace id.
final _workspaceKeys = <String, SecretKey>{};

/// In-flight ensure flights, keyed by workspace id: concurrent first-opens
/// share ONE flight (first write wins server-side, so they converge on the
/// same key instead of racing two PUTs).
final _inFlightEnsures = <String, Future<SecretKey>>{};

/// The expected raw master-key length; a persisted record of any other size
/// is corrupt and restore skips it.
const _masterKeyLength = 32;

/// Injectable persistence seam for the derived account master key —
/// the counterpart of the web client's `MasterKeyStore`
/// (`apps/web/src/core/master-key-storage.ts`). Tests inject an in-memory
/// fake (`flutter_secure_storage` is unimplemented on the Dart VM).
abstract class MasterKeyStore {
  Future<void> write(Uint8List keyBytes);
  Future<Uint8List?> read();
  Future<void> delete();
}

/// The default [MasterKeyStore]: the raw 32 key bytes base64-encoded under
/// the `master_key` record of the OS-keystore-backed secure storage. Read
/// failures (missing plugin, corrupt base64) surface as null.
class SecureStorageMasterKeyStore implements MasterKeyStore {
  SecureStorageMasterKeyStore([this._storage = const SecureStorage()]);

  final SecureStorage _storage;

  @override
  Future<void> write(Uint8List keyBytes) =>
      _storage.writeMasterKey(base64Encode(keyBytes));

  @override
  Future<Uint8List?> read() async {
    final encoded = await _storage.readMasterKey();
    if (encoded == null) return null;
    try {
      return base64Decode(encoded);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> delete() => _storage.deleteMasterKey();
}

MasterKeyStore? _defaultStore;

/// Test injection seam, mirroring the web client's
/// `setMasterKeyStoreForTests`: [store] replaces the default (null models an
/// unavailable store), `null` with [reset] restores the default.
MasterKeyStore? _injectedStore;
bool _storeInjected = false;

@visibleForTesting
void setMasterKeyStoreForTests(MasterKeyStore? store, {bool reset = false}) {
  if (reset) {
    _storeInjected = false;
    _injectedStore = null;
    return;
  }
  _storeInjected = true;
  _injectedStore = store;
}

MasterKeyStore? _resolveStore() {
  if (_storeInjected) return _injectedStore;
  return _defaultStore ??= SecureStorageMasterKeyStore();
}

/// Warn-once flag for the best-effort persist: a failed write logs a single
/// warning (the memory-only fallback and the locked banner cover it, same
/// as the web client's bounded persist).
bool _persistWarned = false;

/// Drops the in-memory slot WITHOUT touching the persisted record — a test
/// hook that models an app restart (the persisted record survives; the
/// module state does not).
@visibleForTesting
void resetInMemoryCustodyForTests() {
  _masterKey = null;
  _activeWorkspaceId = null;
  _workspaceKeys.clear();
}

/// Whether this session holds an account master key.
bool get hasMasterKey => _masterKey != null;

/// Notes the session's active workspace (called on every workspace switch).
/// With no master held the key cache stays empty, so asset I/O keeps the
/// honest plaintext path regardless.
void noteActiveWorkspace(String workspaceId) {
  _activeWorkspaceId = workspaceId;
}

/// The raw workspace key for the active workspace, or null when the
/// workspace is locked (keyless session, or the ensure failed/offline).
/// Asset I/O seals uploads and opens sealed downloads through this — the
/// web client's asset layer reads its custody cache the same way.
SecretKey? get activeWorkspaceKey {
  final id = _activeWorkspaceId;
  return id == null ? null : _workspaceKeys[id];
}

/// Unwraps the account master key from the login kdf record and holds it in
/// the session slot, replacing any previous account's key. Throws
/// [StateError] at the verifier on a wrong password — the failure surfaces
/// as a login error, never a silent unencrypted session. The raw key bytes
/// are persisted fire-and-forget so a later app start within the signed-in
/// session re-hydrates silently (mirroring the web client's derive-time
/// persist); the write never blocks the caller and a failure only logs,
/// warn-once.
Future<SecretKey> deriveMasterKey(
  String password,
  Map<String, dynamic> kdfJson,
) async {
  final key = await unwrapMasterKey(password, KdfRecord.fromJson(kdfJson));
  _masterKey = key;
  _workspaceKeys.clear();
  unawaited(_persistMasterKey(key));
  return key;
}

Future<void> _persistMasterKey(SecretKey key) async {
  final store = _resolveStore();
  if (store == null) return;
  try {
    await store.write(Uint8List.fromList(await key.extractBytes()));
  } catch (e) {
    if (!_persistWarned) {
      _persistWarned = true;
      debugPrint('crypto_custody: master key not persisted — app restarts '
          'will ask for the password again: $e');
    }
  }
}

/// Re-hydrates the master key slot from the persisted record (app start
/// with a stored session token, a 2FA-completed challenge, or a keyless
/// token response). Fully silent: no record, an unavailable store, or a
/// corrupt read all leave the slot untouched — the locked workspace refusal
/// and the unlock re-prompt cover the outcome. Only fills the slot when it
/// is empty; returns whether the slot now holds a key.
Future<bool> restoreMasterKeyFromStorage() async {
  if (_masterKey != null) return true;
  final store = _resolveStore();
  if (store == null) return false;
  try {
    final bytes = await store.read();
    if (bytes == null || bytes.length != _masterKeyLength) return false;
    _masterKey = SecretKey(bytes);
    _workspaceKeys.clear();
    return true;
  } catch (_) {
    return false;
  }
}

/// Drops the session's master key and every raw workspace key (sign-out,
/// server switch, a rejected credential) and deletes the persisted record —
/// session end reverts to the password, mirroring the web client's
/// `clearCryptoCustody`. The deletion is best-effort fire-and-forget.
void clearCryptoCustody() {
  _masterKey = null;
  _activeWorkspaceId = null;
  _workspaceKeys.clear();
  final store = _resolveStore();
  if (store == null) return;
  unawaited(store.delete().catchError((Object _) {}));
}

/// The workspace's raw key: fetch + unwrap when the server holds a wrapped
/// key; generate + wrap + store when keyless (404). Concurrent calls for
/// the same workspace share one flight. A PUT rejected with 409 (first
/// write wins — a concurrent device stored its key first) re-fetches the
/// winner's key and unwraps THAT; a stored key that does not open under
/// this master is a real error state (thrown, never silently degraded).
///
/// Throws [StateError] when no master key is held — callers gate on
/// [hasMasterKey] first.
Future<SecretKey> ensureWorkspaceKey(Dio dio, String workspaceId) async {
  final master = _masterKey;
  if (master == null) {
    throw StateError('no master key held; password sign-in required');
  }
  final cached = _workspaceKeys[workspaceId];
  if (cached != null) return cached;
  final shared = _inFlightEnsures[workspaceId];
  if (shared != null) return shared;
  final base = _ensureWorkspaceKeyFlight(dio, workspaceId, master);
  final flight = base.whenComplete(() {
    // Block body on purpose: the removed map value IS this flight — an
    // arrow body would return it and deadlock whenComplete on itself.
    _inFlightEnsures.remove(workspaceId);
  });
  _inFlightEnsures[workspaceId] = flight;
  return flight;
}

Future<SecretKey> _ensureWorkspaceKeyFlight(
  Dio dio,
  String workspaceId,
  SecretKey master,
) async {
  final relay = RelayClient(dio: dio);
  final wrapped = await relay.fetchWorkspaceKey(workspaceId);
  late final SecretKey workspaceKey;
  if (wrapped == null) {
    final generated = generateWorkspaceKey();
    try {
      await relay.storeWorkspaceKey(
        workspaceId,
        await wrapWorkspaceKey(master, generated),
      );
      workspaceKey = generated;
    } on DioException catch (error) {
      // First write wins: 409 means a concurrent device stored its key
      // first — adopt the winner's key instead of splitting the workspace.
      if (error.response?.statusCode == 409) {
        final winner = await relay.fetchWorkspaceKey(workspaceId);
        if (winner == null) {
          throw StateError(
            'workspace key disappeared between the 409 and the re-fetch',
          );
        }
        workspaceKey = await _unwrapOrWrongMaster(master, winner);
      } else {
        rethrow;
      }
    }
  } else {
    workspaceKey = await _unwrapOrWrongMaster(master, wrapped);
  }
  _workspaceKeys[workspaceId] = workspaceKey;
  return workspaceKey;
}

Future<SecretKey> _unwrapOrWrongMaster(SecretKey master, String wrapped) async {
  try {
    return await unwrapWorkspaceKey(master, wrapped);
  } catch (_) {
    throw StateError(
      'wrong master key for this workspace: the stored key was wrapped '
      'for a different account password',
    );
  }
}

/// Fail-loud open refusal (the owner ruling, superseding keyless-open):
/// the workspace is encrypted and this session holds no master key. Thrown
/// BEFORE any selection is persisted — a keyed workspace never opens
/// keyless. The caller surfaces the message; a password sign-in re-derives
/// the master key and the next open unlocks.
class EncryptedWorkspaceLockedError implements Exception {
  EncryptedWorkspaceLockedError(this.workspaceId);

  final String workspaceId;

  @override
  String toString() =>
      'This workspace is encrypted — sign in with your password to open it.';
}

/// The custody outcome of an open attempt (`resolveWorkspaceKey` in
/// `apps/web/src/ui/app/store-connection.ts`): [key] seals the open when
/// this session can supply it; [locked] reports a keyed workspace this
/// session cannot open.
class WorkspaceKeyResolution {
  const WorkspaceKeyResolution({required this.key, required this.locked});

  final SecretKey? key;
  final bool locked;
}

/// Resolves the workspace key for an open, fail-loud:
///
/// - Master key held: fetch-or-ensure; on failure probe the wrapped-key row
///   — a row proves the workspace is keyed (locked); a probe failure with a
///   non-HTTP original error (a crypto/unwrap failure) also reports locked,
///   so an open never degrades silently without the sign-in guidance. An
///   HTTP failure with no stored key is genuinely keyless.
/// - No master key (a keyless operator session, or a restored session whose
///   persisted master key was absent/corrupt): the wrapped-key row needs
///   only membership, not the master — a row means locked, no row means
///   keyless.
///
/// Flutter sessions are always user (session-token) sessions; the web's
/// API-key-session arm (the workspaces listing's `encrypted` flag, the key
/// route being user custody) has no counterpart sign-in mode here.
Future<WorkspaceKeyResolution> resolveWorkspaceKey(
  Dio dio,
  String workspaceId,
) async {
  final relay = RelayClient(dio: dio);
  final master = _masterKey;
  if (master != null) {
    try {
      return WorkspaceKeyResolution(
        key: await ensureWorkspaceKey(dio, workspaceId),
        locked: false,
      );
    } catch (error) {
      final wrapped = await relay
          .fetchWorkspaceKey(workspaceId)
          .catchError((Object _) => null);
      if (wrapped != null) {
        return const WorkspaceKeyResolution(key: null, locked: true);
      }
      return WorkspaceKeyResolution(key: null, locked: error is! DioException);
    }
  }
  final wrapped =
      await relay.fetchWorkspaceKey(workspaceId).catchError((Object _) => null);
  if (wrapped != null) return const WorkspaceKeyResolution(key: null, locked: true);
  return const WorkspaceKeyResolution(key: null, locked: false);
}
