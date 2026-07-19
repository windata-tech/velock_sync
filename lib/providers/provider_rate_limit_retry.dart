import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

/// Retries provider responses that explicitly report HTTP 429, honoring
/// Retry-After when present and otherwise using bounded exponential backoff
/// with full jitter.
class ProviderRateLimitRetry {
  ProviderRateLimitRetry({
    this.maxRetries = 3,
    Future<void> Function(Duration)? sleeper,
    DateTime Function()? clock,
    int Function(int maxExclusive)? nextRandomInt,
  }) : _sleeper = sleeper ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now,
       _nextRandomInt = nextRandomInt ?? Random.secure().nextInt;

  final int maxRetries;
  final Future<void> Function(Duration) _sleeper;
  final DateTime Function() _clock;
  final int Function(int maxExclusive) _nextRandomInt;

  Future<Response<T>> execute<T>(
    Future<Response<T>> Function() request, {
    Future<void>? whenCancelled,
  }) async {
    return _execute(
      request,
      retryServerErrors: false,
      whenCancelled: whenCancelled,
    );
  }

  /// Retries rate limits and transient server failures for operations that are
  /// intrinsically idempotent, such as re-sending one fixed upload chunk.
  Future<Response<T>> executeTransient<T>(
    Future<Response<T>> Function() request, {
    Future<void>? whenCancelled,
  }) =>
      _execute(request, retryServerErrors: true, whenCancelled: whenCancelled);

  Future<Response<T>> _execute<T>(
    Future<Response<T>> Function() request, {
    required bool retryServerErrors,
    Future<void>? whenCancelled,
  }) async {
    for (var retry = 0; ; retry++) {
      if (whenCancelled != null) {
        await Future.any<void>([
          Future<void>.value(),
          whenCancelled.then<void>(
            (_) => throw const RemoteOperationCancelledException(),
          ),
        ]);
      }
      final response = await request();
      final statusCode = response.statusCode;
      final isTransientServerError =
          statusCode != null && statusCode >= 500 && statusCode <= 599;
      if (statusCode != 429 && !(retryServerErrors && isTransientServerError)) {
        return response;
      }
      final delay =
          (statusCode == 429
              ? retryAfter(response.headers.value('retry-after'))
              : null) ??
          _fallbackDelay(retry);
      if (retry >= maxRetries) {
        if (statusCode == 429) throw ProviderRateLimitedException(delay);
        throw ProviderRequestException.fromStatus(
          statusCode!,
          retryAfter: delay,
        );
      }
      if (whenCancelled == null) {
        await _sleeper(delay);
      } else {
        await Future.any<void>([
          _sleeper(delay),
          whenCancelled.then<void>(
            (_) => throw const RemoteOperationCancelledException(),
          ),
        ]);
      }
    }
  }

  Duration _fallbackDelay(int retry) {
    final maximum = Duration(seconds: 1 << retry.clamp(0, 5));
    return Duration(milliseconds: _nextRandomInt(maximum.inMilliseconds + 1));
  }

  Duration? retryAfter(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    try {
      final delta = HttpDate.parse(value).toUtc().difference(_clock().toUtc());
      return delta.isNegative ? Duration.zero : delta;
    } on FormatException {
      return null;
    }
  }
}

class ProviderRateLimitedException extends ProviderRequestException {
  const ProviderRateLimitedException(Duration retryAfter)
    : super(
        statusCode: 429,
        kind: ProviderRequestErrorKind.rateLimited,
        retryable: true,
        retryAfter: retryAfter,
      );

  @override
  String toString() => 'ProviderRateLimitedException: retry after $retryAfter';
}
