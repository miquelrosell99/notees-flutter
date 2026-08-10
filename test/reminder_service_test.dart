import 'package:flutter_test/flutter_test.dart';
import 'package:notees/native/reminder_service.dart';

void main() {
  group('ReminderService', () {
    test('exposes a singleton instance', () {
      expect(ReminderService.instance, same(ReminderService.instance));
    });

    test('ReminderSnoozeEvent carries uuid and duration', () {
      const event = ReminderSnoozeEvent(
        taskUuid: '00000000-0000-0000-0000-000000000001',
        duration: Duration(hours: 1),
      );

      expect(event.taskUuid, '00000000-0000-0000-0000-000000000001');
      expect(event.duration, const Duration(hours: 1));
    });

    test('streams are broadcast streams', () {
      // The service exposes broadcast streams for taps and snoozes. Full
      // end-to-end testing of exact alarms is not feasible in unit/widget tests
      // because scheduling relies on Android AlarmManager and the
      // flutter_local_notifications MethodChannel, which are only available on
      // a real device or emulator. We therefore only verify that the public
      // streams exist and are broadcast streams.
      final service = ReminderService.instance;

      expect(service.onTaskTapped.isBroadcast, isTrue);
      expect(service.onSnooze.isBroadcast, isTrue);
    });
  });
}
