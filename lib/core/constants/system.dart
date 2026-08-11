/// Fixed UUIDs that match the backend schema for system classes and properties.
/// Copied from frontend/src/constants/systemProperties.ts.
class SystemClassUuids {
  SystemClassUuids._();

  static const String class_ = '00000000-0000-0000-0001-000000000001';
  static const String page = '00000000-0000-0000-0001-000000000002';
  static const String year = '00000000-0000-0000-0001-000000000003';
  static const String month = '00000000-0000-0000-0001-000000000004';
  static const String day = '00000000-0000-0000-0001-000000000005';
  static const String quote = '00000000-0000-0000-0001-000000000006';
  static const String query = '00000000-0000-0000-0001-000000000007';
  static const String code = '00000000-0000-0000-0001-000000000008';
  static const String asset = '00000000-0000-0000-0001-000000000009';
  static const String whiteboard = '00000000-0000-0000-0001-000000000010';
  static const String card = '00000000-0000-0000-0001-000000000011';
  static const String task = '00000000-0000-0000-0001-000000000012';
  static const String template = '00000000-0000-0000-0001-000000000013';
  static const String comment = '00000000-0000-0000-0001-000000000014';
  static const String table = '00000000-0000-0000-0001-000000000015';
  static const String warning = '00000000-0000-0000-0001-000000000016';
  static const String note = '00000000-0000-0000-0001-000000000017';
  static const String tip = '00000000-0000-0000-0001-000000000018';
  static const String info = '00000000-0000-0000-0001-000000000019';
  static const String danger = '00000000-0000-0000-0001-000000000020';
  static const String success = '00000000-0000-0000-0001-000000000021';
  static const String cloze = '00000000-0000-0000-0001-000000000022';
}

class SystemPropertyUuids {
  SystemPropertyUuids._();

  static const String tags = '00000000-0000-0000-0000-000000000001';
  static const String showHierarchy = '00000000-0000-0000-0000-000000000003';
  static const String usedIn = '00000000-0000-0000-0000-000000000004';
  static const String cover = '00000000-0000-0000-0000-000000000005';
  static const String banner = '00000000-0000-0000-0000-000000000006';
  static const String description = '00000000-0000-0000-0000-000000000009';
  static const String extends_ = '00000000-0000-0000-0000-000000000008';
  static const String whiteboardData = '00000000-0000-0000-0000-000000000010';

  // Task class properties
  static const String taskStatus = '00000000-0000-0000-0003-000000000001';
  static const String taskDeadline = '00000000-0000-0000-0003-000000000002';
  static const String taskScheduled = '00000000-0000-0000-0003-000000000003';
  static const String taskPriority = '00000000-0000-0000-0003-000000000004';
  static const String taskClosedDate = '00000000-0000-0000-0003-000000000005';
  static const String taskRecurrence = '00000000-0000-0000-0003-000000000006';
}

/// Task status names, ordered to match the backend TASK_STATUS_OPTIONS.
class TaskStatuses {
  TaskStatuses._();

  static const List<String> all = [
    'Backlog',
    'Pending',
    'Doing',
    'Reviewing',
    'Done',
    'Cancelled',
  ];

  static const Set<String> closed = {'Done', 'Cancelled'};
}

class SystemPageUuids {
  SystemPageUuids._();

  static const String scratchpad = '00000000-0000-0000-0002-000000000001';
  static const String inbox = '00000000-0000-0000-0002-000000000002';
}
