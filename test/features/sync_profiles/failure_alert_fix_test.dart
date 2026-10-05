/// A failed backup always offers the step that fixes it.
///
/// 2026-10-04: "history missing" was shown with only "OK", so the user was
/// told about the problem but given no way to solve it, run after run.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_remote_history_guard.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace_shared.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

class _Failure implements SyncFailureException {
  const _Failure(this.code);
  final String code;
  @override
  SyncFailure get syncFailure => SyncFailure(
    errorCode: code,
    category: SyncErrorCategory.transientNetwork,
    retryable: true,
    suggestedAction: '',
  );
}

Future<List<BackupAction>> _show(
  WidgetTester tester,
  Object error, {
  String? tap,
}) async {
  final picked = <BackupAction>[];
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [...GlobalMaterialLocalizations.delegates],
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => presentSyncFailureAlert(
              context: context,
              error: error,
              onFix: (action) async => picked.add(action),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  // Never a dead-end acknowledgement.
  expect(find.text('知道了'), findsNothing);
  expect(find.text('稍后'), findsOneWidget);
  if (tap != null) {
    await tester.tap(find.text(tap));
    await tester.pumpAndSettle();
  }
  return picked;
}

void main() {
  testWidgets('missing history offers a new full backup or the old folder', (
    tester,
  ) async {
    final picked = await _show(
      tester,
      const VelockRemoteHistoryIncomplete(),
      tap: '完整备份到新文件夹',
    );
    expect(find.text('这个文件夹里没有完整的备份'), findsNothing);
    expect(picked, [BackupAction.rebuildBackup]);
  });

  testWidgets('missing history can also go back to the original folder', (
    tester,
  ) async {
    final picked = await _show(
      tester,
      const VelockRemoteHistoryIncomplete(),
      tap: '改回原来的文件夹',
    );
    expect(picked, [BackupAction.reviewHistory]);
  });

  final cases = {
    'provider.webdav.collection_not_writable': (
      '更换保存位置',
      BackupAction.checkStorage,
    ),
    'provider.http.401': ('修改连接', BackupAction.fixConnection),
    'local.velock_recovery_required': ('打开格间', BackupAction.openVelock),
    'network.timeout': ('重试', BackupAction.transfer),
  };
  for (final MapEntry(key: code, value: (label, action)) in cases.entries) {
    testWidgets('$code offers "$label"', (tester) async {
      final picked = await _show(tester, _Failure(code), tap: label);
      expect(picked, [action]);
    });
  }

  testWidgets('"Later" closes without acting', (tester) async {
    final picked = await _show(tester, _Failure('network.timeout'), tap: '稍后');
    expect(picked, isEmpty);
  });
}
