import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

typedef ForegroundProfileSync = Future<bool> Function();

/// Serializes foreground resume and network-recovery sync triggers.
///
/// It intentionally only invokes the caller's opted-in profile runner: app
/// lifecycle events never silently enable syncing for a profile the user has
/// not enabled for background operation.
class ForegroundSyncCoordinator {
  ForegroundSyncCoordinator({
    required ForegroundProfileSync runProfiles,
    Stream<List<ConnectivityResult>>? connectivityChanges,
  }) : _runProfiles = runProfiles,
       _connectivityChanges =
           connectivityChanges ?? Connectivity().onConnectivityChanged;

  final ForegroundProfileSync _runProfiles;
  final Stream<List<ConnectivityResult>>? _connectivityChanges;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _wasOnline = false;
  bool _running = false;
  bool _queued = false;

  void start() {
    _subscription ??= _connectivityChanges?.listen(_onConnectivityChanged);
  }

  Future<void> onAppResumed() => _requestRun();

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final online = results.any((result) => result != ConnectivityResult.none);
    final recovered = online && !_wasOnline;
    _wasOnline = online;
    if (recovered) unawaited(_requestRun());
  }

  Future<void> _requestRun() async {
    if (_running) {
      _queued = true;
      return;
    }
    _running = true;
    try {
      await _runProfiles();
    } finally {
      _running = false;
    }
    if (_queued) {
      _queued = false;
      await _requestRun();
    }
  }
}
