import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';

import '../../data/repositories/relay_client.dart';
import '../../domain/models/relay/payload_crypto.dart';

/// Crypto custody — client-side key custody for the E2EE boundary
/// (`apps/web/src/core/crypto-custody.ts` port).
///
/// The account master key lives in a module-level single slot (one account
/// per session), unwrapped from the login response's kdf record at auth
/// time. Raw workspace keys live ONLY in this module's in-memory cache
/// (never `flutter_secure_storage` — the web client's memory-only threat
/// model) and are cleared on sign-out. [ensureWorkspaceKey] fetches the
/// wrapped key (unwrap) or generates + wraps + stores one (404), returning
/// the workspace key for the sync service's boundary setter.
///
/// A session whose sign-in carries no kdf record (keyless operator setups)
/// simply never installs a master: every workspace stays in the locked
/// semantic (remote `$e` envelopes skip with a counted warning, local
/// writes stay plaintext) until a password sign-in derives the master.

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
/// as a login error, never a silent unencrypted session.
Future<SecretKey> deriveMasterKey(
  String password,
  Map<String, dynamic> kdfJson,
) async {
  final key = await unwrapMasterKey(password, KdfRecord.fromJson(kdfJson));
  _masterKey = key;
  _workspaceKeys.clear();
  return key;
}

/// Drops the session's master key and every raw workspace key (sign-out, or
/// a sign-in whose response carries no kdf record).
void clearCryptoCustody() {
  _masterKey = null;
  _activeWorkspaceId = null;
  _workspaceKeys.clear();
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
