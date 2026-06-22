import 'package:dio/dio.dart';

import '../../core/secure/secure_storage.dart';
import '../models/user.dart';

class AuthRepository {
  AuthRepository({
    required this.dio,
    required this.secureStorage,
  });

  final Dio dio;
  final SecureStorage secureStorage;

  Future<User> login({
    required String email,
    required String password,
    bool rememberMe = false,
  }) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/auth/login',
      data: {
        'email': email,
        'password': password,
        'remember_me': rememberMe,
      },
    );
    return _handleTokenResponse(response.data!);
  }

  Future<User> register({
    required String email,
    required String password,
    String? name,
    String? surnames,
    bool rememberMe = false,
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
        'remember_me': rememberMe,
        // ignore: use_null_aware_elements
        if (adminPassword != null) 'admin_password': adminPassword,
      },
    );
    return _handleTokenResponse(response.data!);
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
      await secureStorage.deleteRefreshToken();
    }
  }

  Future<User> updateProfile({String? name, String? surnames}) async {
    final response = await dio.put<Map<String, dynamic>>(
      '/auth/me',
      data: {
        if (name != null) 'name': name,
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

  User _handleTokenResponse(Map<String, dynamic> data) {
    final accessToken = data['access_token'] as String?;
    final refreshToken = data['refresh_token'] as String?;
    final userJson = data['user'] as Map<String, dynamic>?;

    if (accessToken == null || userJson == null) {
      throw const AuthException('Invalid response from server');
    }

    secureStorage.writeAccessToken(accessToken);
    if (refreshToken != null) {
      secureStorage.writeRefreshToken(refreshToken);
    }

    return User.fromJson(userJson);
  }
}

class AuthException implements Exception {
  const AuthException(this.message);
  final String message;

  @override
  String toString() => message;
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
