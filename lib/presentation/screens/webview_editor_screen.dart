import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../providers/auth_provider.dart';
import '../widgets/editor_toolbar.dart';
import '../widgets/node_picker.dart';

/// Loads the self-hosted Notees web app in a WebView and navigates to the
/// requested node or view.
class WebviewEditorScreen extends StatefulWidget {
  const WebviewEditorScreen({
    super.key,
    this.nodeId,
    this.initialPath,
  });

  final int? nodeId;
  final String? initialPath;

  @override
  State<WebviewEditorScreen> createState() => _WebviewEditorScreenState();
}

class _WebviewEditorScreenState extends State<WebviewEditorScreen> {
  WebViewController? _controller;
  bool _loading = true;
  bool _editorFocused = false;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  Future<void> _initWebView() async {
    final auth = context.read<AuthProvider>();
    final serverUrl = auth.activeServer?.url ?? '';
    final path = _buildPath();

    // Copy the auth cookies into the WebView cookie jar so the web app is
    // authenticated the same way the native API client is. Both tokens are
    // required: the web app relies on the HTTPOnly access_token cookie for API
    // calls and falls back to /api/auth/refresh when it expires.
    final uri = Uri.tryParse(serverUrl);
    if (uri != null && uri.host.isNotEmpty) {
      final cookieManager = WebViewCookieManager();
      final isSecure = uri.scheme == 'https';

      Future<void> setAuthCookie(String name, String value, String path) async {
        await cookieManager.setCookie(
          WebViewCookie(
            name: name,
            value: value,
            domain: uri.host,
            path: path,
            isSecure: isSecure,
          ),
        );
      }

      final accessToken = await auth.secureStorage.readAccessToken();
      if (accessToken != null && accessToken.isNotEmpty) {
        await setAuthCookie('access_token', accessToken, '/api');
      }

      final refreshToken = await auth.secureStorage.readRefreshToken();
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await setAuthCookie('refresh_token', refreshToken, '/api/auth/refresh');
      }
    }

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (_) {
            setState(() => _loading = false);
            _injectFocusListener();
          },
          onNavigationRequest: (request) {
            final requestUri = Uri.tryParse(request.url);
            final serverUri = Uri.tryParse(serverUrl);
            if (requestUri == null || serverUri == null) {
              return NavigationDecision.prevent;
            }
            final sameOrigin = requestUri.scheme == serverUri.scheme &&
                requestUri.host == serverUri.host &&
                requestUri.port == serverUri.port;
            if (sameOrigin) {
              return NavigationDecision.navigate;
            }
            // External links are left to the system browser.
            return NavigationDecision.prevent;
          },
        ),
      )
      ..addJavaScriptChannel(
        'FlutterBridge',
        onMessageReceived: _onBridgeMessage,
      )
      ..loadRequest(Uri.parse('$serverUrl$path'));

    if (mounted) {
      setState(() => _controller = controller);
    }
  }

  String _buildPath() {
    if (widget.initialPath != null && widget.initialPath!.isNotEmpty) {
      return widget.initialPath!;
    }
    if (widget.nodeId != null) {
      return '/node/${widget.nodeId}';
    }
    return '/';
  }

  void _onBridgeMessage(JavaScriptMessage message) {
    try {
      final payload = jsonDecode(message.message) as Map<String, dynamic>;
      final method = payload['method'] as String?;
      final args = payload['args'] as Map<String, dynamic>? ?? {};

      switch (method) {
        case 'openServerSettings':
          _showServerSettings();
        case 'shareText':
          _shareText(args['text'] as String? ?? '');
        case 'openUrl':
          _openExternalUrl(args['url'] as String? ?? '');
        case 'reportDrawerState':
          // Handled implicitly by the WebView; could update native back nav.
          break;
        case 'editorFocusChanged':
          _handleEditorFocusChanged(args['focused'] as bool? ?? false);
      }
    } on FormatException {
      // Ignore malformed bridge messages.
    }
  }

  void _handleEditorFocusChanged(bool focused) {
    if (_editorFocused != focused && mounted) {
      setState(() => _editorFocused = focused);
    }
  }

  Future<void> _injectFocusListener() async {
    try {
      await _controller?.runJavaScript('''
        (function() {
          if (window.__noteesFocusListenerInstalled) return;
          window.__noteesFocusListenerInstalled = true;
          window.addEventListener('notees:editor-focus-changed', function(event) {
            if (window.FlutterBridge && window.FlutterBridge.postMessage) {
              window.FlutterBridge.postMessage(JSON.stringify({
                method: 'editorFocusChanged',
                args: { focused: Boolean(event.detail && event.detail.focused) }
              }));
            }
          });
        })();
      ''');
    } catch (e) {
      // Ignore injection failures — the toolbar will fall back to keyboard visibility.
    }
  }

  Future<void> _sendEditorCommand(String command) async {
    try {
      await _controller?.runJavaScript('window.noteesMobileEditor.$command');
    } catch (e) {
      // Ignore command failures when the bridge is not ready.
    }
  }

  Future<void> _insertLinkFromPicker() async {
    final auth = context.read<AuthProvider>();
    if (auth.dio == null) return;

    final node = await NodePicker.show(
      context,
      dio: auth.dio!,
      title: 'Link to page',
    );
    if (node == null || !mounted) return;

    final escaped = node.displayName.replaceAll('"', '\\"').replaceAll('\n', ' ');
    await _sendEditorCommand('insertLinkWithText("$escaped")');
  }

  void _showServerSettings() {
    HapticFeedback.lightImpact();
    // TODO: show native server switcher bottom sheet
  }

  void _shareText(String text) {
    HapticFeedback.lightImpact();
    // TODO: invoke share_plus
  }

  void _openExternalUrl(String url) {
    HapticFeedback.lightImpact();
    // TODO: invoke url_launcher
  }

  Future<void> _onBackPressed() async {
    if (await _controller?.canGoBack() == true) {
      await _controller?.goBack();
      return;
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notees'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _onBackPressed,
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                if (_controller != null)
                  WebViewWidget(controller: _controller!)
                else
                  const Center(child: CircularProgressIndicator()),
                if (_loading)
                  const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
          EditorToolbar(
            visible: keyboardVisible || _editorFocused,
            onCommand: _sendEditorCommand,
            onInsertLink: _insertLinkFromPicker,
          ),
        ],
      ),
    );
  }
}
