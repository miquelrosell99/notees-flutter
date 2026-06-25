class BreadcrumbItem {
  const BreadcrumbItem({
    required this.uuid,
    required this.name,
    required this.displayName,
    this.icon,
    this.isPage = false,
  });

  final String uuid;
  final String name;
  final String displayName;
  final String? icon;
  final bool isPage;

  factory BreadcrumbItem.fromJson(Map<String, dynamic> json) {
    return BreadcrumbItem(
      uuid: json['node_uuid'] as String? ?? json['uuid'] as String? ?? '',
      name: json['name'] as String,
      displayName: json['display_name'] as String? ?? '',
      icon: json['icon'] as String?,
      isPage: json['is_page'] as bool? ?? false,
    );
  }
}
