import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_profile_finalizer.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

void main() {
  testWidgets(
    'home renders the empty state without exposing profile payloads',
    (tester) async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);

      await tester.pumpWidget(_app(fixture, const SyncProfilesHome()));
      await tester.pumpAndSettle();

      expect(find.text('还没有同步配置。请新建一个配置开始同步。'), findsOneWidget);
      expect(find.byKey(const Key('sync-profile-create')), findsOneWidget);
    },
  );

  testWidgets('home renders dataset kinds and non-runnable lifecycle states', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.addProfile(
      profileId: 'selected',
      displayName: 'Selected profile',
      kind: SyncDatasetKind.selectedFolder,
    );
    await fixture.addProfile(
      profileId: 'needs-access',
      displayName: 'Needs access',
      state: SyncProfileState.accessRequired,
    );
    await fixture.addProfile(
      profileId: 'reauth',
      displayName: 'Needs reauth',
      state: SyncProfileState.reauthorizationRequired,
    );
    await fixture.addProfile(
      profileId: 'blocked',
      displayName: 'Blocked profile',
      state: SyncProfileState.blockedByConfiguration,
    );
    await fixture.addProfile(
      profileId: 'velock',
      displayName: 'Velock profile',
      kind: SyncDatasetKind.velockManaged,
    );

    await tester.pumpWidget(_app(fixture, const SyncProfilesHome()));
    await tester.pumpAndSettle();

    expect(find.text('Selected profile'), findsOneWidget);
    expect(find.text('Velock profile'), findsOneWidget);
    expect(find.textContaining('Selected Folder · 已启用'), findsOneWidget);
    expect(find.textContaining('Velock managed · 已启用'), findsOneWidget);
    expect(find.textContaining('需要授权'), findsOneWidget);
    expect(find.textContaining('需要重新授权'), findsOneWidget);
    expect(find.textContaining('配置不完整'), findsOneWidget);
  });

  testWidgets('home pause and resume persist the lifecycle state', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.addProfile(
      profileId: 'profile-1',
      displayName: 'Mutable profile',
    );

    await tester.pumpWidget(_app(fixture, const SyncProfilesHome()));
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.text('Mutable profile'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: tile, matching: find.byTooltip('同步配置操作')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂停'));
    await tester.pumpAndSettle();

    expect(
      (await fixture.profiles.read('profile-1'))!.state,
      SyncProfileState.paused,
    );

    final pausedTile = find.ancestor(
      of: find.text('Mutable profile'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: pausedTile, matching: find.byTooltip('同步配置操作')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(
      (await fixture.profiles.read('profile-1'))!.state,
      SyncProfileState.active,
    );
  });

  testWidgets('home exposes recovery export for Selected Folder profiles', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.addProfile(
      profileId: 'selected-recovery',
      displayName: 'Recovery profile',
    );

    await tester.pumpWidget(_app(fixture, const SyncProfilesHome()));
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.text('Recovery profile'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: tile, matching: find.byTooltip('同步配置操作')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成恢复包'));
    await tester.pumpAndSettle();

    expect(find.text('恢复包和口令需通过不同的受保护渠道保存。'), findsOneWidget);
    expect(find.widgetWithText(TextField, '恢复口令'), findsOneWidget);
    expect(find.widgetWithText(TextField, '再次输入恢复口令'), findsOneWidget);
  });

  testWidgets('detail sync now uses the unified run service seam', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.addProfile(
      profileId: 'profile-1',
      displayName: 'Profile one',
    );
    final runService = _RecordingRunService();

    await tester.pumpWidget(
      _app(
        fixture,
        SyncProfileDetail(profileId: 'profile-1'),
        runService: runService,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sync-now-button')));
    await tester.pumpAndSettle();

    expect(runService.profileIds, ['profile-1']);
    expect(find.text('同步任务已完成。'), findsOneWidget);
  });

  testWidgets('detail has five safe tabs and filters history to its profile', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.addProfile(
      profileId: 'profile-1',
      displayName: 'Profile one',
    );
    await fixture.addProfile(
      profileId: 'profile-2',
      displayName: 'Profile two',
    );
    await fixture.addRun(
      runId: 'run-1',
      profileId: 'profile-1',
      completed: true,
    );
    await fixture.addRun(
      runId: 'run-2',
      profileId: 'profile-1',
      completed: false,
      errorCode: 'provider.http.429',
    );
    await fixture.addRun(
      runId: 'run-3',
      profileId: 'profile-2',
      completed: false,
      errorCode: 'OTHER-PROFILE-ERROR',
    );

    await tester.pumpWidget(
      _app(fixture, const SyncProfileDetail(profileId: 'profile-1')),
    );
    await tester.pumpAndSettle();

    for (final label in const [
      'Overview',
      'Pending',
      'History',
      'Conflicts',
      'Settings',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    expect(find.text('completed'), findsOneWidget);
    expect(find.text('failed'), findsOneWidget);
    expect(find.textContaining('provider.http.429'), findsOneWidget);
    expect(find.textContaining('OTHER-PROFILE-ERROR'), findsNothing);
  });

  testWidgets('detail does not render raw dataset or protected conflict data', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.addProfile(
      profileId: 'profile-1',
      displayName: 'Profile one',
      rootPath: 'SECRET-PATH-DO-NOT-RENDER',
    );
    await fixture.database.recordFolderConflict(
      conflictId: 'conflict-1',
      profileId: 'profile-1',
      entityId: 'opaque-entity-id',
      sourceDeviceId: 'remote-device-id',
      localRevisionId: 'local-revision',
      incomingRevisionId: 'incoming-revision',
      type: 'modify-modify',
      protectedDetails: '{"secret":"PLAINTEXT-DO-NOT-RENDER"}',
    );

    await tester.pumpWidget(
      _app(fixture, const SyncProfileDetail(profileId: 'profile-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conflicts'));
    await tester.pumpAndSettle();

    expect(find.text('两个设备都修改了内容'), findsOneWidget);
    expect(find.textContaining('opaque-entit'), findsOneWidget);
    expect(find.textContaining('SECRET-PATH-DO-NOT-RENDER'), findsNothing);
    expect(find.textContaining('PLAINTEXT-DO-NOT-RENDER'), findsNothing);
  });

  testWidgets(
    'detail background setting is persisted through the profile repository',
    (tester) async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.addProfile(
        profileId: 'profile-1',
        displayName: 'Profile one',
      );

      await tester.pumpWidget(
        _app(fixture, const SyncProfileDetail(profileId: 'profile-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('后台同步'));
      await tester.pumpAndSettle();

      expect(
        (await fixture.profiles.read('profile-1'))!.backgroundPolicy.enabled,
        isTrue,
      );
    },
  );

  testWidgets(
    'Velock wizard fails closed when pairing control plane is missing',
    (tester) async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        _app(
          fixture,
          const SyncProfileWizard(),
          velockReadiness: const _FixedVelockReadiness(
            VelockWizardAvailability.configurationMissing,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Velock managed data'));
      await tester.pumpAndSettle();

      expect(find.text('配对通道尚未配置'), findsOneWidget);
      expect(find.textContaining('本应用不会猜测身份，也不会创建半成品 Profile'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(find.text('完成'), findsOneWidget);
    },
  );

  testWidgets(
    'Velock wizard renders authorization-required as a retryable state',
    (tester) async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        _app(
          fixture,
          const SyncProfileWizard(),
          velockReadiness: const _FixedVelockReadiness(
            VelockWizardAvailability.authorizationRequired,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('inspect-velock-readiness')));
      await tester.pumpAndSettle();

      expect(find.text('需要在 Velock 中授权'), findsOneWidget);
      expect(find.byKey(const Key('retry-velock-readiness')), findsOneWidget);
    },
  );

  testWidgets(
    'Velock wizard completes steps 4 through 7 and exposes ACK retry',
    (tester) async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final session = _velockSession();
      final approval = _velockApproval(session);
      final pairing = _ApprovedPairingService(
        session: session,
        approval: approval,
      );
      final finalizer = _RecordingVelockFinalizer(
        session: session,
        approval: approval,
        acknowledgeImmediately: false,
      );
      final settings = _RecordingSettingsService();

      await tester.pumpWidget(
        _app(
          fixture,
          const SyncProfileWizard(),
          velockReadiness: _FixedVelockReadiness(
            VelockWizardAvailability.ready,
            descriptor: session.descriptor,
          ),
          pairing: pairing,
          finalizer: finalizer,
          loadConnections: () async => [_activeConnection()],
          resolveAppInstanceId: () async => 'sync-device-1',
          settingsService: settings,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('inspect-velock-readiness')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('begin-velock-pairing')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('check-velock-pairing')));
      await tester.pumpAndSettle();

      expect(find.text('步骤 4 / 7 · 选择远端连接'), findsOneWidget);
      await tester.tap(find.byKey(const Key('velock-connection-connection-1')));
      await tester.pumpAndSettle();
      expect(find.text('步骤 5 / 7 · 确认远端目标'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-velock-target')));
      await tester.pumpAndSettle();
      expect(find.text('步骤 6 / 7 · 后台同步策略'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-velock-background')));
      await tester.pumpAndSettle();
      expect(find.text('步骤 7 / 7 · 最终确认'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('velock-profile-name')),
        'My iOS Vault',
      );
      await tester.tap(find.byKey(const Key('finalize-velock-profile')));
      await tester.pumpAndSettle();

      expect(finalizer.finalizeCalls, 1);
      expect(finalizer.displayName, 'My iOS Vault');
      expect(finalizer.connectionId, 'connection-1');
      expect(finalizer.userConfirmed, isTrue);
      expect(finalizer.backgroundPolicy?.enabled, isTrue);
      expect(
        find.byKey(const Key('velock-finalization-result')),
        findsOneWidget,
      );
      expect(find.text('Profile 已保存；配对清理尚未确认。'), findsOneWidget);

      await tester.tap(find.byKey(const Key('retry-velock-acknowledgement')));
      await tester.pumpAndSettle();

      expect(finalizer.retryCalls, 1);
      expect(find.text('Profile 已保存，配对响应已安全消费。'), findsOneWidget);
    },
  );

  testWidgets(
    'settings persist global policy and expose sanitized diagnostics',
    (tester) async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final settings = _RecordingSettingsService();

      await tester.pumpWidget(
        _app(fixture, const SyncSettings(), settingsService: settings),
      );
      await tester.pumpAndSettle();

      expect(find.text('系统后台状态'), findsOneWidget);
      await tester.tap(find.byKey(const Key('global-background-enabled')));
      await tester.pumpAndSettle();
      expect(settings.saved.single.backgroundEnabled, isFalse);

      await tester.scrollUntilVisible(
        find.byKey(const Key('export-sanitized-diagnostics')),
        300,
      );
      expect(find.text('Velock Sync Protocol V1'), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-sanitized-diagnostics')));
      await tester.pumpAndSettle();
      expect(find.text('脱敏诊断'), findsOneWidget);
      expect(find.textContaining('"containsKeys": false'), findsOneWidget);
      expect(find.textContaining('PLAINTEXT-DO-NOT-RENDER'), findsNothing);
    },
  );
}

Widget _app(
  _Fixture fixture,
  Widget home, {
  SyncProfileRunService? runService,
  SyncSettingsService? settingsService,
  VelockWizardReadinessService? velockReadiness,
  VelockPairingSessionService? pairing,
  VelockProfileFinalizer? finalizer,
  Future<List<ConnectionModel>> Function()? loadConnections,
  Future<String> Function()? resolveAppInstanceId,
}) => ProviderScope(
  overrides: [
    syncStateDatabaseProvider.overrideWithValue(fixture.database),
    syncProfileRepositoryProvider.overrideWithValue(fixture.profiles),
    if (runService != null)
      syncProfileRunServiceProvider.overrideWithValue(runService),
    if (settingsService != null)
      syncSettingsServiceProvider.overrideWithValue(settingsService),
    if (velockReadiness != null)
      velockWizardReadinessServiceProvider.overrideWithValue(velockReadiness),
    if (pairing != null)
      velockPairingSessionServiceProvider.overrideWithValue(pairing),
    if (finalizer != null)
      velockProfileFinalizerProvider.overrideWithValue(finalizer),
    if (loadConnections != null)
      velockWizardConnectionsProvider.overrideWithValue(loadConnections),
    if (resolveAppInstanceId != null)
      velockSyncAppInstanceIdProvider.overrideWithValue(resolveAppInstanceId),
  ],
  child: PlatformApp(home: home),
);

class _Fixture {
  _Fixture._(this.database, this.profiles);

  final SyncStateDatabase database;
  final SyncProfileRepository profiles;

  static Future<_Fixture> create() async {
    final database = await SyncStateDatabase.inMemory();
    return _Fixture._(database, SyncProfileRepository(database));
  }

  Future<void> addProfile({
    required String profileId,
    required String displayName,
    SyncDatasetKind kind = SyncDatasetKind.selectedFolder,
    SyncProfileState state = SyncProfileState.active,
    String rootPath = '/safe/path',
  }) => profiles.save(
    SyncProfileEnvelope(
      kind: kind,
      profileId: profileId,
      datasetId: 'dataset-$profileId',
      vaultId: 'vault-$profileId',
      deviceId: 'device-$profileId',
      displayName: displayName,
      connectionId: 'connection-$profileId',
      state: state,
      backgroundPolicy: const SyncProfileBackgroundPolicy(),
      dataset: switch (kind) {
        SyncDatasetKind.selectedFolder => {
          'rootPath': rootPath,
          'keyId': 'key-$profileId',
          'rootKeyRef': 'secure/root-$profileId',
          'signingKeyRef': 'secure/signing-$profileId',
        },
        SyncDatasetKind.velockManaged => {
          'pairedProducerId': 'producer-$profileId',
          'pairedProducerPublicKeyId': 'key-$profileId',
          'exchangeBindingId': 'exchange-$profileId',
        },
      },
      createdAt: DateTime.utc(2026, 7, 17),
    ),
  );

  Future<void> addRun({
    required String runId,
    required String profileId,
    required bool completed,
    String? errorCode,
  }) async {
    final index = int.parse(runId.split('-').last);
    final startedAt = DateTime.utc(2026, 7, 17, 10, index);
    await database.startSyncRun(
      runId: runId,
      profileId: profileId,
      startedAt: startedAt,
    );
    await database.finishSyncRun(
      runId: runId,
      state: completed ? 'completed' : 'failed',
      completedAt: startedAt.add(const Duration(minutes: 1)),
      errorCode: errorCode,
    );
  }

  Future<void> dispose() => database.close();
}

class _RecordingRunService implements SyncProfileRunService {
  final List<String> profileIds = [];

  @override
  Future<SyncProfileDispatchResult> runNow(String profileId) async {
    profileIds.add(profileId);
    return SyncProfileDispatchResult(
      profileId: profileId,
      status: SyncProfileDispatchStatus.completed,
    );
  }
}

class _RecordingSettingsService implements SyncSettingsService {
  SyncGlobalSettings value = const SyncGlobalSettings();
  final List<SyncGlobalSettings> saved = [];

  @override
  Future<SyncSettingsSnapshot> load() async => SyncSettingsSnapshot(
    settings: value,
    backgroundSupported: true,
    backgroundEligibleProfileCount: 2,
    staging: const StagingSpaceSummary(
      totalBytes: 1024,
      fileCount: 1,
      batchCount: 1,
    ),
  );

  @override
  Future<SyncSettingsSnapshot> save(SyncGlobalSettings settings) async {
    value = settings;
    saved.add(settings);
    return load();
  }

  @override
  Future<SyncSettingsCleanupSummary> cleanupStaging() async =>
      const SyncSettingsCleanupSummary();

  @override
  Future<String> exportSanitizedDiagnostics() async =>
      '{"privacy":{"containsKeys": false}}';
}

class _FixedVelockReadiness implements VelockWizardReadinessService {
  const _FixedVelockReadiness(this.availability, {this.descriptor});

  final VelockWizardAvailability availability;
  final VelockPairingDescriptor? descriptor;

  @override
  Future<VelockWizardReadiness> inspect() async =>
      VelockWizardReadiness(availability, descriptor: descriptor);
}

class _ApprovedPairingService implements VelockPairingSessionService {
  _ApprovedPairingService({required this.session, required this.approval});

  final VelockPairingSession session;
  final VelockPairingControlResponse approval;

  @override
  Future<VelockPairingSession> begin({
    required VelockPairingDescriptor descriptor,
    required String syncAppInstanceId,
  }) async {
    expect(descriptor, same(session.descriptor));
    expect(syncAppInstanceId, session.request.syncAppInstanceId);
    return session;
  }

  @override
  Future<VelockPairingSessionState> inspect(
    VelockPairingSession session,
  ) async => VelockPairingSessionState(
    status: VelockPairingControlStatus.approved,
    response: approval,
  );

  @override
  Future<void> acknowledge(VelockPairingSession session) async {}
}

class _RecordingVelockFinalizer implements VelockProfileFinalizer {
  _RecordingVelockFinalizer({
    required this.session,
    required this.approval,
    required this.acknowledgeImmediately,
  });

  final VelockPairingSession session;
  final VelockPairingControlResponse approval;
  final bool acknowledgeImmediately;
  int finalizeCalls = 0;
  int retryCalls = 0;
  String? displayName;
  String? connectionId;
  bool? userConfirmed;
  SyncProfileBackgroundPolicy? backgroundPolicy;

  @override
  Future<VelockProfileFinalizationResult> finalize({
    required VelockPairingSession session,
    required VelockPairingControlResponse approval,
    required String connectionId,
    required String displayName,
    required SyncProfileBackgroundPolicy backgroundPolicy,
    required bool userConfirmed,
  }) async {
    expect(session, same(this.session));
    expect(approval, same(this.approval));
    finalizeCalls++;
    this.connectionId = connectionId;
    this.displayName = displayName;
    this.backgroundPolicy = backgroundPolicy;
    this.userConfirmed = userConfirmed;
    return VelockProfileFinalizationResult(
      profile: VelockSyncProfile(
        profileId: 'profile-1',
        datasetId: approval.vaultId,
        vaultId: approval.vaultId,
        deviceId: session.request.syncAppInstanceId,
        displayName: displayName,
        connectionId: connectionId,
        pairedProducerId: approval.producerId,
        pairedProducerPublicKeyId: approval.producerPublicKeyId,
        exchangeBindingId: approval.exchangeBindingId,
        backgroundPolicy: backgroundPolicy,
        state: SyncProfileState.active,
        createdAt: DateTime.utc(2026, 7, 18),
      ),
      pairingAcknowledged: acknowledgeImmediately,
    );
  }

  @override
  Future<bool> retryAcknowledgement(VelockPairingSession session) async {
    expect(session, same(this.session));
    retryCalls++;
    return true;
  }
}

VelockPairingSession _velockSession() {
  final now = DateTime.utc(2026, 7, 18, 8);
  final descriptor = VelockPairingDescriptor(
    producerId: 'producer-1',
    producerPublicKeyId: 'key-1',
    producerSigningPublicKey: base64UrlEncode(Uint8List(32)),
    exchangeBindingId: 'binding-1',
    publishedAt: now,
  );
  return VelockPairingSession(
    descriptor: descriptor,
    request: VelockPairingControlRequest(
      requestId: 'request-1',
      challenge: 'challenge-1',
      producerId: descriptor.producerId,
      producerPublicKeyId: descriptor.producerPublicKeyId,
      exchangeBindingId: descriptor.exchangeBindingId,
      syncAppInstanceId: 'sync-device-1',
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
    ),
  );
}

VelockPairingControlResponse _velockApproval(VelockPairingSession session) {
  final approvedAt = session.request.createdAt.add(const Duration(seconds: 5));
  return VelockPairingControlResponse(
    requestId: session.request.requestId,
    challenge: session.request.challenge,
    producerId: session.request.producerId,
    producerPublicKeyId: session.request.producerPublicKeyId,
    producerSigningPublicKey: session.descriptor.producerSigningPublicKey,
    exchangeBindingId: session.request.exchangeBindingId,
    vaultId: 'vault-1',
    vaultDisplayName: 'Personal Vault',
    deviceDisplayName: 'iPhone',
    approvedAt: approvedAt,
    expiresAt: session.request.expiresAt,
    signature: Uint8List(64),
  );
}

ConnectionModel _activeConnection() => ConnectionModel(
  id: 'connection-1',
  name: 'iCloud WebDAV',
  source: 'Velock',
  target: '/Encrypted/Velock',
  protocol: const ProtocolModel.webDav(
    protocolType: WebDavProtocolType.https,
    address: 'https://example.test',
    port: '443',
    path: '/Encrypted/Velock',
  ),
  createdAt: DateTime.utc(2026, 7, 18),
  updatedAt: DateTime.utc(2026, 7, 18),
  status: ConnectionStatus.active,
);
