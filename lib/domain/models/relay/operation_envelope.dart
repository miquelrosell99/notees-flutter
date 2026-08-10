import 'hlc.dart';

/// Wire envelope for one operation in the Notees relay protocol.
///
/// The server stores these envelopes in HLC order and serves them back to
/// clients via catch-up. The wire format uses camelCase field names.
class OperationEnvelope {
  const OperationEnvelope({
    required this.id,
    required this.workspaceId,
    required this.actorId,
    required this.hlc,
    required this.affectedNodeIds,
    required this.opType,
    required this.payload,
    this.timestamp,
  });

  final String id;
  final String workspaceId;
  final String actorId;
  final Hlc hlc;
  final List<String> affectedNodeIds;
  final String opType;
  final Map<String, dynamic> payload;
  final String? timestamp;

  factory OperationEnvelope.fromJson(Map<String, dynamic> json) =>
      OperationEnvelope(
        id: json['id'] as String,
        workspaceId: json['workspaceId'] as String,
        actorId: json['actorId'] as String,
        hlc: Hlc.fromJson(json['hlc'] as Map<String, dynamic>),
        affectedNodeIds: (json['affectedNodeIds'] as List<dynamic>)
            .cast<String>(),
        opType: json['opType'] as String,
        payload: json['payload'] as Map<String, dynamic>,
        timestamp: json['timestamp'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
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
        timestamp: timestamp ?? this.timestamp,
      );

  @override
  String toString() => 'OperationEnvelope($opType, $hlc, $id)';
}
