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
    this.nodeUuid,
    this.iconVisibility = 'hidden',
    this.validationRules,
    this.classFilters = const [],
    this.createDate,
    this.writeDate,
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
  final String? nodeUuid;
  final String iconVisibility;
  final Map<String, dynamic>? validationRules;
  final List<String> classFilters;
  final String? createDate;
  final String? writeDate;
  final List<SelectionOption> options;

  /// System properties are server-defined and not user-editable (matches the web,
  /// which disables editing for system properties).
  bool get isReadOnly => isSystem;

  /// Internal system properties are prefixed with `_` (e.g. `_query_ast`,
  /// `_whiteboard_data`) and hidden from the UI on the web.
  bool get isHiddenSystem => name.startsWith('_');

  factory Property.fromJson(Map<String, dynamic> json) {
    final optionsJson = json['options'] as List<dynamic>?;
    final classFiltersJson = json['class_filters'] as List<dynamic>?;
    final validationRulesJson = json['validation_rules'];
    return Property(
      id: json['id'] as int,
      uuid: (json['property_uuid'] as String?) ?? (json['uuid'] as String? ?? ''),
      name: json['name'] as String,
      type: json['type'] as String,
      icon: json['icon'] as String?,
      multi: json['multi'] as bool? ?? false,
      isSystem: json['is_system'] as bool? ?? false,
      scope: json['scope'] as String? ?? 'global',
      nodeUuid: json['node_uuid'] as String?,
      iconVisibility: json['icon_visibility'] as String? ?? 'hidden',
      validationRules: validationRulesJson is Map<String, dynamic> ? validationRulesJson : null,
      classFilters: classFiltersJson?.map((e) => e.toString()).toList() ?? const [],
      createDate: json['create_date'] as String?,
      writeDate: json['write_date'] as String?,
      options: optionsJson?.map((e) => SelectionOption.fromJson(e as Map<String, dynamic>)).toList() ?? const [],
    );
  }
}

class SelectionOption {
  const SelectionOption({
    required this.id,
    required this.uuid,
    required this.name,
    this.icon,
    this.color,
    this.sequence = 0,
  });

  final int id;
  final String uuid;
  final String name;
  final String? icon;
  final String? color;
  final int sequence;

  factory SelectionOption.fromJson(Map<String, dynamic> json) {
    return SelectionOption(
      id: json['id'] as int,
      uuid: (json['selection_line_uuid'] as String?) ?? (json['uuid'] as String? ?? ''),
      name: json['name'] as String,
      icon: json['icon'] as String?,
      color: json['color'] as String?,
      sequence: json['order'] as int? ?? json['sequence'] as int? ?? 0,
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

/// Binding between a class and a property. Carries the class-level `hidden`,
/// `required` and `default_value` attributes (the node's own property values
/// endpoint does not include these).
class ClassProperty {
  const ClassProperty({
    required this.classNodeUuid,
    required this.classNodeName,
    required this.propertyUuid,
    required this.propertyName,
    required this.propertyType,
    this.sequence = 0,
    this.defaultValue,
    this.hidden = false,
    this.required = false,
  });

  final String classNodeUuid;
  final String classNodeName;
  final String propertyUuid;
  final String propertyName;
  final String propertyType;
  final int sequence;
  final dynamic defaultValue;
  final bool hidden;
  final bool required;

  factory ClassProperty.fromJson(Map<String, dynamic> json) {
    return ClassProperty(
      classNodeUuid: json['class_node_uuid'] as String? ?? '',
      classNodeName: json['class_node_name'] as String? ?? '',
      propertyUuid: json['property_uuid'] as String? ?? '',
      propertyName: json['property_name'] as String? ?? '',
      propertyType: json['property_type'] as String? ?? 'text',
      sequence: json['sequence'] as int? ?? 0,
      defaultValue: json['default_value'],
      hidden: json['hidden'] as bool? ?? false,
      required: json['required'] as bool? ?? false,
    );
  }
}
