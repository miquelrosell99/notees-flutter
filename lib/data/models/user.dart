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
  });

  final String id;
  final String uuid;
  final String email;
  final String? name;
  final String? surnames;
  final String? profilePic;
  final String role;
  final bool isActive;

  String get displayName {
    final parts = [if (name != null) name, if (surnames != null) surnames]
        .whereType<String>()
        .join(' ');
    return parts.isEmpty ? email : parts;
  }

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        uuid: json['uuid'] as String,
        email: json['email'] as String,
        name: json['name'] as String?,
        surnames: json['surnames'] as String?,
        profilePic: json['profile_pic'] as String?,
        role: json['role'] as String,
        isActive: json['is_active'] as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'uuid': uuid,
        'email': email,
        'name': name,
        'surnames': surnames,
        'profile_pic': profilePic,
        'role': role,
        'is_active': isActive,
      };
}
