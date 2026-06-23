class Property {
  const Property({
    required this.id,
    required this.uuid,
    required this.name,
    required this.type,
    this.icon,
    this.multi = false,
    this.isSystem = false,
    this.scope = 'global',
    this.options = const [],
  });

  final int id;
  final String uuid;
  final String name;
  final String type;
  final String? icon;
  final bool multi;
  final bool isSystem;
  final String scope;
  final List<SelectionOption> options;

  factory Property.fromJson(Map<String, dynamic> json) {
    final optionsJson = json['options'] as List<dynamic>?;
    return Property(
      id: json['id'] as int,
      uuid: json['uuid'] as String,
      name: json['name'] as String,
      type: json['type'] as String,
      icon: json['icon'] as String?,
      multi: json['multi'] as bool? ?? false,
      isSystem: json['is_system'] as bool? ?? false,
      scope: json['scope'] as String? ?? 'global',
      options: optionsJson?.map((e) => SelectionOption.fromJson(e as Map<String, dynamic>)).toList() ?? const [],
    );
  }
}

class SelectionOption {
  const SelectionOption({
    required this.id,
    required this.name,
    this.color,
  });

  final int id;
  final String name;
  final String? color;

  factory SelectionOption.fromJson(Map<String, dynamic> json) {
    return SelectionOption(
      id: json['id'] as int,
      name: json['name'] as String,
      color: json['color'] as String?,
    );
  }
}

class NodePropertyValue {
  const NodePropertyValue({
    required this.property,
    required this.values,
  });

  final Property property;
  final List<dynamic> values;

  factory NodePropertyValue.fromJson(Map<String, dynamic> json) {
    final propertyJson = json['property'] as Map<String, dynamic>;
    final valuesJson = json['values'] as List<dynamic>?;
    return NodePropertyValue(
      property: Property.fromJson(propertyJson),
      values: valuesJson ?? const [],
    );
  }
}
