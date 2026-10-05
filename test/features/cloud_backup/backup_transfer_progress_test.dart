/// Live progress on the first-backup card.
///
/// Uploaded bytes come from the engine's transfer records for this run; the
/// total adds what Velock still has queued in the outbox. The bar never
/// moves backwards, never claims 100 % before the run returns, and shows no
/// percentage where the outbox cannot be read.
library;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_queue_probe.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_transfer_progress.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';

class _Probe extends VelockExchangeQueueProbe {
  _Probe(this.pending);
  int? pending;
  @override
  Future<int?> pendingUploadBytes() async => pending;
}

Future<void> _upload(
  SyncStateDatabase database,
  String key,
  int bytes, {
  bool complete = true,
  String profileId = 'p1',
}) async {
  await database.beginTransferJob(
    transferId: '$profileId-$key',
    profileId: profileId,
    direction: TransferJobDirection.upload,
    logicalKey: key,
    expectedSize: bytes,
  );
  if (complete) {
    await database.completeTransferJob(
      transferId: '$profileId-$key',
      completedBytes: bytes,
    );
  } else {
    await database.updateTransferProgress(
      transferId: '$profileId-$key',
      completedBytes: bytes,
    );
  }
}

Widget _host(SyncStateDatabase database, _Probe probe, DateTime since) =>
    ProviderScope(
      overrides: [
        syncStateDatabaseProvider.overrideWithValue(database),
        velockExchangeQueueProbeProvider.overrideWithValue(probe),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: BackupTransferProgress(
              profileId: 'p1',
              since: since,
              pollInterval: const Duration(milliseconds: 100),
            ),
          ),
        ),
      ),
    );

double? _value(WidgetTester tester) => tester
    .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
    .value;

void main() {
  test('uploaded bytes count this run only, partial and complete', () async {
    final database = await SyncStateDatabase.inMemory();
    await _upload(database, 'old', 999);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final since = DateTime.now().toUtc();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await _upload(database, 'a', 100);
    await _upload(database, 'b', 40, complete: false);
    await _upload(database, 'c', 7, profileId: 'other');

    expect(
      await database.transferredBytesSince(
        profileId: 'p1',
        since: since,
        direction: TransferJobDirection.upload,
      ),
      140,
    );
  });

  testWidgets('shows a determinate bar from uploaded and queued bytes', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    final since = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
    final probe = _Probe(300);
    await tester.runAsync(() => _upload(database, 'a', 100));

    await tester.pumpWidget(_host(database, probe, since));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(_value(tester), closeTo(0.25, 0.001));
    expect(find.textContaining('25%'), findsOneWidget);

    // A new package arriving must not pull the bar back.
    probe.pending = 900;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(_value(tester), closeTo(0.25, 0.001));

    // Outbox drained: still not "done" until the run itself returns.
    probe.pending = 0;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(_value(tester), 0.99);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without a readable outbox the bar moves without a percent', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    final since = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
    await tester.runAsync(() => _upload(database, 'a', 2048));

    await tester.pumpWidget(_host(database, _Probe(null), since));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(_value(tester), isNull);
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('before anything uploads it says it is preparing', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    await tester.pumpWidget(
      _host(database, _Probe(500), DateTime.now().toUtc()),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.text('Preparing…'), findsOneWidget);
    expect(find.byType(CupertinoButton), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a restore shows what it downloaded, without a percent', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    final since = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await database.beginTransferJob(
        transferId: 'd1',
        profileId: 'p1',
        direction: TransferJobDirection.download,
        logicalKey: 'k',
        expectedSize: 3 * 1024 * 1024,
      );
      await database.completeTransferJob(
        transferId: 'd1',
        completedBytes: 3 * 1024 * 1024,
      );
    });

    await tester.pumpWidget(_host(database, _Probe(0), since));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(_value(tester), isNull);
    expect(find.textContaining('downloaded'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the status card shows progress only while transferring', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    Widget card(BackupStage stage) => ProviderScope(
      overrides: [
        syncStateDatabaseProvider.overrideWithValue(database),
        velockExchangeQueueProbeProvider.overrideWithValue(_Probe(null)),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: ListView(
            children: [
              BackupStatusCard(
                name: 'Velock',
                presentation: BackupPresentation(stage, BackupAction.transfer),
                onAction: () {},
                progress: BackupTransferProgress.forRun('p1', null),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpWidget(card(BackupStage.transferring));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pumpWidget(card(BackupStage.lastTransferCompleted));
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
