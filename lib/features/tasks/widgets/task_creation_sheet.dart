import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../shared/widgets/bottom_sheet_drag_handle.dart';
import './task_row.dart';

/// Result returned when [TaskCreationSheet] is confirmed.
class TaskCreationResult {
  const TaskCreationResult({required this.name, this.dueDate});

  final String name;
  final DateTime? dueDate;
}

/// Keyboard-aware modal sheet for quickly creating a task with an
/// optional due date. Mirrors the styling of the task detail sheet.
class TaskCreationSheet extends StatefulWidget {
  const TaskCreationSheet({super.key, required this.onPickDueDate});

  /// Opens the shared date-picker sheet and returns the chosen date.
  final Future<DateTime?> Function() onPickDueDate;

  @override
  State<TaskCreationSheet> createState() => _TaskCreationSheetState();
}

class _TaskCreationSheetState extends State<TaskCreationSheet> {
  final TextEditingController _nameController = TextEditingController();
  DateTime? _dueDate;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _canCreate => _nameController.text.trim().isNotEmpty;

  void _submit() {
    if (!_canCreate) return;
    HapticFeedback.lightImpact();
    Navigator.of(context).pop(
      TaskCreationResult(name: _nameController.text.trim(), dueDate: _dueDate),
    );
  }

  Future<void> _pickDueDate() async {
    HapticFeedback.lightImpact();
    final picked = await widget.onPickDueDate();
    if (picked != null && mounted) setState(() => _dueDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const BottomSheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'New task',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _nameController,
                    autofocus: true,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(hintText: 'Task name'),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 48,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: _pickDueDate,
                      child: Row(
                        children: [
                          Icon(
                            MdiIcons.calendar,
                            color: _dueDate != null ? colors.primary : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _dueDate == null
                                  ? 'Add due date'
                                  : humanizeTaskDueDate(_dueDate!),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: _dueDate != null
                                    ? colors.onSurface
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (_dueDate != null)
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Clear due date',
                              color: colors.onSurfaceVariant,
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                setState(() => _dueDate = null);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _canCreate ? _submit : null,
                        child: const Text('Create'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
