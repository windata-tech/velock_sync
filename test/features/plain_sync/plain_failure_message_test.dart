/// One shared sentence per failure for the plain (unencrypted) folder domain.
///
/// The location card, the detail page and the run dialog all read
/// [plainFailureMessage], so a code can never mean one thing in the list and
/// another in the dialog. The exact wording lives in [plainFailureCases] and is
/// asserted here; the locale sweep is in
/// `test/l10n/plain_failure_locale_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/plain_sync/model/plain_location_presentation.dart';

import 'plain_failure_cases.dart';
import 'plain_sync_test_support.dart';

/// `sync.some_future_code`-shaped tokens must never reach the primary copy.
final _codeLike = RegExp(r'[a-z][a-z_]*\.[a-z_]+');
final _han = RegExp(r'[\u4e00-\u9fff]');
final _digits = RegExp(r'\d');

/// Every probe the table describes: the code plus the name the card knows.
List<FailureProbe> get _probes => [
  for (final failure in plainFailureCases)
    (code: failure.code, connectionName: failure.connectionName),
];

void main() {
  testWidgets('every known failure reads as its exact Chinese sentence', (
    tester,
  ) async {
    final rendered = await renderPlainFailures(
      tester,
      const Locale('zh'),
      _probes,
    );

    for (var index = 0; index < plainFailureCases.length; index++) {
      final failure = plainFailureCases[index];
      expect(rendered[index], failure.zh, reason: failure.code);
    }
  });

  testWidgets('every known failure has its own exact English sentence', (
    tester,
  ) async {
    final rendered = await renderPlainFailures(
      tester,
      const Locale('en'),
      _probes,
    );

    for (var index = 0; index < plainFailureCases.length; index++) {
      final failure = plainFailureCases[index];
      expect(rendered[index], failure.en, reason: failure.code);
    }
  });

  testWidgets(
    'no raw code, protocol token or number reaches the primary sentence',
    (tester) async {
      for (final locale in const [Locale('zh'), Locale('en')]) {
        final rendered = await renderPlainFailures(tester, locale, _probes);

        for (var index = 0; index < plainFailureCases.length; index++) {
          final failure = plainFailureCases[index];
          for (final sentence in [failure.zh, failure.en, rendered[index]]) {
            expect(
              sentence,
              isNot(contains(failure.code)),
              reason: failure.code,
            );
            expect(sentence, isNot(matches(_codeLike)), reason: failure.code);
            expect(sentence, isNot(matches(_digits)), reason: failure.code);
          }
        }
      }
    },
  );

  testWidgets('English sentences carry no Chinese characters', (tester) async {
    final rendered = await renderPlainFailures(
      tester,
      const Locale('en'),
      _probes,
    );

    for (var index = 0; index < plainFailureCases.length; index++) {
      expect(
        rendered[index],
        isNot(matches(_han)),
        reason: plainFailureCases[index].code,
      );
    }
  });

  testWidgets('the local-access sentence explains an iOS reinstall', (
    tester,
  ) async {
    expect(
      await renderPlainFailure(
        tester,
        const Locale('zh'),
        'plain_folder.local_access_lost',
        platform: TargetPlatform.iOS,
      ),
      '本机文件夹的访问权限已失效，在 iPhone 或 iPad 上重装 App 后就是这样。请打开“详情”，重新选择本机文件夹。',
    );

    // The same code on a platform without that failure mode stays short.
    final android = await renderPlainFailure(
      tester,
      const Locale('zh'),
      'plain_folder.local_access_lost',
    );
    expect(android, '本机文件夹的访问权限已失效。请打开“详情”，重新选择本机文件夹。');
    expect(android, isNot(contains('重装')));
  });

  testWidgets('the sign-in sentence names the connection when it is known', (
    tester,
  ) async {
    expect(
      await renderPlainFailure(tester, const Locale('zh'), 'provider.http.401'),
      '远端连接没有通过认证，用户名或密码不对。请打开这个连接，重新填写用户名和密码后重试。',
    );
    expect(
      await renderPlainFailure(
        tester,
        const Locale('zh'),
        'provider.http.401',
        connectionName: '我的 NAS',
      ),
      contains('“我的 NAS”'),
    );
    // A blank name must not turn into an empty pair of quotes.
    expect(
      await renderPlainFailure(
        tester,
        const Locale('zh'),
        'provider.http.401',
        connectionName: '  ',
      ),
      isNot(contains('“')),
    );
  });

  testWidgets('a missing or unknown code is never echoed back', (tester) async {
    expect(
      await renderPlainFailure(tester, const Locale('zh'), null),
      '同步没有完成。请重试一次；一直失败就打开“详情”检查本机文件夹和远端文件夹。',
    );
    expect(
      await renderPlainFailure(tester, const Locale('zh'), '   '),
      '同步没有完成。请重试一次；一直失败就打开“详情”检查本机文件夹和远端文件夹。',
    );

    for (final code in const [
      'sync.some_future_code',
      'plain_folder.not_invented_yet',
      'future.provider.failure',
      'HTTP 500 from the server',
    ]) {
      final message = await renderPlainFailure(
        tester,
        const Locale('zh'),
        code,
      );
      expect(message, unknownPlainFailureZh, reason: code);
      expect(message, isNot(contains(code)), reason: code);
      expect(message, isNot(matches(_codeLike)), reason: code);
    }

    expect(
      await renderPlainFailure(
        tester,
        const Locale('en'),
        'sync.some_future_code',
      ),
      unknownPlainFailureEn,
    );
  });

  testWidgets('the unknown sentence still tells the user what to do next', (
    tester,
  ) async {
    final message = await renderPlainFailure(
      tester,
      const Locale('zh'),
      'sync.something-new',
    );
    expect(message, contains('重试'));
    expect(message, contains('详情'));
    // It must not blame the network for a cause it cannot see.
    expect(message, isNot(contains('网络')));
  });

  testWidgets(
    'the location card shows the plain sentence, never the stored code',
    (tester) async {
      final world = await pumpPlainSyncApp(
        tester,
        connections: [webDavConnection()],
      );
      await world.seedPlainProfile();
      await world.database.startSyncRun(
        runId: 'run-plain-1',
        profileId: 'plain-1',
        startedAt: DateTime.utc(2026, 9, 27, 8),
      );
      await world.database.finishSyncRun(
        runId: 'run-plain-1',
        state: 'failed',
        completedAt: DateTime.utc(2026, 9, 27, 8, 1),
        errorCode: 'plain_folder.remote_folder_unwritable',
      );
      await world.refreshListView();

      expect(find.text('上次同步失败'), findsOneWidget);
      expect(
        find.text('远端文件夹不存在，或这个账号不能写入。请打开“详情”，重新选择一个真实存在、可写入的远端文件夹。'),
        findsOneWidget,
      );

      // The code the card used to print in the paragraph is gone from the page.
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(
          text.data ?? '',
          isNot(contains('plain_folder.remote_folder_unwritable')),
        );
        expect(text.data ?? '', isNot(matches(_codeLike)));
      }
    },
  );

  testWidgets('the card names the connection whose password is wrong', (
    tester,
  ) async {
    final world = await pumpPlainSyncApp(
      tester,
      connections: [webDavConnection(name: '我的 NAS')],
    );
    await world.seedPlainProfile();
    await world.database.startSyncRun(
      runId: 'run-plain-1',
      profileId: 'plain-1',
      startedAt: DateTime.utc(2026, 9, 27, 8),
    );
    await world.database.finishSyncRun(
      runId: 'run-plain-1',
      state: 'failed',
      completedAt: DateTime.utc(2026, 9, 27, 8, 1),
      errorCode: 'provider.http.401',
    );
    await world.refreshListView();

    expect(
      find.text('远端连接“我的 NAS”没有通过认证，用户名或密码不对。请打开这个连接，重新填写用户名和密码后重试。'),
      findsOneWidget,
    );
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data ?? '', isNot(contains('provider.http.401')));
    }
  });
}
