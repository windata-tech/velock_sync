import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace_shared.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';

/// Fake exceptions carry a stable [SyncFailure] without any network or
/// database access, so the presentation layer can be exercised offline.
class _FakeSyncFailure implements SyncFailureException {
  const _FakeSyncFailure(this.syncFailure);

  @override
  final SyncFailure syncFailure;
}

const _authFailure = SyncFailure(
  errorCode: 'provider.http.401',
  category: SyncErrorCategory.authenticationRequired,
  retryable: false,
  suggestedAction: '',
  providerStatusCode: 401,
);

const _noChangeResult = SyncProfileDispatchResult(
  profileId: 'profile-1',
  status: SyncProfileDispatchStatus.completed,
  run: SyncProfileRunResult(
    runId: 'run-1',
    upload: UploadRunResult.idle(),
    download: DownloadRunResult(0),
  ),
);

SyncProfileDispatchResult failedResult(Object? error) =>
    SyncProfileDispatchResult(
      profileId: 'profile-1',
      status: SyncProfileDispatchStatus.failed,
      error: error,
    );

/// Minimal host: a Scaffold (so [showMessage] can use its SnackBar messenger)
/// and one trigger button that invokes the presenter under test.
Widget host(
  TargetPlatform platform,
  Locale locale,
  Future<void> Function(BuildContext) presenter,
) => MaterialApp(
  locale: locale,
  supportedLocales: const [Locale('zh'), Locale('en')],
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: ThemeData(platform: platform),
  home: Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => TextButton(
          key: const Key('trigger'),
          onPressed: () => presenter(context),
          child: const Text('Trigger'),
        ),
      ),
    ),
  ),
);

Finder alertFor(TargetPlatform platform) => platform == TargetPlatform.iOS
    ? find.byType(CupertinoAlertDialog)
    : find.byType(AlertDialog);

/// Asserts the full persistent-failure contract:
/// the adaptive alert appears with the localized title, readable failure
/// text and an explicit OK action; it has no timer (still visible after 6s,
/// far beyond any toast display duration); barrier taps do not dismiss it;
/// only the acknowledgement closes it; and no transient toast is involved.
Future<void> expectPersistentFailurePresentation(
  WidgetTester tester, {
  required TargetPlatform platform,
  required Locale locale,
  required Future<void> Function(BuildContext) presenter,
  required String title,
  required String message,
  required String okLabel,
}) async {
  final alert = alertFor(platform);

  await tester.pumpWidget(host(platform, locale, presenter));
  await tester.tap(find.byKey(const Key('trigger')));
  await tester.pumpAndSettle();

  expect(alert, findsOneWidget);
  expect(find.text(title), findsOneWidget);
  expect(find.text(message), findsOneWidget);
  expect(find.text(okLabel), findsOneWidget);
  expect(
    find.byType(SnackBar),
    findsNothing,
    reason: 'a failed sync must not fall back to the transient toast',
  );

  // No timer: the alert stays readable well past a toast's display time.
  await tester.pump(const Duration(seconds: 6));
  expect(alert, findsOneWidget);

  // Dismissed only by acknowledgement: tapping the barrier keeps it open.
  await tester.tapAt(const Offset(4, 4));
  await tester.pumpAndSettle();
  expect(alert, findsOneWidget);

  // The explicit OK action acknowledges and dismisses it.
  await tester.tap(find.text(okLabel));
  await tester.pumpAndSettle();
  expect(alert, findsNothing);
}

void main() {
  for (final platform in const [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      'presentSyncResult shows a persistent acknowledged failure alert '
      'on ${platform.name}',
      (tester) async {
        await expectPersistentFailurePresentation(
          tester,
          platform: platform,
          locale: const Locale('zh'),
          presenter: (context) => presentSyncResult(
            context,
            failedResult(const _FakeSyncFailure(_authFailure)),
          ),
          title: '同步失败',
          message: '远端拒绝了访问，请重新授权后再试。',
          okLabel: '知道了',
        );
      },
    );

    testWidgets(
      'presentFirstSyncResult shows the same persistent failure alert '
      'on ${platform.name}',
      (tester) async {
        await expectPersistentFailurePresentation(
          tester,
          platform: platform,
          locale: const Locale('zh'),
          presenter: (context) => presentFirstSyncResult(
            context,
            // Plain thrown exception: classified as the stable unknown
            // failure without leaking diagnostic text.
            failedResult(Exception('boom')),
          ),
          title: '同步失败',
          message: '同步未完成，请检查同步配置后重试。',
          okLabel: '知道了',
        );
      },
    );

    testWidgets('presentSyncFailureAlert persists a thrown-exception failure '
        'on ${platform.name}', (tester) async {
      await expectPersistentFailurePresentation(
        tester,
        platform: platform,
        locale: const Locale('zh'),
        presenter: (context) => presentSyncFailureAlert(
          context: context,
          error: StateError('fake thrown exception'),
        ),
        title: '同步失败',
        message: '同步未完成，请检查同步配置后重试。',
        okLabel: '知道了',
      );
    });

    testWidgets('presentSyncResult localizes the persistent failure alert '
        'in English on ${platform.name}', (tester) async {
      await expectPersistentFailurePresentation(
        tester,
        platform: platform,
        locale: const Locale('en'),
        presenter: (context) => presentSyncResult(
          context,
          failedResult(const _FakeSyncFailure(_authFailure)),
        ),
        title: 'Sync failed',
        message: 'Remote access was denied. Authorize access again and retry.',
        okLabel: 'OK',
      );
    });

    testWidgets('busy is informational on ${platform.name}', (tester) async {
      const result = SyncProfileDispatchResult(
        profileId: 'profile-1',
        status: SyncProfileDispatchStatus.skippedNotRunnable,
        error: SyncRunBusyException('profile-1'),
      );
      for (final first in [false, true]) {
        await tester.pumpWidget(
          host(
            platform,
            const Locale('zh'),
            (context) => first
                ? presentFirstSyncResult(context, result)
                : presentSyncResult(context, result),
          ),
        );
        await tester.tap(find.byKey(const Key('trigger')));
        await tester.pumpAndSettle();
        expect(find.text('同步已在进行中，无需重复启动。'), findsOneWidget);
        expect(alertFor(platform), findsNothing);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('successful and no-change results keep the transient toast '
        'on ${platform.name}', (tester) async {
      final alert = alertFor(platform);

      // A completed run with nothing to transfer stays a toast that
      // dismisses on its own.
      await tester.pumpWidget(
        host(
          platform,
          const Locale('zh'),
          (context) => presentSyncResult(context, _noChangeResult),
        ),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();
      expect(alert, findsNothing);
      expect(find.text('本次检查没有发现需要传输的新内容。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);

      // A first sync that never started is informational, so it stays a
      // toast as well.
      await tester.pumpWidget(
        host(
          platform,
          const Locale('zh'),
          (context) => presentFirstSyncResult(context, null),
        ),
      );
      await tester.tap(find.byKey(const Key('trigger')));
      await tester.pumpAndSettle();
      expect(alert, findsNothing);
      expect(find.text('本次传输尚未开始，请重试。'), findsOneWidget);
    });
  }
}
