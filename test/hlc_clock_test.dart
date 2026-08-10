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
      final fixedPhysical = 1234567890123;
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

      clock.update(Hlc(physical: 100, logical: 3), 100);
      final next = clock.advance(100);

      expect(next.physical, 100);
      expect(next.logical, 5);
    });

    test('update keeps higher logical for same physical', () {
      final clock = HlcClock();
      clock.advance(100);
      clock.advance(100);

      clock.update(Hlc(physical: 100, logical: 5), 100);
      final next = clock.advance(100);

      expect(next.physical, 100);
      expect(next.logical, 7);
    });

    test('update ignores older remote HLC', () {
      final clock = HlcClock();
      clock.advance(200);
      clock.advance(200);

      clock.update(Hlc(physical: 100, logical: 99), 200);
      final next = clock.advance(200);

      expect(next.physical, 200);
      expect(next.logical, 3);
    });
  });
}
