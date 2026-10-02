import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/models/node.dart';
import 'package:notees/features/home/screens/home_screen.dart';

void main() {
  Node block(String displayName) => Node(
        id: 0,
        uuid: '11111111-2222-3333-4444-555555555555',
        name: '',
        displayName: displayName,
      );

  group('composeTodayPeek', () {
    test('joins the first non-empty child texts (max 3)', () {
      final peek = composeTodayPeek([
        block('First line'),
        block('Second line'),
        block('Third line'),
        block('Fourth line'),
      ]);
      expect(peek, 'First line · Second line · Third line');
    });

    test('skips empty and untitled children', () {
      final peek = composeTodayPeek([
        block(''),
        block('Real content'),
        block('Untitled'),
        block('More content'),
      ]);
      expect(peek, 'Real content · More content');
    });

    test('empty when the note has no body yet', () {
      expect(composeTodayPeek(const []), '');
      expect(composeTodayPeek([block(''), block('Untitled')]), '');
    });
  });
}
