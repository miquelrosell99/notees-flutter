import 'package:flutter_test/flutter_test.dart';
import 'package:notees/data/repositories/local_recents_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<LocalRecentsRepository> makeRepo() async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    return LocalRecentsRepository(prefs);
  }

  group('LocalRecentsRepository', () {
    test('empty when nothing was recorded', () async {
      final repo = await makeRepo();
      expect(repo.uuids, isEmpty);
    });

    test('records opens most-recent-first with dedup', () async {
      final repo = await makeRepo();
      await repo.recordOpen('a');
      await repo.recordOpen('b');
      await repo.recordOpen('c');
      await repo.recordOpen('a'); // re-open bumps to the front
      expect(repo.uuids, ['a', 'c', 'b']);
    });

    test('caps at 20 entries', () async {
      final repo = await makeRepo();
      for (var i = 0; i < 25; i++) {
        await repo.recordOpen('uuid-$i');
      }
      expect(repo.uuids.length, 20);
      expect(repo.uuids.first, 'uuid-24');
      expect(repo.uuids.last, 'uuid-5');
    });

    test('ignores empty uuids and survives corrupt prefs data', () async {
      SharedPreferences.setMockInitialValues(const {
        'local_recent_node_uuids': '{not json',
      });
      final prefs = await SharedPreferences.getInstance();
      final repo = LocalRecentsRepository(prefs);
      expect(repo.uuids, isEmpty);
      await repo.recordOpen('');
      expect(repo.uuids, isEmpty);
    });
  });
}
