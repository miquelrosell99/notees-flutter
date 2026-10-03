import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notees/core/utils/color_presets.dart';
import 'package:notees/domain/models/relay/colors.dart';
import 'package:notees/domain/models/relay/operation_payloads.dart';

/// §34.43 color grammar: node/class `color` is a preset token, a `#RRGGBB`
/// hex, or null (clear) — the retired `var(--color-preset-*)` encoding and
/// garbage are rejected loud. Covers the strict validators, the builders'
/// presence-vs-null sentinel, the ColorPresets rendering/lookup table, and
/// the pickers' token-for-preset write mapping.
void main() {
  const objectId = '0192a000-0000-7000-8000-000000000010';
  const classId = '0192a000-0000-7000-8000-0000000000c5';

  group('color grammar validation (token | #RRGGBB | null)', () {
    for (final (opType, payloadWith) in [
      (
        'object.update',
        (Object? color) => <String, dynamic>{'objectId': objectId, 'color': color},
      ),
      (
        'class.create',
        (Object? color) => <String, dynamic>{'classId': classId, 'color': color},
      ),
      (
        'class.update',
        (Object? color) => <String, dynamic>{'classId': classId, 'color': color},
      ),
    ]) {
      test('$opType accepts all ten preset tokens', () {
        for (final token in colorPresetTokens) {
          final payload = payloadWith(token);
          expect(
            () => OperationPayloads.validatePayload(opType, payload),
            returnsNormally,
            reason: '$opType color "$token"',
          );
        }
      });

      test('$opType accepts a custom hex', () {
        expect(
          () => OperationPayloads.validatePayload(opType, payloadWith('#abcdef')),
          returnsNormally,
        );
      });

      test('$opType accepts a present null (clear)', () {
        expect(
          () => OperationPayloads.validatePayload(opType, payloadWith(null)),
          returnsNormally,
        );
      });

      test('$opType rejects the retired css-var encoding and garbage', () {
        for (final bad in [
          'var(--color-preset-red)',
          '#12345',
          '#1234567',
          'not-a-color',
          'RED',
          '',
          42,
        ]) {
          expect(
            () => OperationPayloads.validatePayload(opType, payloadWith(bad)),
            throwsFormatException,
            reason: '$opType color "$bad"',
          );
        }
      });
    }
  });

  group('color grammar builders', () {
    test('object.update omitted color stays absent; explicit null rides '
        'the wire as a clear', () {
      final omitted = OperationPayloads.objectUpdate(objectId: objectId, icon: 'x');
      expect(omitted.containsKey('color'), isFalse);

      final cleared = OperationPayloads.objectUpdate(
        objectId: objectId,
        color: null,
      );
      expect(cleared.containsKey('color'), isTrue);
      expect(cleared['color'], isNull);
      expect(() => OperationPayloads.validatePayload('object.update', cleared),
          returnsNormally);
    });

    test('object.update explicit null satisfies the at-least-one-field rule',
        () {
      expect(() => OperationPayloads.objectUpdate(objectId: objectId, color: null),
          returnsNormally);
    });

    test('object.update rejects a retired css-var color at build time', () {
      expect(
        () => OperationPayloads.objectUpdate(
          objectId: objectId,
          color: 'var(--color-preset-red)',
        ),
        throwsFormatException,
      );
    });

    test('class.update omitted color stays absent; explicit null clears', () {
      final omitted = OperationPayloads.classUpdate(
        classId: classId,
        name: 'Genre',
      );
      expect(omitted.containsKey('color'), isFalse);

      final cleared = OperationPayloads.classUpdate(classId: classId, color: null);
      expect(cleared.containsKey('color'), isTrue);
      expect(cleared['color'], isNull);
      expect(() => OperationPayloads.validatePayload('class.update', cleared),
          returnsNormally);
    });

    test('class.create accepts a token and keeps hex parity', () {
      final payload = OperationPayloads.classCreate(
        classId: classId,
        name: 'Genre',
        color: 'sky',
      );
      expect(payload['color'], 'sky');
      expect(() => OperationPayloads.validatePayload('class.create', payload),
          returnsNormally);
    });
  });

  group('ColorPresets', () {
    test('entries carry the normative tokens and the exact web hexes', () {
      expect(
        ColorPresets.entries.map((e) => e.$1).toList(),
        colorPresetTokens,
      );
      expect(
        ColorPresets.entries.map((e) => e.$2).toList(),
        [
          '#e34d45',
          '#ed822b',
          '#f3b816',
          '#30a66f',
          '#27a59c',
          '#20a9e9',
          '#4072e7',
          '#9662da',
          '#de4996',
          '#8c857d',
        ],
      );
    });

    test('tryResolve resolves both stored shapes: token and hex', () {
      expect(ColorPresets.tryResolve('sky'), const Color(0xFF20A9E9));
      expect(ColorPresets.tryResolve('#123abc'), const Color(0xFF123ABC));
      expect(ColorPresets.tryResolve('gray'), const Color(0xFF8C857D));
    });

    test('tryResolve still resolves the retired css-var shape for '
        'pre-migration stored rows', () {
      expect(
        ColorPresets.tryResolve('var(--color-preset-green)'),
        const Color(0xFF30A66F),
      );
    });

    test('tryResolve returns null for unset, tokens-case-mismatch, and '
        'garbage', () {
      expect(ColorPresets.tryResolve(null), isNull);
      expect(ColorPresets.tryResolve(''), isNull);
      expect(ColorPresets.tryResolve('SKY'), isNull);
      expect(ColorPresets.tryResolve('#12345'), isNull);
      expect(ColorPresets.tryResolve('not-a-color'), isNull);
    });

    test('tokenFor maps every stored preset shape to its token', () {
      expect(ColorPresets.tokenFor('sky'), 'sky');
      expect(ColorPresets.tokenFor('#20a9e9'), 'sky');
      expect(ColorPresets.tokenFor('var(--color-preset-sky)'), 'sky');
      expect(ColorPresets.tokenFor('#123abc'), isNull);
      expect(ColorPresets.tokenFor(ColorPresets.defaultHex), isNull);
      expect(ColorPresets.tokenFor(null), isNull);
    });
  });

  group('picker write mapping (unit)', () {
    test('every preset swatch writes its token, resolvable to the swatch '
        'hex, and the cream default keeps writing hex', () {
      for (final (token, hex, _) in ColorPresets.entries) {
        // What the pickers now put on the wire for a preset tap:
        final wireValue = token;
        expect(colorPresetTokens, contains(wireValue));
        expect(ColorPresets.tryResolve(wireValue), ColorPresets.fromHex(hex));
      }
      // Quick-capture's custom default is not a preset: it writes hex.
      expect(ColorPresets.tokenFor(ColorPresets.defaultHex), isNull);
      expect(
        ColorPresets.tryResolve(ColorPresets.defaultHex),
        const Color(0xFFF9F5E8),
      );
    });
  });
}
