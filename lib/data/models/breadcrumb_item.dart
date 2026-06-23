class BreadcrumbItem {
  const BreadcrumbItem({
    required this.id,
    required this.name,
    required this.displayName,
    this.icon,
    this.isPage = false,
  });

  final int id;
  final String name;
  final String displayName;
  final String? icon;
  final bool isPage;

  factory BreadcrumbItem.fromJson(Map<String, dynamic> json) {
    return BreadcrumbItem(
      id: json['id'] as int,
      name: json['name'] as String,
      displayName: json['display_name'] as String? ?? '',
      icon: json['icon'] as String?,
      isPage: json['is_page'] as bool? ?? false,
    );
  }
}
