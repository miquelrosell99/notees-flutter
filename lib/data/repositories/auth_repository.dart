import 'package:dio/dio.dart';

import '../../core/crypto/crypto_custody.dart';
import '../../core/secure/secure_storage.dart';
import '../models/user.dart';

class AuthRepository {
  AuthRepository({
    required this.dio,
    required this.secureStorage,
  });

  final Dio dio;
  final SecureStorage secureStorage;

  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    final Map<String, dynamic> data;
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/auth/login',
        // The server's login body is strict {email, password} — extra
        // keys are rejected with 422 (the old remember_me blocked login).
        data: {
          'email': email,
          'password': password,
        },
      );
      data = response.data!;
    } on DioException catch (e) {
      throw AuthException(_serverMessage(e, 'Login failed'));
    }
    if (data['requires_2fa'] == true) {
      return TwoFactorChallenge(
        preauthToken: data['preauth_token'] as String,
        purpose: data['purpose'] as String? ?? 'verify',
      );
    }
    return LoginSuccess(await _handleTokenResponse(data, password: password));
  }

  /// Completes a login that returned a [TwoFactorChallenge].
  ///
  /// [code] accepts either the current 6-digit TOTP or a one-time backup code.
  Future<User> verifyTwoFactor({
    required String preauthToken,
    required String code,
  }) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/auth/2fa/verify',
        data: {
          'preauth_token': preauthToken,
          'code': code,
        },
      );
      return await _handleTokenResponse(response.data!);
    } on DioException catch (e) {
      throw AuthException(_serverMessage(e, 'Verification failed'));
    }
  }

  /// Extracts the server's error detail from a failed auth request.
  static String _serverMessage(DioException e, String fallback) {
    final body = e.response?.data;
    if (body is Map) {
      // The wire error envelope is {error: {code, message, status}}
      // (errors.ts); older surfaces used a bare `detail`.
      final err = body['error'];
      if (err is Map && err['message'] != null) {
        return err['message'].toString();
      }
      if (body['detail'] != null) return body['detail'].toString();
    }
    return e.message ?? fallback;
  }

  /// The unlock re-prompt (W2 port): re-derives the master key from the
  /// kdf record WITHOUT minting a session — the caller already holds a
  /// live credential. Same per-IP rate limit and per-account lockout as
  /// login: a 429 `account_locked`/`rate_limited` carries the retry-after
  /// message, a 401 `invalid_credentials` is the wrong-password form
  /// error. Returns the kdf record JSON on success.
  Future<Map<String, dynamic>> unlock({
    required String email,
    required String password,
  }) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/auth/unlock',
        data: {
          'email': email,
          'password': password,
        },
      );
      final data = response.data;
      final kdf = data?['kdf'];
      if (kdf is! Map<String, dynamic>) {
        throw const AuthException('Invalid response from server');
      }
      return kdf;
    } on DioException catch (e) {
      throw AuthException(_serverMessage(e, 'Unlock failed'));
    }
  }

  Future<User> register({
    required String email,
    required String password,
    String? name,
    String? surnames,
    String? adminPassword,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/auth/register',
      data: {
        'email': email,
        'password': password,
        // ignore: use_null_aware_elements
        if (name != null) 'name': name,
        // ignore: use_null_aware_elements
        if (surnames != null) 'surnames': surnames,
        // ignore: use_null_aware_elements
        if (adminPassword != null) 'admin_password': adminPassword,
      },
    );
    return _handleTokenResponse(response.data!, password: password);
  }

  Future<User?> checkSession() async {
    final token = await secureStorage.readAccessToken();
    if (token == null || token.isEmpty) return null;
    try {
      final response = await dio.get<Map<String, dynamic>>('/auth/me');
      final data = response.data;
      if (data == null) return null;
      return User.fromJson(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) return null;
      rethrow;
    }
  }

  Future<void> logout() async {
    try {
      await dio.post('/auth/logout');
    } finally {
      await secureStorage.deleteAccessToken();
    }
  }

  Future<User> updateProfile({String? name, String? surnames}) async {
    final response = await dio.put<Map<String, dynamic>>(
      '/auth/me',
      data: {
        // ignore: use_null_aware_elements
        if (name != null) 'name': name,
        // ignore: use_null_aware_elements
        if (surnames != null) 'surnames': surnames,
      },
    );
    return User.fromJson(response.data!);
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await dio.post<Map<String, dynamic>>(
      '/auth/change-password',
      data: {
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    );
  }

  Future<List<ApiKey>> listApiKeys() async {
    final response = await dio.get<List<dynamic>>('/auth/api-keys');
    return (response.data ?? [])
        .map((e) => ApiKey.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ApiKey> createApiKey({required String name}) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/auth/api-keys',
      data: {'name': name},
    );
    return ApiKey.fromJson(response.data!);
  }

  Future<void> revokeApiKey(String keyId) async {
    await dio.delete('/auth/api-keys/$keyId');
  }

  Future<User> _handleTokenResponse(
    Map<String, dynamic> data, {
    String? password,
  }) async {
    // The server returns the session as `token` (plus expiresAt/user/kdf);
    // there is no refresh-token cookie surface.
    final accessToken = data['token'] as String?;
    final userJson = data['user'] as Map<String, dynamic>?;

    if (accessToken == null || userJson == null) {
      throw const AuthException('Invalid response from server');
    }

    // E2EE custody: unwrap + hold the account master key from the kdf
    // record while the password is at hand. A verifier mismatch means the
    // stored record does not open under the authenticated password — a
    // login-level error, never a silent keyless session (and the token is
    // not persisted for a session that failed custody). A passwordless
    // token response (2FA-completed challenge, session reload) never
    // derives a master: it attempts to re-hydrate the persisted record so
    // the signed-in session keeps its workspaces unlocked across app
    // restarts (mirroring the web client's restore at boot; silent when
    // nothing is stored). Keyless operator setups simply never install a
    // master: every workspace stays in the locked semantic (remote `$e`
    // envelopes skip with a counted warning, local writes stay plaintext)
    // until a password sign-in derives the master.
    final kdf = data['kdf'];
    if (password != null && kdf is Map<String, dynamic>) {
      try {
        await deriveMasterKey(password, kdf);
      } on StateError catch (e) {
        throw AuthException(e.message);
      }
    } else if (password == null || kdf == null) {
      await restoreMasterKeyFromStorage();
    }

    secureStorage.writeAccessToken(accessToken);

    return User.fromJson(userJson);
  }
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Result of a login attempt: either a full session or a 2FA challenge that
/// must be completed via [AuthRepository.verifyTwoFactor].
sealed class LoginResult {
  const LoginResult();
}

class LoginSuccess extends LoginResult {
  const LoginSuccess(this.user);
  final User user;
}

/// The server accepted the password but requires a second factor.
/// [preauthToken] is short-lived (~5 minutes) and single-purpose.
class TwoFactorChallenge extends LoginResult {
  const TwoFactorChallenge({
    required this.preauthToken,
    required this.purpose,
  });

  final String preauthToken;

  /// 'verify' for normal logins; 'setup' would mean forced enrollment
  /// (not currently issued by the server).
  final String purpose;
}

class ApiKey {
  ApiKey({
    required this.id,
    required this.name,
    required this.scopes,
    this.key,
    required this.createDate,
  });

  final String id;
  final String name;
  final List<String> scopes;
  final String? key;
  final DateTime createDate;

  factory ApiKey.fromJson(Map<String, dynamic> json) => ApiKey(
        id: json['id'] as String,
        name: json['name'] as String,
        scopes: (json['scopes'] as List<dynamic>?)?.cast<String>() ?? [],
        key: json['key'] as String?,
        createDate: DateTime.parse(json['created_at'] as String),
      );
}
