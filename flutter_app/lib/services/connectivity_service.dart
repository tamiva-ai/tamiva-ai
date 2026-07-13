import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// v36 / S2.7 — connectivity notifier.
///
/// Wraps `connectivity_plus` so the rest of the app can `await` the
/// next change, or watch a broadcast stream. Used by:
///   - the global offline banner (shows "You're offline" when false)
///   - mutations that retry on reconnect (uploads, idempotent posts)
///
/// We treat all known connection types except `none` as "online".
class ConnectivityService {
  final _ctrl = StreamController<bool>.broadcast();
  final Connectivity _connectivity;

  bool _online = true;
  bool get isOnline => _online;

  ConnectivityService({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity() {
    _init();
  }

  Stream<bool> get onlineStream => _ctrl.stream;

  Future<void> _init() async {
    try {
      final initial = await _connectivity.checkConnectivity();
      _update(_fromList(initial));
    } catch (_) {
      // If the plugin isn't available (e.g. running in a test), assume
      // online so the app remains usable.
      _online = true;
    }
    _connectivity.onConnectivityChanged.listen((event) {
      _update(_fromList(event));
    });
  }

  static bool _fromList(List<ConnectivityResult> results) {
    if (results.isEmpty) return true;
    return results.any((r) => r != ConnectivityResult.none);
  }

  void _update(bool online) {
    if (online == _online) return;
    _online = online;
    _ctrl.add(online);
  }

  Future<void> dispose() async {
    await _ctrl.close();
  }
}