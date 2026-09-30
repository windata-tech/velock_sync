import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

/// Works around WebDAV relays that reject valid credentials under concurrency.
///
/// Measured on an FN Connect relay: sequential requests always pass, but two
/// or more requests that arrive within ~50 ms of each other get a spurious
/// `401 Basic realm="Restricted"` (identical to a wrong password). Starts at
/// least 100 ms apart never failed. The relay rejects before forwarding, so
/// the rejected request had no effect on the server.
///
/// Two mitigations, both scoped to one endpoint + account and shared by every
/// client in this process:
///
/// * [paced]: a request does not start within [startGap] of the previous
///   start while that previous request is still waiting for its response.
///   Sequential flows and fast (LAN) servers are not slowed down.
/// * [retryUnauthorized]: a *replayable* request that gets 401 is retried with
///   jitter. Until this account has succeeded once in this process only one
///   retry is allowed, so a genuinely wrong password or a lockout policy is not
///   hammered. Upload bodies from caller streams are never replayed.
class WebDavAuthRaceGuard {
  @visibleForTesting
  WebDavAuthRaceGuard({
    this.startGap = const Duration(milliseconds: 200),
    this.provenRetries = 3,
    this.unprovenRetries = 1,
    Future<void> Function(Duration)? sleeper,
    DateTime Function()? clock,
    int Function(int maxExclusive)? nextRandomInt,
  }) : _sleeper = sleeper ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now,
       _nextRandomInt = nextRandomInt ?? Random().nextInt;

  /// The shared guard for one endpoint origin and account.
  factory WebDavAuthRaceGuard.forEndpoint(
    Uri endpoint, {
    String? username,
    String? password,
  }) {
    final origin = endpoint.hasAuthority
        ? '${endpoint.scheme}://${endpoint.host}:${endpoint.port}'
        : endpoint.toString();
    // Keyed by a digest so the registry never holds the password itself.
    final account = sha256
        .convert(utf8.encode('${username ?? ''}\u0000${password ?? ''}'))
        .toString();
    return _registry.putIfAbsent('$origin|$account', WebDavAuthRaceGuard.new);
  }

  static final Map<String, WebDavAuthRaceGuard> _registry = {};

  @visibleForTesting
  static void resetForTesting() => _registry.clear();

  final Duration startGap;
  final int provenRetries;
  final int unprovenRetries;
  final Future<void> Function(Duration) _sleeper;
  final DateTime Function() _clock;
  final int Function(int maxExclusive) _nextRandomInt;

  bool _proven = false;
  DateTime? _lastStart;
  Completer<void>? _lastPending;
  Future<void> _slots = Future<void>.value();

  /// Whether this account has been accepted at least once in this process.
  bool get proven => _proven;

  /// Starts [request] no sooner than [startGap] after the previous start,
  /// unless that previous request has already been answered.
  Future<T> paced<T>(Future<T> Function() request) async {
    final answered = await _acquireStart();
    try {
      return await request();
    } finally {
      answered.complete();
    }
  }

  Future<Completer<void>> _acquireStart() {
    final slot = _slots.then((_) async {
      final last = _lastStart;
      final pending = _lastPending;
      if (last != null && pending != null && !pending.isCompleted) {
        final remaining = startGap - _clock().difference(last);
        if (remaining > Duration.zero) {
          await Future.any<void>([_sleeper(remaining), pending.future]);
        }
      }
      final answered = Completer<void>();
      _lastStart = _clock();
      _lastPending = answered;
      return answered;
    });
    _slots = slot.then<void>((_) {}, onError: (_) {});
    return slot;
  }

  /// Retries a replayable [request] after a 401 (see class docs).
  ///
  /// [isUnauthorized] recognises the client's 401 error. Any other outcome,
  /// including other HTTP errors, proves the credentials were accepted.
  Future<T> retryUnauthorized<T>(
    Future<T> Function() request, {
    required bool replayable,
    bool Function(Object error)? isUnauthorized,
    Future<void>? whenCancelled,
  }) async {
    final unauthorized = isUnauthorized ?? isUnauthorizedError;
    for (var attempt = 0; ; attempt++) {
      try {
        final result = await request();
        _proven = true;
        return result;
      } catch (error) {
        if (!unauthorized(error)) {
          if (_answeredByServer(error)) _proven = true;
          rethrow;
        }
        final allowed = _proven ? provenRetries : unprovenRetries;
        if (!replayable || attempt >= allowed) rethrow;
        if (kDebugMode) {
          debugPrint('WEBDAV_AUTH_RETRY attempt=${attempt + 1} of $allowed');
        }
        final delay = Duration(
          milliseconds: 250 * (attempt + 1) + _nextRandomInt(251),
        );
        await Future.any<void>([
          _sleeper(delay),
          if (whenCancelled != null)
            whenCancelled.then<void>(
              (_) => throw const RemoteOperationCancelledException(),
            ),
        ]);
      }
    }
  }

  /// 401 as raised by Dio, by [ProviderRequestException], or by any client
  /// exception exposing an HTTP `statusCode` (e.g. webdav_client_plus).
  static bool isUnauthorizedError(Object error) => _statusOf(error) == 401;

  static bool _answeredByServer(Object error) {
    final status = _statusOf(error);
    return status != null && status != 401 && status != 407;
  }

  static int? _statusOf(Object error) {
    if (error is DioException) return error.response?.statusCode;
    if (error is ProviderRequestException) return error.statusCode;
    try {
      final status = (error as dynamic).statusCode;
      return status is int ? status : null;
    } on NoSuchMethodError {
      return null;
    }
  }
}
