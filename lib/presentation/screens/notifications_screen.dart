import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/notification_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/fleet_card.dart';

/// Lists app notifications with read/unread actions.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<AppNotification> _notifications = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  Future<void> _loadNotifications() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NotificationRepository(dio: auth.dio!);
      final items = await repo.fetchNotifications(includeRead: true);
      if (mounted) {
        setState(() {
          _notifications = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markRead(AppNotification notification) async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NotificationRepository(dio: auth.dio!);
      await repo.markRead(notification.id);
      await _loadNotifications();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markAllRead() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    setState(() => _loading = true);
    try {
      final repo = NotificationRepository(dio: auth.dio!);
      await repo.markAllRead();
      await _loadNotifications();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: _loading ? null : _markAllRead,
            child: const Text('Mark all read'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadNotifications,
        child: _loading && _notifications.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : _buildBody(colors),
      ),
    );
  }

  Widget _buildBody(ColorScheme colors) {
    if (_error != null) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              _error!,
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      );
    }

    if (_notifications.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(child: Text('No notifications')),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _notifications.length,
      itemBuilder: (context, index) {
        final notification = _notifications[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FleetCard(
            child: ListTile(
              leading: Icon(
                notification.isRead
                    ? Icons.notifications_outlined
                    : Icons.notifications_active,
                color: notification.isRead
                    ? colors.onSurfaceVariant
                    : colors.primary,
              ),
              title: Text(notification.message),
              subtitle: Text(
                [
                  if (notification.actorName != null) notification.actorName!,
                  if (notification.nodeName != null) notification.nodeName!,
                  notification.createDate,
                ].join(' · '),
              ),
              trailing: notification.isRead
                  ? null
                  : TextButton(
                      onPressed: () => _markRead(notification),
                      child: const Text('Mark read'),
                    ),
            ),
          ),
        );
      },
    );
  }
}
