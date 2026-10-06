import 'package:flutter_test/flutter_test.dart';
import 'package:notees/domain/models/relay/hlc.dart';
import 'package:notees/domain/services/hlc_clock.dart';

void main() {
  group('HlcClock', () {
    test('advances physical time when wall clock moves forward', () {
      final clock = HlcClock();
      final before = DateTime.now().millisecondsSinceEpoch;
      final hlc = clock.advance();
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(hlc.physical, greaterThanOrEqualTo(before));
      expect(hlc.physical, lessThanOrEqualTo(after));
      expect(hlc.logical, 0);
      expect(clock.last, hlc);
    });

    test('increments logical counter for same physical time', () {
      final clock = HlcClock();
      const fixedPhysical = 1234567890123;
      final first = clock.advance(fixedPhysical);
      final second = clock.advance(fixedPhysical);
      final third = clock.advance(fixedPhysical);

      expect(first.physical, fixedPhysical);
      expect(second.physical, fixedPhysical);
      expect(third.physical, fixedPhysical);
      expect(first.logical, 0);
      expect(second.logical, 1);
      expect(third.logical, 2);
    });

    test('resets logical counter when physical time advances', () {
      final clock = HlcClock();
      clock.advance(100);
      clock.advance(100);
      final next = clock.advance(101);

      expect(next.physical, 101);
      expect(next.logical, 0);
    });

    test('update moves clock forward to remote HLC', () {
      final clock = HlcClock();
      clock.advance(50);

      clock.update(const Hlc(physical: 100, logical: 3), 100);
      final next = clock.advance(100);

      expect(next.physical, 100);
      expect(next.logical, 5);
    });

    test('update keeps higher logical for same physical', () {
      final clock = HlcClock();
      clock.advance(100);
      clock.advance(100);

      clock.update(const Hlc(physical: 100, logical: 5), 100);
      final next = clock.advance(100);

      expect(next.physical, 100);
      expect(next.logical, 7);
    });

    test('update ignores older remote HLC', () {
      final clock = HlcClock();
      clock.advance(200);
      clock.advance(200);

      clock.update(const Hlc(physical: 100, logical: 99), 200);
      final next = clock.advance(200);

      expect(next.physical, 200);
      expect(next.logical, 3);
    });
  });

  // Direct port of the branch matrix in `packages/protocol/src/hlc.ts`
  // Clock.update/advance: physical = max(wall, last.physical,
  // received.physical); the logical component then resolves by which
  // operand(s) won the max. Pins the Dart clock to the TypeScript norm so it
  // cannot drift (same matrix as the GTK client's test_clock.py).
  group('hlc.ts parity matrix', () {
    HlcClock seeded(int physical, int logical) {
      final clock = HlcClock();
      clock.advance(physical);
      for (var i = 0; i < logical; i++) {
        clock.advance(physical);
      }
      return clock;
    }

    final updateCases = [
      // (last, received, wallClock, expected)
      // physical == last.physical == received.physical → max logical + 1
      ((100, 5), (100, 3), 100, (100, 6)),
      ((100, 5), (100, 9), 90, (100, 10)),
      // physical == last.physical only → last logical + 1
      ((200, 5), (100, 3), 150, (200, 6)),
      ((200, 5), (100, 3), 200, (200, 6)),
      // physical == received.physical only → received logical + 1
      ((100, 5), (200, 3), 150, (200, 4)),
      ((100, 5), (150, 9), 120, (150, 10)),
      // fresh wall clock beats both → logical resets to 0
      ((100, 5), (150, 3), 200, (200, 0)),
      ((100, 5), (50, 3), 200, (200, 0)),
    ];

    for (final (last, received, wall, expected) in updateCases) {
      test(
        'update last=$last received=$received wall=$wall '
        '→ ($expected)',
        () {
          final clock = seeded(last.$1, last.$2);
          final result = clock.update(
            Hlc(physical: received.$1, logical: received.$2),
            wall,
          );
          expect(result.physical, expected.$1);
          expect(result.logical, expected.$2);
        },
      );
    }

    final advanceCases = [
      // (seed, wallClock, expected)
      ((0, 0), 10, (10, 0)), // ahead → reset
      ((10, 3), 10, (10, 4)), // equal → increment
      ((10, 3), 5, (10, 4)), // behind → increment
    ];

    for (final (seed, wall, expected) in advanceCases) {
      test('advance seed=$seed wall=$wall → ($expected)', () {
        final clock = seeded(seed.$1, seed.$2);
        final result = clock.advance(wall);
        expect(result.physical, expected.$1);
        expect(result.logical, expected.$2);
      });
    }
  });
}
