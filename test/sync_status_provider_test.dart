import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/features/home/providers/sync_status_provider.dart';

void main() {
  group('SyncStatusProvider (catching-up overlay)', () {
    test('beginCatchUp shows the overlay with a plain label and no fraction',
        () {
      final status = SyncStatusProvider();
      addTearDown(status.dispose);

      expect(status.showCatchUpOverlay, isFalse);
      expect(status.progressLabel, isNull);

      status.beginCatchUp();

      expect(status.showCatchUpOverlay, isTrue);
      expect(status.fraction, isNull);
      expect(status.progressLabel, 'Catching up…');
    });

    test('updateProgress sets the fraction and a floored percent label',
        () {
      final status = SyncStatusProvider();
      addTearDown(status.dispose);
      status.beginCatchUp();

      status.updateProgress(40, 100);
      expect(status.fraction, 0.4);
      expect(status.progressLabel, 'Catching up… 40%');

      // Floored, not rounded.
      status.updateProgress(1, 3);
      expect(status.progressLabel, 'Catching up… 33%');
    });

    test('a progress event that caught up ends the overlay', () {
      final status = SyncStatusProvider();
      addTearDown(status.dispose);
      status.beginCatchUp();
      status.updateProgress(90, 100);
      expect(status.showCatchUpOverlay, isTrue);

      // The final page reports total == applied (no remaining envelopes).
      status.updateProgress(100, 100);
      expect(status.showCatchUpOverlay, isFalse);
      expect(status.fraction, isNull);
      expect(status.progressLabel, isNull);
    });

    test('updateProgress is silent when no overlay is up (later catch-ups '
        'stay silent)', () {
      final status = SyncStatusProvider();
      addTearDown(status.dispose);

      status.updateProgress(40, 100);
      expect(status.showCatchUpOverlay, isFalse);
      expect(status.fraction, isNull);
    });

    test('endCatchUp hides the overlay and clears the fraction', () {
      final status = SyncStatusProvider();
      addTearDown(status.dispose);
      status.beginCatchUp();
      status.updateProgress(40, 100);

      status.endCatchUp();

      expect(status.showCatchUpOverlay, isFalse);
      expect(status.fraction, isNull);
      expect(status.progressLabel, isNull);
    });

    test('re-beginning restarts fresh (no stale fraction, re-armed '
        'backstop)', () {
      fakeAsync((async) {
        final status = SyncStatusProvider(timeout: const Duration(seconds: 10));
        addTearDown(status.dispose);
        status.beginCatchUp();
        status.updateProgress(40, 100);

        async.elapse(const Duration(seconds: 11));
        expect(status.showCatchUpOverlay, isFalse);

        status.beginCatchUp();
        expect(status.showCatchUpOverlay, isTrue);
        expect(status.fraction, isNull);

        // The backstop is armed again for the new catch-up.
        async.elapse(const Duration(seconds: 11));
        expect(status.showCatchUpOverlay, isFalse);
      });
    });

    test('the timeout backstop ends a stuck overlay (safety net, not web '
        'behavior)', () {
      fakeAsync((async) {
        final status = SyncStatusProvider(timeout: const Duration(seconds: 60));
        addTearDown(status.dispose);
        status.beginCatchUp();
        status.updateProgress(10, 100);

        async.elapse(const Duration(seconds: 59));
        expect(status.showCatchUpOverlay, isTrue);

        async.elapse(const Duration(seconds: 1));
        expect(status.showCatchUpOverlay, isFalse);
        expect(status.fraction, isNull);
      });
    });

    test('a completed overlay is not re-ended by the backstop timer', () {
      fakeAsync((async) {
        final status = SyncStatusProvider(timeout: const Duration(seconds: 10));
        addTearDown(status.dispose);
        status.beginCatchUp();
        status.updateProgress(5, 100);

        status.endCatchUp();
        var notifications = 0;
        status.addListener(() => notifications++);

        async.elapse(const Duration(minutes: 1));
        expect(status.showCatchUpOverlay, isFalse);
        expect(notifications, 0);
      });
    });
  });
}
