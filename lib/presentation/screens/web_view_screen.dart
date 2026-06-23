import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/routing/router.dart';
import '../../core/secure/secure_storage.dart';
import '../providers/auth_provider.dart';

/// Loads a Notees React view inside a WebView.
///
/// The current server's JWT access token is forwarded by setting the same
/// HTTP-only cookies the backend uses for the web app, so the user is already
/// authenticated when the page loads.
class NoteesWebViewScreen extends StatefulWidget {
  const NoteesWebViewScreen({
    super.key,
    required this.path,
    this.title,
  });

  /// React-router path to load (e.g. `/graph`, `/whiteboard/{uuid}`).
  final String path;

  /// Screen title shown in the app bar.
  final String? title;

  @override
  State<NoteesWebViewScreen> createState() => _NoteesWebViewScreenState();
}

class _NoteesWebViewScreenState extends State<NoteesWebViewScreen> {
  WebViewController? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final auth = context.read<AuthProvider>();
    final secureStorage = context.read<SecureStorage>();
    final server = auth.activeServer;

    if (server == null) {
      if (mounted) setState(() => _error = 'No server configured');
      return;
    }

    final baseUrl = server.url.endsWith('/')
        ? server.url.substring(0, server.url.length - 1)
        : server.url;
    final url = '$baseUrl${widget.path}';
    final uri = Uri.parse(url);

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (mounted) setState(() => _error = error.description);
          },
          onNavigationRequest: (request) => _handleNavigation(request, baseUrl),
        ),
      )
      ..addJavaScriptChannel(
        'NoteesNative',
        onMessageReceived: _onNativeMessage,
      );

    final accessToken = await secureStorage.readAccessToken();
    final refreshToken = await secureStorage.readRefreshToken();
    final cookieManager = WebViewCookieManager();

    if (accessToken != null && accessToken.isNotEmpty) {
      await cookieManager.setCookie(
        WebViewCookie(
          name: 'access_token',
          value: accessToken,
          domain: uri.host,
          path: '/',
        ),
      );
    }

    if (refreshToken != null && refreshToken.isNotEmpty) {
      await cookieManager.setCookie(
        WebViewCookie(
          name: 'refresh_token',
          value: refreshToken,
          domain: uri.host,
          path: '/',
        ),
      );
    }

    await controller.loadRequest(uri);

    if (mounted) setState(() => _controller = controller);
  }

  NavigationDecision _handleNavigation(NavigationRequest request, String baseUrl) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.navigate;

    // Forward native deep links back to the app router.
    if (uri.scheme == 'notees') {
      _handleNativeDeepLink(uri);
      return NavigationDecision.prevent;
    }

    // Keep navigation inside the WebView only for the current server.
    // Anything else (external links, shares, mailto, etc.) is handed off.
    final serverUri = Uri.parse(baseUrl);
    final isSameHost = uri.host == serverUri.host && uri.port == serverUri.port;
    final isHttp = uri.scheme == 'http' || uri.scheme == 'https';
    if (!isHttp || (uri.host.isNotEmpty && !isSameHost)) {
      _openExternal(request.url);
      return NavigationDecision.prevent;
    }

    return NavigationDecision.navigate;
  }

  void _handleNativeDeepLink(Uri uri) {
    HapticFeedback.lightImpact();

    if (uri.host == 'share') {
      final text = uri.queryParameters['text'] ?? '';
      if (text.isNotEmpty) Share.share(text);
      return;
    }

    final router = GoRouter.of(context);
    final firstSegment = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;

    switch (uri.host) {
      case 'editor':
        final nodeId = int.tryParse(firstSegment ?? '');
        if (nodeId != null) router.push('${Routes.editor}/$nodeId');
      case 'graph':
        router.push(Routes.graph);
      case 'whiteboard':
        router.push(
          firstSegment != null
              ? '${Routes.whiteboard}/$firstSegment'
              : Routes.whiteboard,
        );
      case 'timeline':
        router.push(Routes.timeline);
      case 'gantt':
        router.push(Routes.gantt);
      case 'chart':
        router.push(Routes.chart);
      case 'pivot':
        router.push(Routes.pivot);
      case 'query':
        final nodeId = int.tryParse(firstSegment ?? '');
        if (nodeId != null) router.push('${Routes.query}/$nodeId');
      case 'dashboard':
        router.push(Routes.dashboard);
      case 'pages':
        router.push(Routes.pages);
      case 'tasks':
        router.push(Routes.tasks);
    }
  }

  void _onNativeMessage(JavaScriptMessage message) {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final action = data['action'] as String?;
      switch (action) {
        case 'share':
          final text = data['text'] as String? ?? '';
          if (text.isNotEmpty) Share.share(text);
        case 'openExternal':
          final url = data['url'] as String?;
          if (url != null) _openExternal(url);
      }
    } catch (_) {
      // Ignore malformed messages from the web app.
    }
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _reload() async {
    try {
      await _controller?.reload();
    } catch (_) {
      // Ignore reload errors.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'Notees'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => context.canPop() ? context.pop() : context.go(Routes.dashboard),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _controller == null ? null : _reload,
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_controller != null && _error == null)
            WebViewWidget(controller: _controller!)
          else if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          if (_loading && _error == null)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
