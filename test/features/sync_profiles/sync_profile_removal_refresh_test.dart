import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

void main() {
  testWidgets('removing a profile from settings refreshes every list', (
    tester,
  ) async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final repository = SyncProfileRepository(database);
    await repository.save(_velockProfile());

    final container = ProviderContainer(
      overrides: [
        syncStateDatabaseProvider.overrideWithValue(database),
        syncProfileRepositoryProvider.overrideWithValue(repository),
        velockWizardReadinessServiceProvider.overrideWithValue(
          const _UnavailableReadinessService(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: '/sync-profiles/velock-profile',
      routes: [
        GoRoute(
          path: '/dashboard',
          builder: (context, state) =>
              const Scaffold(body: Text('dashboard-home')),
        ),
        GoRoute(
          path: '/sync-profiles/:profileId',
          builder: (context, state) => SyncProfileDetail(
            profileId: state.pathParameters['profileId']!,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('移除同步配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除同步配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await tester.pumpAndSettle();

    // The detail page leaves and the shared revision changes, so the sync home
    // and the Velock wizard reload instead of keeping the removed profile.
    expect(find.text('dashboard-home'), findsOneWidget);
    expect(container.read(profilesRevisionProvider), 1);
    expect(
      await repository.listSummaries(kind: SyncDatasetKind.velockManaged),
      isEmpty,
    );
  });
}

SyncProfileEnvelope _velockProfile() => SyncProfileEnvelope(
  kind: SyncDatasetKind.velockManaged,
  profileId: 'velock-profile',
  datasetId: 'velock-dataset',
  vaultId: 'velock-vault',
  deviceId: 'consumer-device',
  displayName: 'Velock E2E Replica 的 Velock',
  connectionId: 'connection-1',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'schemaVersion': 1,
    'pairedProducerId': 'producer-device',
    'pairedProducerPublicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  },
  createdAt: DateTime.utc(2026, 9, 12),
);

class _UnavailableReadinessService implements VelockWizardReadinessService {
  const _UnavailableReadinessService();

  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async =>
      const VelockWizardReadiness(
        VelockWizardAvailability.temporarilyUnavailable,
      );
}
