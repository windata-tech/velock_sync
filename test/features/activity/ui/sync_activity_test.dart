import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/activity/ui/sync_activity.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_service.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_strategy.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  testWidgets(
    'Selected Folder conflict keeps protected details private and offers only folder strategies',
    (tester) async {
      final fixture = await _Fixture.create(SyncDatasetKind.selectedFolder);
      addTearDown(fixture.dispose);
      final service = _RecordingConflictResolutionService();

      await tester.pumpWidget(_app(fixture, service));
      await tester.pumpAndSettle();

      expect(find.textContaining('PLAINTEXT-DO-NOT-RENDER'), findsNothing);
      expect(find.text('两个设备都修改了内容'), findsOneWidget);
      expect(find.byTooltip('解决冲突'), findsOneWidget);

      await tester.tap(find.byTooltip('解决冲突'));
      await tester.pumpAndSettle();

      expect(find.text('保留本地版本'), findsOneWidget);
      expect(find.text('保留远端版本'), findsOneWidget);
      expect(find.text('保留两个版本'), findsOneWidget);
      expect(find.text('在 Velock 中处理'), findsNothing);

      await tester.tap(find.text('保留本地版本'));
      await tester.pumpAndSettle();

      expect(service.calls, [
        const _ResolutionCall(
          conflictId: 'conflict-1',
          strategy: ConflictResolutionStrategy.keepLocal,
        ),
      ]);
    },
  );

  testWidgets('Velock conflict offers only open in Velock', (tester) async {
    final fixture = await _Fixture.create(SyncDatasetKind.velockManaged);
    addTearDown(fixture.dispose);
    final service = _RecordingConflictResolutionService(
      result: const ConflictResolutionResult.failed(
        'velock-resolution-pending',
      ),
    );

    await tester.pumpWidget(_app(fixture, service));
    await tester.pumpAndSettle();

    expect(find.textContaining('PLAINTEXT-DO-NOT-RENDER'), findsNothing);
    await tester.tap(find.byTooltip('解决冲突'));
    await tester.pumpAndSettle();

    expect(find.text('在 Velock 中处理'), findsOneWidget);
    expect(find.text('保留本地版本'), findsNothing);
    expect(find.text('保留远端版本'), findsNothing);
    expect(find.text('保留两个版本'), findsNothing);

    await tester.tap(find.text('在 Velock 中处理'));
    await tester.pumpAndSettle();
    expect(
      find.text('已打开 Velock；处理完成后回到这里再次选择“在 Velock 中处理”。'),
      findsOneWidget,
    );
  });
}

Widget _app(_Fixture fixture, ConflictResolutionService service) =>
    ProviderScope(
      overrides: [
        syncStateDatabaseProvider.overrideWithValue(fixture.database),
        syncProfileRepositoryProvider.overrideWithValue(fixture.profiles),
        conflictResolutionServiceProvider.overrideWithValue(service),
      ],
      child: const PlatformApp(home: SyncActivity()),
    );

class _Fixture {
  _Fixture._(this.database, this.profiles);

  final SyncStateDatabase database;
  final SyncProfileRepository profiles;

  static Future<_Fixture> create(SyncDatasetKind kind) async {
    final database = await SyncStateDatabase.inMemory();
    final profiles = SyncProfileRepository(database);
    await profiles.save(
      SyncProfileEnvelope(
        kind: kind,
        profileId: 'profile-1',
        datasetId: 'dataset-1',
        vaultId: 'vault-1',
        deviceId: 'device-1',
        displayName: 'Privacy-safe test profile',
        connectionId: 'connection-1',
        state: SyncProfileState.active,
        backgroundPolicy: const SyncProfileBackgroundPolicy(),
        dataset: switch (kind) {
          SyncDatasetKind.selectedFolder => const {
            'rootPath': '/safe/path',
            'rootKeyRef': 'secure/root',
            'signingKeyRef': 'secure/signing',
          },
          SyncDatasetKind.velockManaged => const {
            'pairedProducerId': 'producer-1',
            'pairedProducerPublicKeyId': 'key-1',
            'exchangeBindingId': 'exchange-1',
          },
        },
        createdAt: DateTime.utc(2026, 7, 17),
      ),
    );
    await database.recordFolderConflict(
      conflictId: 'conflict-1',
      profileId: 'profile-1',
      entityId: 'opaque-entity-id',
      sourceDeviceId: 'remote-device-id',
      localRevisionId: 'local-revision',
      incomingRevisionId: 'incoming-revision',
      type: 'modify-modify',
      protectedDetails: '{"secret":"PLAINTEXT-DO-NOT-RENDER"}',
    );
    return _Fixture._(database, profiles);
  }

  Future<void> dispose() => database.close();
}

class _RecordingConflictResolutionService implements ConflictResolutionService {
  _RecordingConflictResolutionService({
    this.result = const ConflictResolutionResult.completed(),
  });

  final List<_ResolutionCall> calls = [];
  final ConflictResolutionResult result;

  @override
  Future<ConflictResolutionResult> resolve({
    required String conflictId,
    required ConflictResolutionStrategy strategy,
  }) async {
    calls.add(_ResolutionCall(conflictId: conflictId, strategy: strategy));
    return result;
  }
}

class _ResolutionCall {
  const _ResolutionCall({required this.conflictId, required this.strategy});

  final String conflictId;
  final ConflictResolutionStrategy strategy;

  @override
  bool operator ==(Object other) =>
      other is _ResolutionCall &&
      other.conflictId == conflictId &&
      other.strategy == strategy;

  @override
  int get hashCode => Object.hash(conflictId, strategy);
}
