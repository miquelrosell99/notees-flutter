import 'dart:async';

/// The local derived store's change bus — the Flutter twin of the web
/// workspace client's `subscribe` notify the live query runs ride
/// (`useQueryRun` coalesces re-runs on it).
///
/// Singleton (the IntentReceiver/ReminderService idiom): every store
/// mutation funnel in SyncV2Service notifies after its batch applies (local
/// flush, serverless flush, catch-up/realtime pages, snapshot restores,
/// emitLocal applies); live surfaces subscribe and re-run. Purely a
/// derived-store signal — no wire, no server involvement.
class StoreChangeBus {
  StoreChangeBus._();

  static final StoreChangeBus instance = StoreChangeBus._();

  final StreamController<void> _controller = StreamController<void>.broadcast();

  /// Fires after the derived store changed. Broadcast: any number of
  /// subscribers, late subscribers do not replay.
  Stream<void> get changes => _controller.stream;

  void notify() {
    if (!_controller.isClosed) _controller.add(null);
  }
}
