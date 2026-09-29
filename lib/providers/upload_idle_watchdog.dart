import 'dart:async';

import 'package:dio/dio.dart';

/// Aborts an upload whose body stops moving, instead of capping its duration.
///
/// Dio's `sendTimeout` bounds the whole `addStream` of the request body, so
/// with a five minute limit any single object that needs longer (a 300 MB
/// video on an 8 Mbps uplink) failed on every run and blocked every later
/// batch. The body stream is only pulled as the socket accepts data, so the
/// time since the last pulled chunk measures real progress: a black-holed
/// connection still fails after [idleTimeout], a slow but moving one finishes.
final class UploadIdleWatchdog {
  UploadIdleWatchdog({
    required this.idleTimeout,
    required this.cancelToken,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration idleTimeout;

  /// Cancelled when the body stalls; pass the same token to the request.
  final CancelToken cancelToken;
  final DateTime Function() _now;

  Timer? _timer;
  DateTime? _lastProgress;
  bool _timedOut = false;

  /// Whether this watchdog, not the caller, cancelled the request.
  bool get timedOut => _timedOut;

  /// Wraps [source]; listen to the result exactly once, as the request body.
  Stream<List<int>> watch(Stream<List<int>> source) {
    late final StreamSubscription<List<int>> subscription;
    final controller = StreamController<List<int>>(sync: true);
    controller
      ..onListen = () {
        _lastProgress = _now();
        final interval = idleTimeout ~/ 4;
        _timer = Timer.periodic(
          interval > Duration.zero ? interval : idleTimeout,
          (_) => _check(),
        );
        subscription = source.listen(
          (chunk) {
            _lastProgress = _now();
            controller.add(chunk);
          },
          onError: (Object error, StackTrace stackTrace) {
            _stop();
            controller.addError(error, stackTrace);
          },
          onDone: () {
            // The body is fully handed over; waiting for the response is
            // bounded by the client's receive timeout.
            _stop();
            controller.close();
          },
          cancelOnError: true,
        );
      }
      ..onPause = () {
        subscription.pause();
      }
      ..onResume = () {
        subscription.resume();
      }
      ..onCancel = () {
        _stop();
        return subscription.cancel();
      };
    return controller.stream;
  }

  /// Stops watching; safe to call more than once.
  void dispose() => _stop();

  void _check() {
    final last = _lastProgress;
    if (last == null || _timer == null) return;
    if (_now().difference(last) < idleTimeout) return;
    _timedOut = true;
    _stop();
    cancelToken.cancel('Upload made no progress for $idleTimeout.');
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }
}
