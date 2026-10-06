class User {
  User({
    required this.id,
    required this.uuid,
    required this.email,
    this.name,
    this.surnames,
    this.profilePic,
    required this.role,
    required this.isActive,
    this.totpEnabled = false,
    this.isLocal = false,
  });

  final String id;
  final String uuid;
  final String email;
  final String? name;
  final String? surnames;
  final String? profilePic;
  final String role;
  final bool isActive;
  final bool totpEnabled;

  /// True for the synthetic offline-mode profile (no server, no auth).
  /// Mirrors the web client's local session shape (`isLocal: true`).
  final bool isLocal;

  String get displayName {
    final parts = [if (name != null) name, if (surnames != null) surnames]
        .whereType<String>()
        .join(' ');
    return parts.isEmpty ? email : parts;
  }

  // Server user: {id, email, displayName, name|null, surnames|null,
  // avatarUrl|null, isAdmin}. Legacy keys (uuid/role/is_active/profile_pic)
  // are read as fallbacks so older payloads keep parsing.
  factory User.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    return User(
      id: id,
      uuid: json['uuid'] as String? ?? id,
      email: json['email'] as String,
      name: json['name'] as String?,
      surnames: json['surnames'] as String?,
      profilePic: json['avatarUrl'] as String? ?? json['profile_pic'] as String?,
      role: json['role'] as String? ?? (json['isAdmin'] == true ? 'admin' : 'member'),
      isActive: json['is_active'] as bool? ?? true,
      totpEnabled: json['totp_enabled'] as bool? ?? false,
      isLocal: json['is_local'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'uuid': uuid,
        'email': email,
        'name': name,
        'surnames': surnames,
        'profile_pic': profilePic,
        'role': role,
        'is_active': isActive,
        'totp_enabled': totpEnabled,
        'is_local': isLocal,
      };
}
