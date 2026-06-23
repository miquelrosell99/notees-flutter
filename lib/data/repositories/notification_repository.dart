import 'package:dio/dio.dart';

class AppNotification {
  AppNotification({
    required this.id,
    required this.type,
    required this.message,
    required this.isRead,
    required this.createDate,
    this.actorUserId,
    this.actorName,
    this.nodeId,
    this.nodeName,
  });

  final String id;
  final String type;
  final String message;
  final bool isRead;
  final String createDate;
  final String? actorUserId;
  final String? actorName;
  final String? nodeId;
  final String? nodeName;

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as String,
        type: json['type'] as String,
        message: json['message'] as String? ?? '',
        isRead: json['is_read'] as bool? ?? false,
        createDate: json['create_date'] as String,
        actorUserId: json['actor_user_id'] as String?,
        actorName: json['actor_name'] as String?,
        nodeId: json['node_id'] as String?,
        nodeName: json['node_name'] as String?,
      );
}

class NotificationRepository {
  NotificationRepository({required this.dio});

  final Dio dio;

  Future<List<AppNotification>> fetchNotifications({bool includeRead = false, int limit = 50}) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/notifications',
      queryParameters: {'include_read': includeRead.toString(), 'limit': limit},
    );
    final data = response.data;
    if (data == null) return [];
    final items = (data['notifications'] ?? data['items']) as List<dynamic>? ?? [];
    return items.map((e) => AppNotification.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<int> unreadCount() async {
    final response = await dio.get<Map<String, dynamic>>(
      '/notifications',
      queryParameters: {'include_read': 'false', 'limit': 1},
    );
    return response.data?['unread_count'] as int? ?? 0;
  }

  Future<void> markRead(String notificationId) async {
    await dio.post<Map<String, dynamic>>('/notifications/$notificationId/read');
  }

  Future<void> markAllRead() async {
    await dio.post<Map<String, dynamic>>('/notifications/read-all');
  }

  Future<void> registerDeviceToken(String token, String platform) async {
    await dio.post<Map<String, dynamic>>(
      '/auth/device-token',
      data: {'token': token, 'platform': platform},
    );
  }
}
