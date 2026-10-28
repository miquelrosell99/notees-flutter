import 'package:flutter/foundation.dart';

import '../../../data/repositories/prefs_repository.dart';
import '../../../domain/services/srs.dart';

/// Holds the cards scheduler preference for the hub's algorithm toggle.
///
/// Optimistic: [setAlgorithm]/[toggle] update the value and notify BEFORE
/// the repository persists, so the SegmentedButton flips immediately; the
/// repository answers the server when online, the device copy otherwise
/// (the web `nodePrefs.ts` contract).
class CardsPrefsProvider extends ChangeNotifier {
  CardsPrefsProvider({required this._repository});

  final PrefsRepository _repository;

  SrsAlgorithm _algorithm = SrsAlgorithm.fsrs;
  bool _loaded = false;

  SrsAlgorithm get algorithm => _algorithm;
  bool get loaded => _loaded;

  /// Reads the current value (server-authoritative, device fallback).
  Future<void> load() async {
    _algorithm = await _repository.getCardsAlgorithm();
    _loaded = true;
    notifyListeners();
  }

  /// Flips sm2 ↔ fsrs.
  Future<void> toggle() => setAlgorithm(
        _algorithm == SrsAlgorithm.fsrs ? SrsAlgorithm.sm2 : SrsAlgorithm.fsrs,
      );

  /// Optimistic write: the new value is visible before persistence lands.
  Future<void> setAlgorithm(SrsAlgorithm algorithm) async {
    if (algorithm == _algorithm && _loaded) return;
    _algorithm = algorithm;
    _loaded = true;
    notifyListeners();
    await _repository.setCardsAlgorithm(algorithm);
  }
}
