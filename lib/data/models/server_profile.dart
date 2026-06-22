import 'dart:convert';

/// A self-hosted Notees server that the user has configured.
class ServerProfile {
  ServerProfile({
    required this.id,
    required this.url,
    required this.nickname,
    this.apiKey,
    this.trustSelfSigned = false,
  });

  final String id;
  final String url;
  final String nickname;
  final String? apiKey;
  final bool trustSelfSigned;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'nickname': nickname,
        if (apiKey != null) 'apiKey': apiKey,
        'trustSelfSigned': trustSelfSigned,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
        id: json['id'] as String,
        url: json['url'] as String,
        nickname: json['nickname'] as String,
        apiKey: json['apiKey'] as String?,
        trustSelfSigned: json['trustSelfSigned'] as bool? ?? false,
      );

  String toRaw() => jsonEncode(toJson());

  factory ServerProfile.fromRaw(String raw) =>
      ServerProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  ServerProfile copyWith({
    String? id,
    String? url,
    String? nickname,
    String? apiKey,
    bool? trustSelfSigned,
  }) =>
      ServerProfile(
        id: id ?? this.id,
        url: url ?? this.url,
        nickname: nickname ?? this.nickname,
        apiKey: apiKey ?? this.apiKey,
        trustSelfSigned: trustSelfSigned ?? this.trustSelfSigned,
      );
}
