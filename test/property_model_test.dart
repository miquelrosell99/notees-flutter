import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/models/property.dart';

void main() {
  group('Property.fromJson', () {
    test('parses the full server attribute surface', () {
      final json = {
        'id': 7,
        'property_uuid': 'prop-123',
        'name': 'Due',
        'type': 'date_range',
        'icon': 'calendar',
        'multi': false,
        'is_system': true,
        'scope': 'class',
        'node_uuid': 'node-9',
        'icon_visibility': 'before_content',
        'validation_rules': {'required': true, 'min': 1},
        'class_filters': ['cls-1', 'cls-2'],
        'create_date': '2024-01-01',
        'write_date': '2024-02-01',
        'options': [
          {'id': 1, 'selection_line_uuid': 'opt-1', 'name': 'A', 'icon': 'star', 'color': '#fff', 'order': 3},
        ],
      };

      final p = Property.fromJson(json);

      expect(p.id, 7);
      expect(p.uuid, 'prop-123');
      expect(p.nodeUuid, 'node-9');
      expect(p.iconVisibility, 'before_content');
      expect(p.validationRules, {'required': true, 'min': 1});
      expect(p.classFilters, ['cls-1', 'cls-2']);
      expect(p.createDate, '2024-01-01');
      expect(p.writeDate, '2024-02-01');
      expect(p.options.single.icon, 'star');
      expect(p.options.single.sequence, 3);
    });

    test('applies defaults when optional attributes are absent', () {
      final p = Property.fromJson({'id': 1, 'uuid': 'u', 'name': 'Note', 'type': 'text'});

      expect(p.scope, 'global');
      expect(p.iconVisibility, 'hidden');
      expect(p.validationRules, isNull);
      expect(p.classFilters, isEmpty);
      expect(p.isReadOnly, isFalse);
    });

    test('isReadOnly is true for system properties', () {
      final p = Property.fromJson({'id': 1, 'uuid': 'u', 'name': 'Status', 'type': 'selection', 'is_system': true});
      expect(p.isReadOnly, isTrue);
    });

    test('isHiddenSystem is true for underscore-prefixed names', () {
      final hidden = Property.fromJson({'id': 1, 'uuid': 'u', 'name': '_query_ast', 'type': 'text'});
      final visible = Property.fromJson({'id': 2, 'uuid': 'v', 'name': 'query', 'type': 'text'});
      expect(hidden.isHiddenSystem, isTrue);
      expect(visible.isHiddenSystem, isFalse);
    });
  });

  group('SelectionOption.fromJson', () {
    test('parses icon and sequence (order)', () {
      final o = SelectionOption.fromJson({
        'id': 2,
        'selection_line_uuid': 'opt-2',
        'name': 'Done',
        'icon': 'check',
        'color': 'green',
        'order': 5,
      });
      expect(o.uuid, 'opt-2');
      expect(o.icon, 'check');
      expect(o.sequence, 5);
    });

    test('defaults sequence to 0 when order missing', () {
      final o = SelectionOption.fromJson({'id': 3, 'uuid': 'opt-3', 'name': 'Todo'});
      expect(o.sequence, 0);
      expect(o.icon, isNull);
    });
  });

  group('ClassProperty.fromJson', () {
    test('parses hidden, required and default_value', () {
      final cp = ClassProperty.fromJson({
        'class_node_uuid': 'cls-1',
        'class_node_name': 'Task',
        'property_uuid': 'prop-9',
        'property_name': 'Priority',
        'property_type': 'selection',
        'sequence': 2,
        'default_value': 'high',
        'hidden': true,
        'required': true,
      });

      expect(cp.classNodeUuid, 'cls-1');
      expect(cp.propertyUuid, 'prop-9');
      expect(cp.defaultValue, 'high');
      expect(cp.hidden, isTrue);
      expect(cp.required, isTrue);
      expect(cp.sequence, 2);
    });

    test('defaults hidden and required to false', () {
      final cp = ClassProperty.fromJson({'property_uuid': 'p', 'property_name': 'n', 'property_type': 'text'});
      expect(cp.hidden, isFalse);
      expect(cp.required, isFalse);
      expect(cp.defaultValue, isNull);
    });
  });

  group('NodePropertyValue.fromJson', () {
    test('parses nested property and values', () {
      final npv = NodePropertyValue.fromJson({
        'property': {'id': 1, 'property_uuid': 'p-1', 'name': 'Count', 'type': 'integer'},
        'values': [
          {'value_integer': 42},
        ],
      });
      expect(npv.property.uuid, 'p-1');
      expect(npv.values, hasLength(1));
    });
  });
}
