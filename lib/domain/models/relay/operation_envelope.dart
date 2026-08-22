import './hlc.dart';

/// Envelope schema version this client speaks (`PROTOCOL_VERSION` in the
/// relay spec). Envelopes with a newer version are rejected on parse.
const kRelayProtocolVersion = 1;

/// Wire envelope for one operation in the Notees relay protocol.
///
/// The server assigns each envelope a sequence number (`seq`) and serves them
/// back via catch-up in ascending seq order; the HLC inside the envelope is
/// causality metadata, not the sync cursor. The wire format uses camelCase
/// field names and every envelope carries `protocolVersion`.
class OperationEnvelope {
  const OperationEnvelope({
    required this.id,
    required this.workspaceId,
    required this.actorId,
    required this.hlc,
    required this.affectedNodeIds,
    required this.opType,
    required this.payload,
    this.protocolVersion = kRelayProtocolVersion,
    this.timestamp,
  });

  final String id;
  final String workspaceId;
  final String actorId;
  final Hlc hlc;
  final List<String> affectedNodeIds;
  final String opType;
  final Map<String, dynamic> payload;
  final int protocolVersion;
  final String? timestamp;

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
    return OperationEnvelope(
      id: json['id'] as String,
      workspaceId: json['workspaceId'] as String,
      actorId: json['actorId'] as String,
      hlc: Hlc.fromJson(json['hlc'] as Map<String, dynamic>),
      affectedNodeIds: (json['affectedNodeIds'] as List<dynamic>)
          .cast<String>(),
      opType: json['opType'] as String,
      payload: json['payload'] as Map<String, dynamic>,
      protocolVersion: version,
      timestamp: json['timestamp'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'protocolVersion': protocolVersion,
        'workspaceId': workspaceId,
        'actorId': actorId,
        'hlc': hlc.toJson(),
        'affectedNodeIds': affectedNodeIds,
        'opType': opType,
        'payload': payload,
        if (timestamp != null) 'timestamp': timestamp,
      };

  OperationEnvelope copyWith({
    String? id,
    String? workspaceId,
    String? actorId,
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
