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

    test('the default timeout backstop is 10 minutes (a legit first-sync '
        'snapshot restore takes minutes)', () {
      fakeAsync((async) {
        final status = SyncStatusProvider();
        addTearDown(status.dispose);
        status.beginCatchUp();

        // Well past the old 60s backstop…
        async.elapse(const Duration(minutes: 5));
        expect(status.showCatchUpOverlay, isTrue);

        async.elapse(const Duration(minutes: 5));
        expect(status.showCatchUpOverlay, isFalse);
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

    group('error mode', () {
      test('failCatchUp switches to error mode and cancels the backstop — '
          'the error stays until the user acts', () {
        fakeAsync((async) {
          final status = SyncStatusProvider(timeout: const Duration(seconds: 10));
          addTearDown(status.dispose);
          status.beginCatchUp();

          status.failCatchUp('connection refused');

          expect(status.showCatchUpOverlay, isTrue);
          expect(status.isPullFailed, isTrue);
          expect(status.pullError, 'connection refused');
          expect(status.progressLabel, isNull);
          expect(status.fraction, isNull);

          // Past the timeout: a surfaced error never self-dismisses.
          async.elapse(const Duration(minutes: 5));
          expect(status.showCatchUpOverlay, isTrue);
          expect(status.isPullFailed, isTrue);
        });
      });

      test('updateProgress is ignored in error mode (a stale progress event '
          'never sweeps the error away)', () {
        final status = SyncStatusProvider();
        addTearDown(status.dispose);
        status.beginCatchUp();
        status.failCatchUp('boom');

        status.updateProgress(100, 100);
        expect(status.showCatchUpOverlay, isTrue);
        expect(status.isPullFailed, isTrue);
      });

      test('dismissError hides the overlay and clears the error', () {
        final status = SyncStatusProvider();
        addTearDown(status.dispose);
        status.beginCatchUp();
        status.failCatchUp('boom');

        status.dismissError();

        expect(status.showCatchUpOverlay, isFalse);
        expect(status.isPullFailed, isFalse);
        expect(status.pullError, isNull);
      });

      test('a retry (beginCatchUp) clears the previous error and re-arms '
          'the backstop', () {
        fakeAsync((async) {
          final status = SyncStatusProvider(timeout: const Duration(seconds: 10));
          addTearDown(status.dispose);
          status.beginCatchUp();
          status.failCatchUp('boom');
          expect(status.isPullFailed, isTrue);

          status.beginCatchUp();
          expect(status.isPullFailed, isFalse);
          expect(status.pullError, isNull);
          expect(status.progressLabel, 'Catching up…');

          async.elapse(const Duration(seconds: 11));
          expect(status.showCatchUpOverlay, isFalse);
          expect(status.isPullFailed, isFalse);
        });
      });

      test('a successful retry (endCatchUp) clears the error', () {
        final status = SyncStatusProvider();
        addTearDown(status.dispose);
        status.beginCatchUp();
        status.failCatchUp('boom');

        // The retry's pull completes: AuthProvider ends the catch-up.
        status.endCatchUp();

        expect(status.showCatchUpOverlay, isFalse);
        expect(status.isPullFailed, isFalse);
      });
    });
  });
}
