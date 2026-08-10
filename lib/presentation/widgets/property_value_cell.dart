import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
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
    this.readOnly = false,
    this.required = false,
  });

  final Property property;
  final List<dynamic> values;
  final ValueChanged<dynamic>? onChanged;
  final Future<int> Function(DateTime date)? onPickDate;

  /// Forces the cell into a non-editable, display-only state.
  final bool readOnly;

  /// Shows a required indicator next to the label (display-only; matches the web).
  final bool required;

  @override
  State<PropertyValueCell> createState() => _PropertyValueCellState();
}

class _PropertyValueCellState extends State<PropertyValueCell> {
  final _textController = TextEditingController();
  Timer? _debounce;

  // date_range editing state
  DateTime? _rangeStart;
  DateTime? _rangeEnd;
  String _rangeGranularity = 'day';
  bool _rangeInitialized = false;

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
    // Re-parse the date_range value when the widget is rebuilt with fresh values.
    if (oldWidget.values != widget.values) {
      _rangeInitialized = false;
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

  /// Read-only when explicitly requested or when the property is a system property.
  bool get _isReadOnly => widget.readOnly || widget.property.isReadOnly;

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
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                widget.property.name,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
            ),
            if (widget.required)
              Text(
                ' *',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        _buildEditor(context),
      ],
    );
  }

  Widget _buildEditor(BuildContext context) {
    if (_isReadOnly) return _buildReadOnly(context);
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
      case 'date_range':
        return _buildDateRange();
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
      icon: Icon(MdiIcons.link, size: 18),
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
      icon: Icon(MdiIcons.calendar, size: 18),
      label: Text(currentId == null ? 'Select date' : 'Date node $currentId'),
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        alignment: Alignment.centerLeft,
      ),
    );
  }

  // === Read-only display ===

  Widget _buildReadOnly(BuildContext context) {
    final text = _displayText();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text.isEmpty ? '—' : text,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  String _displayText() {
    switch (widget.property.type) {
      case 'boolean':
        return _boolValue() ? 'Yes' : 'No';
      case 'selection':
        final id = _selectionLineId();
        if (id == null) return '';
        final match = widget.property.options.where((o) => o.id == id);
        return match.isNotEmpty ? match.first.name : '';
      case 'node':
      case 'image':
        final id = _relationTargetId();
        return id == null ? '' : 'Node $id';
      case 'date':
        final id = _relationTargetId();
        return id == null ? '' : 'Date node $id';
      case 'date_range':
        return _formatDateRange();
      default:
        final v = _scalarValue();
        return v == null ? '' : v.toString();
    }
  }

  // === date_range ===

  String _fmtDate(DateTime? d) => d == null
      ? '—'
      : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Parses the stored date_range value (JSON text) into start/end/granularity.
  Map<String, dynamic> _dateRangeMap() {
    if (widget.values.isEmpty) return {};
    final v = widget.values.first;
    dynamic raw;
    if (v is Map<String, dynamic>) {
      raw = v['value'] ?? v['value_text'];
    } else {
      raw = v;
    }
    Map<String, dynamic>? parsed;
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) parsed = decoded;
      } catch (_) {
        // Not valid JSON — fall through to empty.
      }
    } else if (raw is Map<String, dynamic>) {
      parsed = raw;
    }
    if (parsed == null) return {};
    return {
      'start': DateTime.tryParse(parsed['start']?.toString() ?? ''),
      'end': DateTime.tryParse(parsed['end']?.toString() ?? ''),
      'granularity': parsed['granularity']?.toString(),
    };
  }

  String _formatDateRange() {
    final m = _dateRangeMap();
    final start = m['start'] as DateTime?;
    final end = m['end'] as DateTime?;
    if (start == null && end == null) return '';
    final gran = (m['granularity'] as String?) ?? 'day';
    return '${_fmtDate(start)} → ${_fmtDate(end)} ($gran)';
  }

  void _initRange() {
    if (_rangeInitialized) return;
    _rangeInitialized = true;
    final m = _dateRangeMap();
    _rangeStart = m['start'] as DateTime?;
    _rangeEnd = m['end'] as DateTime?;
    _rangeGranularity = (m['granularity'] as String?) ?? 'day';
  }

  void _emitRange() {
    if (_rangeStart == null || _rangeEnd == null) return;
    _onChanged({
      'start': _fmtDate(_rangeStart),
      'end': _fmtDate(_rangeEnd),
      'granularity': _rangeGranularity,
    });
  }

  Future<void> _pickRangeDate({required bool isStart}) async {
    final initial = (isStart ? _rangeStart : _rangeEnd) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null) return;
    setState(() {
      if (isStart) {
        _rangeStart = date;
      } else {
        _rangeEnd = date;
      }
    });
    _emitRange();
  }

  Widget _buildDateRange() {
    _initRange();
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          onPressed: () => _pickRangeDate(isStart: true),
          icon: Icon(MdiIcons.calendar, size: 18),
          label: Text('From ${_fmtDate(_rangeStart)}'),
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
        ),
        TextButton.icon(
          onPressed: () => _pickRangeDate(isStart: false),
          icon: Icon(MdiIcons.calendar, size: 18),
          label: Text('To ${_fmtDate(_rangeEnd)}'),
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
        ),
        DropdownButton<String>(
          value: _rangeGranularity,
          isDense: true,
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(value: 'day', child: Text('Day')),
            DropdownMenuItem(value: 'month', child: Text('Month')),
            DropdownMenuItem(value: 'year', child: Text('Year')),
          ],
          onChanged: (g) {
            if (g == null) return;
            setState(() => _rangeGranularity = g);
            _emitRange();
          },
        ),
      ],
    );
  }
}
