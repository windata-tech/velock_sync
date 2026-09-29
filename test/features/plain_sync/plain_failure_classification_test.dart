/// The plain domain can only say "没有网络连接" if the engine actually classifies
/// a transport failure as one.
///
/// The folder service persists `SyncFailureClassifier.classify(error).errorCode`
/// for every failed run, and the location card renders that stored code. These
/// tests pin the classification of the failures that used to collapse into
/// `sync.unexpected` — a wrong password, an offline device and a full disk all
/// reached the user as the same sentence.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/plain_sync/model/plain_location_presentation.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

DioException _dio(DioExceptionType type, {int? statusCode, Object? error}) =>
    DioException(
      requestOptions: RequestOptions(path: '/dav/photo.jpg'),
      type: type,
      error: error,
      response: statusCode == null
          ? null
          : Response<void>(
              requestOptions: RequestOptions(path: '/dav'),
              statusCode: statusCode,
            ),
    );

Future<BuildContext> _mount(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  group('SyncFailureClassifier', () {
    test(
      'a refused connection is unreachable, not "offline" or "unexpected"',
      () {
        final failure = SyncFailureClassifier.classify(
          _dio(
            DioExceptionType.connectionError,
            error: const SocketException('offline'),
          ),
        );

        expect(failure.errorCode, SyncFailureCodes.networkUnreachable);
        expect(failure.category, SyncErrorCategory.transientNetwork);
        expect(failure.retryable, isTrue);
      },
    );

    test('a bare socket error is unreachable as well', () {
      expect(
        SyncFailureClassifier.classify(
          const SocketException('no route to host'),
        ).errorCode,
        SyncFailureCodes.networkUnreachable,
      );
    });

    test('every timeout flavour is a timeout', () {
      for (final type in const [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.transformTimeout,
      ]) {
        expect(
          SyncFailureClassifier.classify(_dio(type)).errorCode,
          SyncFailureCodes.networkTimeout,
          reason: '$type',
        );
      }
      expect(
        SyncFailureClassifier.classify(
          TimeoutException('probe timed out'),
        ).errorCode,
        SyncFailureCodes.networkTimeout,
      );
    });

    test('a status that arrived without a provider wrapper keeps its code', () {
      expect(
        SyncFailureClassifier.classify(
          _dio(DioExceptionType.badResponse, statusCode: 507),
        ).errorCode,
        'provider.http.507',
      );
      expect(
        SyncFailureClassifier.classify(
          _dio(DioExceptionType.badResponse, statusCode: 401),
        ).category,
        SyncErrorCategory.authenticationRequired,
      );
      expect(
        SyncFailureClassifier.classify(
          _dio(DioExceptionType.badResponse, statusCode: 503),
        ).errorCode,
        'provider.http.503',
      );
    });

    test('a cancelled request is a cancellation, not a failure to explain', () {
      expect(
        SyncFailureClassifier.classify(_dio(DioExceptionType.cancel)).errorCode,
        'remote.operation_cancelled',
      );
    });

    test('a genuinely unknown error stays unexpected', () {
      expect(
        SyncFailureClassifier.classify(StateError('boom')).errorCode,
        SyncFailureCodes.unexpected,
      );
      expect(
        SyncFailureClassifier.classify(
          _dio(DioExceptionType.unknown, error: StateError('boom')),
        ).errorCode,
        SyncFailureCodes.unexpected,
      );
    });

    test('a provider failure keeps its own classification', () {
      final failure = SyncFailureClassifier.classify(
        ProviderRequestException.fromStatus(507),
      );
      expect(failure.errorCode, 'provider.http.507');
      expect(failure.category, SyncErrorCategory.insufficientSpace);
      expect(failure.suggestedAction, contains('空间'));
    });
  });

  testWidgets('the classified transport codes render as plain sentences', (
    tester,
  ) async {
    final context = await _mount(tester);

    final offline = SyncFailureClassifier.classify(
      _dio(DioExceptionType.connectionError, error: const SocketException('x')),
    );
    expect(
      plainFailureMessage(context, offline.errorCode),
      '连不上远端服务器，本次同步没有完成。请检查网络、服务器地址和端口，并确认服务器正在运行。',
    );

    final timeout = SyncFailureClassifier.classify(
      _dio(DioExceptionType.receiveTimeout),
    );
    expect(
      plainFailureMessage(context, timeout.errorCode),
      '连接远端超时，本次同步没有完成。请检查网络和远端服务后重试。',
    );

    final fullDisk = SyncFailureClassifier.classify(
      ProviderRequestException.fromStatus(507),
    );
    expect(
      plainFailureMessage(context, fullDisk.errorCode),
      '云端空间不足，本次同步没有完成。请先清理远端文件或扩容，再重新同步。',
    );
  });
}
