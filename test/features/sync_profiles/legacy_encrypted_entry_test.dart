/// The encrypted folder-sync protocol is retired: it is not offered anywhere,
/// and it must not keep running invisibly either.
///
/// These tests pin both halves of that decision. Settings renders no
/// 「旧版…」 section even when such a task exists in the database (the user's
/// 2026-09-27 instruction: 「旧版就是淘汰的版本功能，不需要保留」), and
/// `SyncProfileSummary.isBackgroundEligible` excludes
/// `SyncDatasetKind.selectedFolder`, so the retired task cannot be picked up by
/// the background scheduler while no page offers a way to see, pause or delete
/// it. The stored rows and the remote encrypted data are deliberately left
/// untouched by this retirement.
///
/// Harness notes: an in-memory [SyncStateDatabase] replaces the on-disk app
/// database (so the page really reads profile rows), and
/// [syncSettingsServiceProvider] is stubbed so the page never reaches
/// `getApplicationSupportDirectory`.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_settings.dart';

const _legacyHeader = '旧版加密文件夹同步';
const _manageTileKey = Key('legacy-encrypted-manage');
const _manageTileTitle = '管理旧版加密同步';

void main() {
  late SyncStateDatabase database;
  late SyncProfileRepository profiles;

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    profiles = SyncProfileRepository(database);
  });

  tearDown(() => database.close());

  testWidgets('a fresh install shows no retired encrypted section', (
    tester,
  ) async {
    await _mountSettings(tester, database: database);

    expect(find.text(_legacyHeader), findsNothing);
    expect(find.byKey(_manageTileKey), findsNothing);
    expect(find.textContaining(_manageTileTitle), findsNothing);
    expect(find.textContaining('旧版'), findsNothing);

    // The ordinary settings rows the user came for still render.
    expect(find.text('云端账号与保存位置'), findsOneWidget);
    expect(find.text('所有传输记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an existing retired task is not advertised anywhere', (
    tester,
  ) async {
    await _seedLegacyEncryptedProfile(profiles);
    await _seedPlainProfile(database);

    // The row really is in the database, so the absence below is a product
    // decision and not an empty table.
    expect((await profiles.listSummaries()).length, 2);

    await _mountSettings(tester, database: database);

    expect(find.text(_legacyHeader), findsNothing);
    expect(find.byKey(_manageTileKey), findsNothing);
    expect(find.textContaining(_manageTileTitle), findsNothing);
    expect(find.textContaining('旧版'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('a retired encrypted task never runs in the background', () async {
    await _seedLegacyEncryptedProfile(profiles);
    await _seedPlainProfile(database);

    // Both tasks are active with background enabled, but only the plain mirror
    // location is schedulable: the retired kind has no UI left to pause it.
    final eligible = await profiles.listBackgroundEligible();
    expect(eligible.map((summary) => summary.profileId), ['plain-1']);

    final legacy = (await profiles.listSummaries()).firstWhere(
      (summary) => summary.profileId == 'legacy-folder',
    );
    expect(legacy.isRunnable, isTrue, reason: 'the row itself is untouched');
    expect(legacy.isBackgroundEligible, isFalse);
    expect(legacy.kind, SyncDatasetKind.selectedFolder);
  });
}

/// Mounts `SyncSettings` the way `sync_settings_deletion_protection_test.dart`
/// does: zh locale plus localization delegates, the settings service stubbed so
/// no platform channel is touched, and the profile table overridden with the
/// in-memory database so `legacyEncryptedProfilesProvider` reads real rows.
Future<ProviderContainer> _mountSettings(
  WidgetTester tester, {
  required SyncStateDatabase database,
}) async {
  _usePhoneSurface(tester);
  final container = ProviderContainer(
    overrides: [
      syncStateDatabaseProvider.overrideWithValue(database),
      syncSettingsServiceProvider.overrideWithValue(_StubSyncSettingsService()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const SyncSettings(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void _usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A pre-plain-sync encrypted folder task, saved exactly like production does
/// (`plain_sync_home_test.dart`).
Future<void> _seedLegacyEncryptedProfile(SyncProfileRepository profiles) =>
    profiles.save(
      SyncProfileEnvelope(
        kind: SyncDatasetKind.selectedFolder,
        profileId: 'legacy-folder',
        datasetId: 'legacy-dataset',
        vaultId: 'legacy-vault',
        deviceId: 'this-device',
        displayName: '旧工作文件夹',
        connectionId: 'cloud',
        state: SyncProfileState.active,
        backgroundPolicy: const SyncProfileBackgroundPolicy(),
        dataset: const {
          'schemaVersion': 1,
          'pairedProducerId': 'source',
          'pairedProducerPublicKey':
              'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        },
        createdAt: DateTime.utc(2026, 9, 20),
      ),
    );

/// A current plain (unencrypted) mirror location in the same profile table.
Future<void> _seedPlainProfile(SyncStateDatabase database) =>
    PlainFolderSyncProfileRepository(database).save(
      PlainFolderSyncProfile(
        profileId: 'plain-1',
        datasetId: 'plain-dataset',
        deviceId: 'this-device',
        displayName: '照片同步',
        localRootReference: '/tmp/legacy-entry-test/照片',
        localDisplayName: '照片',
        connectionId: 'cloud',
        remoteRootSegments: const ['photos'],
        // Both tasks ask for background work; only the live kind gets it.
        backgroundEnabled: true,
        createdAt: DateTime.utc(2026, 9, 27),
      ),
    );

class _StubSyncSettingsService implements SyncSettingsService {
  @override
  Future<SyncSettingsSnapshot> load() async => _snapshot;

  @override
  Future<SyncSettingsSnapshot> save(SyncGlobalSettings settings) async =>
      _snapshot;

  @override
  Future<SyncSettingsCleanupSummary> cleanupStaging() async =>
      const SyncSettingsCleanupSummary();

  @override
  Future<String> exportSanitizedDiagnostics() async => '{}';

  static const _snapshot = SyncSettingsSnapshot(
    settings: SyncGlobalSettings(),
    backgroundSupported: false,
    backgroundEligibleProfileCount: 0,
    staging: StagingSpaceSummary(),
    garbageCollection: null,
  );
}
