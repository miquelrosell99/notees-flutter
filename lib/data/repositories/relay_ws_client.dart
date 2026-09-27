import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../domain/models/relay/operation_envelope.dart';

/// WIRE.md §2 framing version; a newer one from the relay fails loud.
const kWsProtocolVersion = 2;

/// Default reconnect backoff after abnormal closes (reset on every hello).
const List<Duration> kDefaultWsReconnectDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 30),
];

/// The relay speaks a NEWER WS framing version: fail loud, never reconnect.
class ProtocolVersionError implements Exception {
  const ProtocolVersionError(this.message);

  final String message;

  @override
  String toString() => 'ProtocolVersionError: $message';
}

/// A malformed frame or envelope from the relay (the connection stays open).
class RealtimeProtocolError implements Exception {
  const RealtimeProtocolError(this.message);

  final String message;

  @override
  String toString() => 'RealtimeProtocolError: $message';
}

/// Server greeting metadata from the last `hello` frame.
class WsHelloInfo {
  const WsHelloInfo({required this.latestSeq, required this.restoreEpoch});

  final int latestSeq;
  final int restoreEpoch;
}

/// Minimal structural socket surface (the Dart port of the TS
/// `WebSocketLike`): the client is written against this interface so tests
/// can inject scripted fakes without a live socket.
abstract class WsConnection {
  Stream<dynamic> get messages;

  bool get isOpen;

  void send(String data);

  void close(int code, String reason);
}

/// [web_socket_channel] adapter used in production.
class WebSocketChannelConnection implements WsConnection {
  WebSocketChannelConnection(this._channel);

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get messages => _channel.stream;

  @override
  bool get isOpen => _channel.closeCode == null;

  @override
  void send(String data) => _channel.sink.add(data);

  @override
  void close(int code, String reason) => _channel.sink.close(code, reason);
}

/// Opens a production socket for [url].
Future<WsConnection> defaultWsConnector(String url) async {
  final channel = WebSocketChannel.connect(Uri.parse(url));
  await channel.ready;
  return WebSocketChannelConnection(channel);
}

typedef WsConnector = Future<WsConnection> Function(String url);

/// Realtime subscriber for one workspace — the relay's acceleration path
/// (WIRE.md §2).
///
/// Framing contract:
///  - server → client `hello` (`wsProtocolVersion`/`restoreEpoch`/
///    `latestSeq`), `ops` (`envelopes` + `seqs` map), `ack` (`savedIds`),
///    `error` (`message`); unknown frame types are ignored;
///  - a `hello`/`ops` with a NEWER framing version fails loud:
///    [ProtocolVersionError] via [onError], the socket is closed and the
///    client NEVER reconnects (silently applying newer framing is the
///    failure mode WIRE.md §2 forbids);
///  - malformed JSON answers the error callback and keeps the connection;
///  - abnormal closes reconnect on the backoff schedule (reset after a
///    successful `hello`); [stop] closes cleanly (code 1000, no reconnect).
///
/// The socket is only an accelerator: the seq cursor on catch-up responses
/// stays the authoritative recovery mechanism — [latestSeq] and
/// [restoreEpoch] expose the last hello so the engine can decide when a
/// catch-up pull is needed after a reconnect.
class RelayWsClient {
  RelayWsClient({
    required this.url,
    this.connector,
    this.onHello,
    this.onOps,
    this.onAck,
    this.onError,
    this.reconnectDelays = kDefaultWsReconnectDelays,
  });

  final String url;
  final WsConnector? connector;
  final void Function(WsHelloInfo hello)? onHello;
  final void Function(
    List<Map<String, dynamic>> envelopes,
    Map<String, int> seqs,
  )?
  onOps;
  final void Function(List<String> savedIds)? onAck;
  final void Function(Object error)? onError;
  final List<Duration> reconnectDelays;

  int _latestSeq = 0;
  int _restoreEpoch = 0;
  int _attempt = 0;
  bool _stopped = true;
  bool _failed = false;
  WsConnection? _connection;
  Future<void>? _loop;
  Completer<void>? _delayInterrupt;

  /// Highest server seq advertised by the last `hello`.
  int get latestSeq => _latestSeq;

  /// Restore epoch advertised by the last `hello`.
  int get restoreEpoch => _restoreEpoch;

  /// True after a fail-loud framing rejection (never reconnects).
  bool get failed => _failed;

  /// True between [start] and [stop].
  bool get running => _loop != null;

  /// Starts the connect/read loop (idempotent while running).
  void start() {
    if (_loop != null) return;
    _stopped = false;
    _failed = false;
    _attempt = 0;
    _loop = _run();
    // A top-level error in the loop must never surface as an unhandled
    // future; everything routes through onError.
    _loop!.ignore();
  }

  /// Stops the stream: clean close (code 1000), interrupt a pending backoff,
  /// never reconnects. Safe to call more than once.
  Future<void> stop() async {
    _stopped = true;
    _delayInterrupt?.complete();
    final connection = _connection;
    _connection = null;
    try {
      connection?.close(1000, 'bye');
    } catch (_) {
      // Already closing/closed.
    }
    final loop = _loop;
    _loop = null;
    if (loop != null) {
      await loop;
    }
  }

  /// Submits a batch over the socket (the acceleration path). Returns false
  /// when no socket is open (callers fall back to HTTP push, which stays
  /// authoritative).
  bool sendBatch(List<OperationEnvelope> envelopes) {
    final connection = _connection;
    if (connection == null || !connection.isOpen) return false;
    try {
      connection.send(jsonEncode({
        'type': 'batch',
        'envelopes': [for (final e in envelopes) e.toJson()],
      }));
    } catch (_) {
      return false;
    }
    return true;
  }

  Future<void> _run() async {
    while (!_stopped && !_failed) {
      WsConnection? connection;
      try {
        connection = await (connector ?? defaultWsConnector)(url);
        if (_stopped) {
          connection.close(1000, 'bye');
          return;
        }
        _connection = connection;
        await for (final message in connection.messages) {
          if (_stopped) break;
          _handleFrame(message);
        }
      } catch (error) {
        _emitError(error);
      } finally {
        if (identical(_connection, connection)) {
          _connection = null;
        }
      }
      if (_stopped || _failed) break;
      final delay =
          reconnectDelays[math.min(_attempt, reconnectDelays.length - 1)];
      _attempt++;
      final interrupt = Completer<void>();
      _delayInterrupt = interrupt;
      await Future.any([Future.delayed(delay), interrupt.future]);
      _delayInterrupt = null;
    }
  }

  void _handleFrame(dynamic raw) {
    Map<String, dynamic> frame;
    try {
      final text = switch (raw) {
        String s => s,
        List<int> bytes => utf8.decode(bytes),
        _ => throw RealtimeProtocolError('frame is not text'),
      };
      final parsed = jsonDecode(text);
      if (parsed is! Map<String, dynamic>) {
        throw const RealtimeProtocolError('frame is not a JSON object');
      }
      frame = parsed;
    } catch (error) {
      // Malformed frames answer the error callback and keep the connection
      // (WIRE.md §2 unknown-frame semantics).
      _emitError(
        error is RealtimeProtocolError
            ? error
            : RealtimeProtocolError('malformed frame: $error'),
      );
      return;
    }

    switch (frame['type']) {
      case 'hello':
        _onHelloFrame(frame);
      case 'ops':
        _onOpsFrame(frame);
      case 'ack':
        final savedIds = frame['savedIds'];
        if (savedIds is List) {
          _emit(onAck, [
            <String>[for (final id in savedIds) '$id'],
          ]);
        }
      case 'error':
        final message = frame['message'];
        _emitError(Exception(message is String ? message : 'relay error'));
      default:
        // Unknown frame types are ignored (WIRE.md §2).
        break;
    }
  }

  void _onHelloFrame(Map<String, dynamic> frame) {
    if (_checkFramingVersion(frame)) return;
    _attempt = 0; // Successful handshake: reset the backoff schedule.
    _latestSeq = _intOrZero(frame['latestSeq']);
    _restoreEpoch = _intOrZero(frame['restoreEpoch']);
    _emit(onHello, [WsHelloInfo(latestSeq: _latestSeq, restoreEpoch: _restoreEpoch)]);
  }

  void _onOpsFrame(Map<String, dynamic> frame) {
    if (_checkFramingVersion(frame)) return;
    final rawEnvelopes = frame['envelopes'];
    if (rawEnvelopes is! List) {
      _emitError(const RealtimeProtocolError('ops frame has no envelopes list'));
      return;
    }
    final envelopes = <Map<String, dynamic>>[];
    for (final raw in rawEnvelopes) {
      if (raw is! Map<String, dynamic>) {
        _emitError(const RealtimeProtocolError(
          'invalid envelope in ops frame: not an object',
        ));
        return; // Drop the frame; the connection stays.
      }
      envelopes.add(raw);
    }
    final rawSeqs = frame['seqs'];
    final seqs = <String, int>{
      if (rawSeqs is Map)
        for (final entry in rawSeqs.entries)
          if (entry.value is int) '${entry.key}': entry.value as int,
    };
    _emit(onOps, [envelopes, seqs]);
  }

  /// Fail loud on a newer framing version; true when the frame was rejected.
  bool _checkFramingVersion(Map<String, dynamic> frame) {
    final version = frame['wsProtocolVersion'];
    if (version is! int || version <= kWsProtocolVersion) return false;
    _failed = true;
    _emitError(ProtocolVersionError(
      'relay WS framing version $version is newer than supported '
      '$kWsProtocolVersion',
    ));
    final connection = _connection;
    if (connection != null) {
      try {
        connection.close(1000, 'unsupported framing version');
      } catch (_) {
        // Already closing/closed.
      }
    }
    return true;
  }

  void _emitError(Object error) {
    if (onError != null) _emit(onError, [error]);
  }

  /// Invokes a consumer callback; a raising consumer never kills the loop.
  void _emit(Function? callback, List<dynamic> args) {
    if (callback == null) return;
    try {
      Function.apply(callback, args);
    } catch (error) {
      // Consumer bugs must not kill the stream; surface via debugPrint.
      // ignore: avoid_print
      print('RelayWsClient: callback raised: $error');
    }
  }

  static int _intOrZero(dynamic value) => value is int ? value : 0;
}

/// Builds the relay WS URL from the REST base URL (`http(s)` → `ws(s)`).
String buildRelayWsUrl(String baseUrl, String workspaceId, String token) {
  var base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  // The Dio base already carries /api (e.g. https://host/api); the WS path
  // appends the relay v2 route under it.
  if (base.endsWith('/api')) {
    base = base.substring(0, base.length - 4);
  }
  if (base.startsWith('https://')) {
    base = 'wss://${base.substring('https://'.length)}';
  } else if (base.startsWith('http://')) {
    base = 'ws://${base.substring('http://'.length)}';
  }
  final wsBase = base;
  final wsToken = Uri.encodeQueryComponent(token);
  return '$wsBase/api/relay/v2/ws/${Uri.encodeQueryComponent(workspaceId)}'
      '?token=$wsToken';
}
