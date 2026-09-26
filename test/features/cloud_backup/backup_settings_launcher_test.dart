import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_actions.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_detail.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

void main() {
  const fallback = '请打开格间，解锁后进入设置中的云备份，查看恢复卡与已授权设备';

  test('static contract: settings URI is fixed velock://sync-settings with no '
      'query or requestId; generic pairing URI stays velock://open', () {
    final source = File(
      'lib/features/cloud_backup/ui/backup_actions.dart',
    ).readAsStringSync();
    expect(source, contains("Uri.parse('velock://sync-settings')"));
    expect(source, isNot(contains('velock://sync-settings?')));
    final uri = Uri.parse('velock://sync-settings');
    expect(uri.scheme, 'velock');
    expect(uri.host, 'sync-settings');
    expect(uri.path, isEmpty);
    expect(uri.hasQuery, isFalse);
    expect(uri.queryParameters, isEmpty);
    expect(source, contains("Uri.parse('velock://open')"));
  });

  testWidgets(
    'backup settings launcher is injectable; success shows no fallback',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            velockBackupSettingsLauncherProvider.overrideWithValue(() async {
              calls++;
              return true;
            }),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            supportedLocales: [Locale('zh'), Locale('en')],
            localizationsDelegates: [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: _LauncherProbe(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-launcher')));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text(fallback), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed settings launch shows the manual fallback and it is dismissible',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            velockBackupSettingsLauncherProvider.overrideWithValue(
              () async => false,
            ),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            supportedLocales: [Locale('zh'), Locale('en')],
            localizationsDelegates: [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: _LauncherProbe(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-launcher')));
      await tester.pumpAndSettle();

      expect(find.text(fallback), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text(fallback), findsNothing);
    },
  );

  testWidgets(
    'settings launcher throwing is treated as a failure with the same fallback',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            velockBackupSettingsLauncherProvider.overrideWithValue(
              () async => throw StateError('launcher down'),
            ),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            supportedLocales: [Locale('zh'), Locale('en')],
            localizationsDelegates: [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: _LauncherProbe(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-launcher')));
      await tester.pumpAndSettle();

      expect(find.text(fallback), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail recovery row calls the settings launcher, not the pairing launcher',
    (tester) async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final repository = SyncProfileRepository(database);
      await repository.save(_profile());

      var settingsCalls = 0;
      var pairingCalls = 0;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncStateDatabaseProvider.overrideWithValue(database),
            syncProfileRepositoryProvider.overrideWithValue(repository),
            velockWizardReadinessServiceProvider.overrideWithValue(
              const _Ready(),
            ),
            velockAppLauncherProvider.overrideWithValue(() async {
              pairingCalls++;
              return true;
            }),
            velockBackupSettingsLauncherProvider.overrideWithValue(() async {
              settingsCalls++;
              return true;
            }),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: const SyncProfileDetail(profileId: 'velock'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('恢复卡与已授权设备'), 220);
      await tester.tap(find.text('恢复卡与已授权设备'));
      await tester.pumpAndSettle();

      expect(settingsCalls, 1);
      expect(pairingCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

class _LauncherProbe extends ConsumerWidget {
  const _LauncherProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: GestureDetector(
        key: const Key('settings-launcher'),
        behavior: HitTestBehavior.opaque,
        onTap: () => openVelockBackupSettings(context, ref),
        child: const SizedBox(width: 44, height: 44),
      ),
    );
  }
}

SyncProfileEnvelope _profile() => SyncProfileEnvelope(
  kind: SyncDatasetKind.velockManaged,
  profileId: 'velock',
  datasetId: 'dataset',
  vaultId: 'vault',
  deviceId: 'consumer',
  displayName: '我的格间',
  connectionId: 'cloud',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'schemaVersion': 1,
    'pairedProducerId': 'source',
    'pairedProducerPublicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  },
  createdAt: DateTime.utc(2026, 9, 25),
);

class _Ready implements VelockWizardReadinessService {
  const _Ready();
  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async =>
      const VelockWizardReadiness(VelockWizardAvailability.ready);
}
