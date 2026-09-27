import './hlc.dart';

/// Envelope schema version this client speaks (`PROTOCOL_VERSION` in
/// `v2/packages/protocol/src/envelope.ts`). v2 made the version mandatory:
/// envelopes without `protocolVersion` are rejected and receivers fail loud
/// on a newer version (WIRE.md §3).
const kRelayProtocolVersion = 2;

/// Provenance-claim shape from `envelope.ts` `clientClaimSchema`
/// (`'web'`, `'cli'`, `'flutter'`, `'agent:<id>'`, …).
final RegExp _clientClaimPattern = RegExp(r'^[a-z][a-z0-9-]*(:[a-z0-9-]+)?$');

/// Standard UUID shape (`z.string().uuid()` in the zod schemas).
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Wire envelope for one operation in the Notees relay protocol v2.
///
/// The server assigns each envelope a sequence number (`seq`) and serves them
/// back via catch-up in ascending seq order; the HLC inside the envelope is
/// causality metadata, not the sync cursor (it resolves last-writer-wins ties
/// in derived state). The wire format is camelCase-only — `envelope.ts` is
/// `.strict()`, so unknown or snake_case keys must fail loud — and every
/// envelope carries `protocolVersion`, `deviceId`, and `timestamp`.
class OperationEnvelope {
  const OperationEnvelope({
    required this.id,
    required this.workspaceId,
    required this.actorId,
    required this.deviceId,
    required this.hlc,
    required this.affectedNodeIds,
    required this.opType,
    required this.payload,
    required this.timestamp,
    this.client,
    this.protocolVersion = kRelayProtocolVersion,
  });

  final String id;
  final String workspaceId;
  final String actorId;

  /// Stable per-install device identity (`client_id.dart`'s client id).
  final String deviceId;

  /// Optional provenance claim: which client produced the operation
  /// (`'flutter'` for this app). `envelope.ts` `clientClaimSchema`.
  final String? client;
  final Hlc hlc;
  final List<String> affectedNodeIds;
  final String opType;
  final Map<String, dynamic> payload;
  final int protocolVersion;

  /// ISO-8601 UTC timestamp; required in v2 (`z.string().datetime()`).
  final String timestamp;

  factory OperationEnvelope.fromJson(Map<String, dynamic> json) {
    final version = json['protocolVersion'];
    if (version is! int) {
      throw FormatException(
        'Relay envelope is missing protocolVersion',
        json['id'],
      );
    }
    if (version > kRelayProtocolVersion) {
      throw FormatException(
        'Relay envelope protocolVersion $version is newer than '
        'supported $kRelayProtocolVersion',
        json['id'],
      );
    }
    if (version != kRelayProtocolVersion) {
      throw FormatException(
        'Relay envelope protocolVersion $version is not supported '
        '(this client speaks v$kRelayProtocolVersion only)',
        json['id'],
      );
    }
    final id = json['id'];
    if (id is! String || !_uuidPattern.hasMatch(id)) {
      throw FormatException('Relay envelope has a missing or non-uuid id', id);
    }
    final workspaceId = json['workspaceId'];
    if (workspaceId is! String || !_uuidPattern.hasMatch(workspaceId)) {
      throw FormatException(
        'Relay envelope has a missing or non-uuid workspaceId',
        id,
      );
    }
    final actorId = json['actorId'];
    if (actorId is! String || !_uuidPattern.hasMatch(actorId)) {
      throw FormatException(
        'Relay envelope has a missing or non-uuid actorId',
        id,
      );
    }
    final deviceId = json['deviceId'];
    if (deviceId is! String || deviceId.isEmpty || deviceId.length > 128) {
      throw FormatException(
        'Relay envelope has a missing or invalid deviceId '
        '(1-128 chars, envelope.ts deviceId)',
        id,
      );
    }
    final client = json['client'];
    if (client != null &&
        (client is! String ||
            client.isEmpty ||
            client.length > 64 ||
            !_clientClaimPattern.hasMatch(client))) {
      throw FormatException(
        "Relay envelope client must look like 'web', 'cli', or 'agent:<id>'",
        id,
      );
    }
    final timestamp = json['timestamp'];
    if (timestamp is! String || DateTime.tryParse(timestamp) == null) {
      throw FormatException(
        'Relay envelope has a missing or invalid timestamp',
        id,
      );
    }
    final hlcJson = json['hlc'];
    if (hlcJson is! Map<String, dynamic>) {
      throw FormatException('Relay envelope has a missing hlc', id);
    }
    final affectedNodeIds = json['affectedNodeIds'];
    if (affectedNodeIds is! List<dynamic>) {
      throw FormatException('Relay envelope has a missing affectedNodeIds', id);
    }
    final opType = json['opType'];
    if (opType is! String || opType.isEmpty) {
      throw FormatException('Relay envelope has a missing opType', id);
    }
    final payload = json['payload'];
    if (payload is! Map<String, dynamic>) {
      throw FormatException('Relay envelope has a missing payload', id);
    }
    _validateEncryptedSlot(payload, id);
    return OperationEnvelope(
      id: id,
      workspaceId: workspaceId,
      actorId: actorId,
      deviceId: deviceId,
      client: client,
      hlc: Hlc.fromJson(hlcJson),
      affectedNodeIds: affectedNodeIds.cast<String>(),
      opType: opType,
      payload: payload,
      timestamp: timestamp,
    );
  }

  /// The M3 E2EE slot is reserved in v2 so E2EE never breaks the protocol:
  /// a payload carrying `$e` must be exactly `{"$e": {iv, ct}}` with string
  /// `iv`/`ct` (`envelope.ts` `encryptedPayloadSchema`, `.strict()`).
  static void _validateEncryptedSlot(Map<String, dynamic> payload, Object? id) {
    if (!payload.containsKey(r'$e')) return;
    if (payload.length != 1) {
      throw FormatException(
        'Encrypted payload must be exactly {"\$e": {...}} with no sibling keys',
        id,
      );
    }
    final slot = payload[r'$e'];
    if (slot is! Map<String, dynamic> ||
        slot.length != 2 ||
        slot['iv'] is! String ||
        slot['ct'] is! String) {
      throw FormatException(
        'Encrypted payload slot must have shape {"\$e": {iv, ct}}',
        id,
      );
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'protocolVersion': protocolVersion,
        'workspaceId': workspaceId,
        'actorId': actorId,
        'deviceId': deviceId,
        if (client != null) 'client': client,
        'hlc': hlc.toJson(),
        'affectedNodeIds': affectedNodeIds,
        'opType': opType,
        'timestamp': timestamp,
        'payload': payload,
      };

  OperationEnvelope copyWith({
    String? id,
    String? workspaceId,
    String? actorId,
    String? deviceId,
    String? client,
    Hlc? hlc,
    List<String>? affectedNodeIds,
    String? opType,
    Map<String, dynamic>? payload,
    int? protocolVersion,
    String? timestamp,
  }) =>
      OperationEnvelope(
        id: id ?? this.id,
        workspaceId: workspaceId ?? this.workspaceId,
        actorId: actorId ?? this.actorId,
        deviceId: deviceId ?? this.deviceId,
        client: client ?? this.client,
        hlc: hlc ?? this.hlc,
        affectedNodeIds: affectedNodeIds ?? this.affectedNodeIds,
        opType: opType ?? this.opType,
        payload: payload ?? this.payload,
        protocolVersion: protocolVersion ?? this.protocolVersion,
        timestamp: timestamp ?? this.timestamp,
      );

  @override
  String toString() => 'OperationEnvelope($opType, $hlc, $id)';
}
