import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/property.dart';
import 'node_picker.dart';

/// Displays and edits a property value.
class PropertyValueCell extends StatefulWidget {
  const PropertyValueCell({
    super.key,
    required this.property,
    required this.values,
    this.onChanged,
    this.onPickDate,
  });

  final Property property;
  final List<dynamic> values;
  final ValueChanged<dynamic>? onChanged;
  final Future<int> Function(DateTime date)? onPickDate;

  @override
  State<PropertyValueCell> createState() => _PropertyValueCellState();
}

class _PropertyValueCellState extends State<PropertyValueCell> {
  final _textController = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _textController.text = _scalarValue().toString();
  }

  @override
  void didUpdateWidget(covariant PropertyValueCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newValue = _scalarValue().toString();
    if (_textController.text != newValue) {
      _textController.text = newValue;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _textController.dispose();
    super.dispose();
  }

  dynamic _scalarValue() {
    if (widget.values.isEmpty) return '';
    final v = widget.values.first;
    if (v is Map<String, dynamic>) {
      return v['value'] ?? v['value_text'] ?? v.toString();
    }
    return v;
  }

  int? _relationTargetId() {
    if (widget.values.isEmpty) return null;
    final v = widget.values.first;
    if (v is int) return v;
    if (v is Map<String, dynamic>) {
      return v['target_node_id'] as int? ?? v['target_id'] as int?;
    }
    return null;
  }

  int? _selectionLineId() {
    if (widget.values.isEmpty) return null;
    final v = widget.values.first;
    if (v is int) return v;
    if (v is Map<String, dynamic>) {
      return v['selection_line_id'] as int? ?? v['id'] as int?;
    }
    return null;
  }

  bool _boolValue() {
    if (widget.values.isEmpty) return false;
    final v = widget.values.first;
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return false;
  }

  void _onChanged(dynamic value) {
    HapticFeedback.lightImpact();
    widget.onChanged?.call(value);
  }

  void _onTextChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      dynamic parsed = value;
      final type = widget.property.type;
      if (type == 'integer') {
        parsed = int.tryParse(value) ?? value;
      } else if (type == 'float' || type == 'number') {
        parsed = double.tryParse(value) ?? value;
      }
      _onChanged(parsed);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.property.name,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 4),
        _buildEditor(context),
      ],
    );
  }

  Widget _buildEditor(BuildContext context) {
    switch (widget.property.type) {
      case 'boolean':
        return Switch(
          value: _boolValue(),
          onChanged: (value) => _onChanged(value),
        );
      case 'selection':
        return _buildSelectionDropdown();
      case 'node':
      case 'image':
        return _buildNodePicker();
      case 'date':
        return _buildDatePicker();
      case 'integer':
        return _buildTextField(
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        );
      case 'float':
      case 'number':
        return _buildTextField(keyboardType: const TextInputType.numberWithOptions(decimal: true));
      case 'url':
        return _buildTextField(keyboardType: TextInputType.url);
      case 'email':
        return _buildTextField(keyboardType: TextInputType.emailAddress);
      case 'text':
      default:
        return _buildTextField();
    }
  }

  Widget _buildTextField({
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: _textController,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: 8),
        border: UnderlineInputBorder(),
      ),
      onChanged: _onTextChanged,
      onSubmitted: (value) {
        _debounce?.cancel();
        _onTextChanged(value);
      },
    );
  }

  Widget _buildSelectionDropdown() {
    final currentId = _selectionLineId();
    final options = widget.property.options;
    return DropdownButtonFormField<int>(
      initialValue: currentId,
      isDense: true,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: 8),
        border: UnderlineInputBorder(),
      ),
      hint: const Text('Select…'),
      items: options
          .map(
            (o) => DropdownMenuItem(
              value: o.id,
              child: Text(o.name),
            ),
          )
          .toList(),
      onChanged: (id) {
        if (id != null) _onChanged(id);
      },
    );
  }

  Widget _buildNodePicker() {
    final currentId = _relationTargetId();
    return TextButton.icon(
      onPressed: () async {
        final node = await NodePicker.show(context, mode: NodePickerMode.any);
        if (node != null) _onChanged(node.id);
      },
      icon: const Icon(Icons.link, size: 18),
      label: Text(currentId == null ? 'Select node' : 'Node $currentId'),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        alignment: Alignment.centerLeft,
      ),
    );
  }

  Widget _buildDatePicker() {
    final currentId = _relationTargetId();
    return TextButton.icon(
      onPressed: () async {
        final now = DateTime.now();
        final date = await showDatePicker(
          context: context,
          initialDate: now,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (date == null) return;
        final nodeId = await widget.onPickDate?.call(date);
        if (nodeId != null) _onChanged(nodeId);
      },
      icon: const Icon(Icons.calendar_today, size: 18),
      label: Text(currentId == null ? 'Select date' : 'Date node $currentId'),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        alignment: Alignment.centerLeft,
      ),
    );
  }
}
