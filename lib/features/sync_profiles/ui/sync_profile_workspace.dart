import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_service.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_pairing_control_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/device_signing_key_store.dart';
import 'package:velock_sync/infrastructure/secure_storage/vault_key_store.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher_factory.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/sync_core/crypto/vault_recovery_package.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_profile_finalizer.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';

/// UI-level seam so widget tests can verify the unified action without
/// executing platform IPC, providers, or a remote transfer.
abstract interface class SyncProfileRunService {
  Future<SyncProfileDispatchResult> runNow(String profileId);
}

final syncProfileRunServiceProvider = Provider<SyncProfileRunService>(
  (ref) => _ForegroundSyncProfileRunService(
    database: ref.watch(syncStateDatabaseProvider),
    profiles: ref.watch(syncProfileRepositoryProvider),
    selectedFolderProfiles: ref.watch(selectedFolderProfilesProvider),
    connections: ref.watch(connectionRepositoryProvider),
    vaultKeys: ref.watch(vaultKeyStoreProvider),
    signingKeys: ref.watch(deviceSigningKeyStoreProvider),
  ),
);

final syncSettingsServiceProvider = Provider<SyncSettingsService>(
  (ref) => DurableSyncSettingsService(
    settings: LocalSyncGlobalSettingsStore(ref.watch(localDataManagerProvider)),
    profiles: ref.watch(syncProfileRepositoryProvider),
    database: ref.watch(syncStateDatabaseProvider),
    supportDirectory: getApplicationSupportDirectory,
  ),
);

final velockWizardReadinessServiceProvider =
    Provider<VelockWizardReadinessService>(
      (ref) => PlatformVelockWizardReadinessService(),
    );

final velockPairingSessionServiceProvider =
    Provider<VelockPairingSessionService>(
      (ref) => PlatformVelockPairingSessionService(
        control: Platform.isIOS || Platform.isMacOS
            ? ApplePairingControlChannel()
            : MethodChannelAndroidExchangeChannel(),
      ),
    );

final velockSyncAppInstanceIdProvider = Provider<Future<String> Function()>((
  ref,
) {
  final localData = ref.watch(localDataManagerProvider);
  return () async {
    var appInstanceId = await localData.getStringAsync(AppKeys.deviceId);
    if (appInstanceId == null || appInstanceId.trim().isEmpty) {
      appInstanceId = const Uuid().v4();
      await localData.setStringAsync(AppKeys.deviceId, appInstanceId);
    }
    return appInstanceId;
  };
});

final velockWizardConnectionsProvider =
    Provider<Future<List<ConnectionModel>> Function()>(
      (ref) => ref.watch(connectionRepositoryProvider).loadConnections,
    );

final velockProfileFinalizerProvider = Provider<VelockProfileFinalizer>((ref) {
  final profiles = ref.watch(syncProfileRepositoryProvider);
  final connections = ref.watch(connectionRepositoryProvider);
  final database = ref.watch(syncStateDatabaseProvider);
  return VelockProfileFinalizationService(
    saveProfile: profiles.save,
    retainProducerTrust:
        ({required vaultId, required producerId, required signingPublicKey}) =>
            database.trustDevice(
              vaultId: vaultId,
              deviceId: producerId,
              signingPublicKey: signingPublicKey,
            ),
    readProfiles: () =>
        profiles.listSummaries(kind: SyncDatasetKind.velockManaged),
    readConnection: connections.getConnectionById,
    pairing: ref.watch(velockPairingSessionServiceProvider),
  );
});

class _ForegroundSyncProfileRunService implements SyncProfileRunService {
  _ForegroundSyncProfileRunService({
    required SyncStateDatabase database,
    required SyncProfileRepository profiles,
    required this.selectedFolderProfiles,
    required this.connections,
    required this.vaultKeys,
    required this.signingKeys,
  }) : _database = database,
       _profiles = profiles;

  final SyncStateDatabase _database;
  final SyncProfileRepository _profiles;
  final SelectedFolderSyncProfileRepository selectedFolderProfiles;
  final ConnectionRepository connections;
  final VaultKeyStore vaultKeys;
  final DeviceSigningKeyStore signingKeys;
  Future<SyncProfileDispatcher>? _dispatcher;

  @override
  Future<SyncProfileDispatchResult> runNow(String profileId) async =>
      (await (_dispatcher ??= _buildDispatcher())).dispatch(profileId);

  Future<SyncProfileDispatcher> _buildDispatcher() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final stagingRoot = Directory('${supportDirectory.path}/staging');
    final selectedFolderService = SelectedFolderSyncService(
      database: _database,
      profiles: selectedFolderProfiles,
      connections: connections,
      vaultKeys: vaultKeys,
      signingKeys: signingKeys,
      stagingRoot: stagingRoot,
    );
    final velockService = VelockSyncService(
      database: _database,
      profiles: _profiles,
      connections: connections,
      adapterFactory: PlatformVelockDatasetAdapterFactory(
        androidExchange: MethodChannelAndroidExchangeChannel(),
        appleRootLocator: AppleExchangeRootLocator(),
      ),
      stagingRoot: stagingRoot,
    );
    return SyncProfileDispatcherFactory.create(
      profiles: _profiles,
      selectedFolderService: selectedFolderService,
      velockService: velockService,
    );
  }
}

class SyncProfilesHome extends ConsumerStatefulWidget {
  const SyncProfilesHome({super.key});

  @override
  ConsumerState<SyncProfilesHome> createState() => _SyncProfilesHomeState();
}

class _SyncProfilesHomeState extends ConsumerState<SyncProfilesHome> {
  late Future<List<SyncProfileSummary>> _profiles;

  @override
  void initState() {
    super.initState();
    _profiles = _load();
  }

  Future<List<SyncProfileSummary>> _load() =>
      ref.read(syncProfileRepositoryProvider).listSummaries();

  void _refresh() => setState(() {
    _profiles = _load();
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sync')),
    floatingActionButton: FloatingActionButton.extended(
      key: const Key('sync-profile-create'),
      tooltip: '新建同步配置',
      onPressed: () => context.push('/sync-profiles/new'),
      icon: const Icon(Icons.add),
      label: const Text('新建'),
    ),
    body: FutureBuilder<List<SyncProfileSummary>>(
      future: _profiles,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: Semantics(
              label: '正在加载同步配置',
              child: const CircularProgressIndicator(),
            ),
          );
        }
        if (snapshot.hasError) {
          return _RetryState(onRetry: _refresh, message: '无法读取同步配置。');
        }
        final profiles = snapshot.requireData;
        if (profiles.isEmpty) {
          return Center(
            child: Semantics(
              label: '没有同步配置',
              child: const Text('还没有同步配置。请新建一个配置开始同步。'),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: profiles.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) =>
                _ProfileTile(summary: profiles[index], onChanged: _refresh),
          ),
        );
      },
    ),
  );
}

class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({required this.summary, required this.onChanged});

  final SyncProfileSummary summary;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = summary.displayName ?? '不可用的同步配置';
    final subtitle =
        '${_kindLabel(summary.kind)} · ${_stateLabel(summary.state)}${_activityText(summary.activity)}';
    return Semantics(
      label: '$title，$subtitle',
      child: ListTile(
        leading: Icon(_kindIcon(summary.kind)),
        title: Text(title),
        subtitle: Text(summary.isIsolated ? '此配置无法安全读取。' : subtitle),
        enabled: !summary.isIsolated,
        onTap: () => context.push('/sync-profiles/${summary.profileId}'),
        trailing: PopupMenuButton<_ProfileAction>(
          tooltip: '同步配置操作',
          onSelected: (action) => _runAction(context, ref, action),
          itemBuilder: (context) => [
            if (summary.kind == SyncDatasetKind.selectedFolder)
              const PopupMenuItem(
                value: _ProfileAction.exportRecovery,
                child: Text('生成恢复包'),
              ),
            if (summary.isRunnable)
              const PopupMenuItem(
                value: _ProfileAction.syncNow,
                child: Text('立即同步'),
              ),
            if (summary.state == SyncProfileState.active)
              const PopupMenuItem(
                value: _ProfileAction.pause,
                child: Text('暂停'),
              ),
            if (summary.state == SyncProfileState.paused)
              const PopupMenuItem(
                value: _ProfileAction.resume,
                child: Text('恢复'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _runAction(
    BuildContext context,
    WidgetRef ref,
    _ProfileAction action,
  ) async {
    try {
      switch (action) {
        case _ProfileAction.exportRecovery:
          final profile = await ref
              .read(selectedFolderProfilesProvider)
              .read(summary.profileId);
          if (profile == null || !context.mounted) {
            throw StateError('Selected Folder profile is unavailable.');
          }
          final passphrase = await _requestProfileRecoveryPassphrase(context);
          if (passphrase == null || !context.mounted) return;
          final recoveryPackage = await GenericVaultRecoveryService(
            ref.read(vaultKeyStoreProvider),
          ).export(rootKeyRef: profile.rootKeyRef, passphrase: passphrase);
          if (context.mounted) {
            await _showProfileRecoveryPackage(context, recoveryPackage);
          }
        case _ProfileAction.syncNow:
          final result = await ref
              .read(syncProfileRunServiceProvider)
              .runNow(summary.profileId);
          if (!context.mounted) {
            return;
          }
          _showMessage(
            context,
            result.didRun
                ? '同步任务已完成。'
                : '同步未启动：${_dispatchLabel(result.status)}',
          );
        case _ProfileAction.pause:
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(summary.profileId, SyncProfileState.paused);
        case _ProfileAction.resume:
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(summary.profileId, SyncProfileState.active);
      }
      onChanged();
    } on Object {
      if (context.mounted) {
        _showMessage(context, '操作未完成，请稍后重试。');
      }
    }
  }
}

enum _ProfileAction { exportRecovery, syncNow, pause, resume }

Future<String?> _requestProfileRecoveryPassphrase(BuildContext context) async {
  final first = TextEditingController();
  final second = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('生成恢复包'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('恢复包和口令需通过不同的受保护渠道保存。'),
            TextField(
              controller: first,
              decoration: const InputDecoration(labelText: '恢复口令'),
              obscureText: true,
              autocorrect: false,
            ),
            TextField(
              controller: second,
              decoration: const InputDecoration(labelText: '再次输入恢复口令'),
              obscureText: true,
              autocorrect: false,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (first.text.isEmpty || first.text != second.text) return;
              Navigator.of(dialogContext).pop(first.text);
            },
            child: const Text('生成'),
          ),
        ],
      ),
    );
  } finally {
    first.dispose();
    second.dispose();
  }
}

Future<void> _showProfileRecoveryPackage(
  BuildContext context,
  String recoveryPackage,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: const Text('一次性恢复包'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('请安全保存。此窗口关闭后应用不会保留或自动复制该恢复包。'),
          const SizedBox(height: 12),
          SelectableText(recoveryPackage),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('我已安全保存'),
      ),
    ],
  ),
);

class SyncProfileWizard extends ConsumerStatefulWidget {
  const SyncProfileWizard({super.key});

  @override
  ConsumerState<SyncProfileWizard> createState() => _SyncProfileWizardState();
}

class _SyncProfileWizardState extends ConsumerState<SyncProfileWizard> {
  bool _checkingVelock = false;
  VelockPairingSession? _velockPairingSession;
  VelockPairingControlResponse? _velockPairingApproval;
  VelockProfileFinalizationResult? _velockFinalization;

  Future<void> _inspectVelock() async {
    setState(() => _checkingVelock = true);
    final readiness = await ref
        .read(velockWizardReadinessServiceProvider)
        .inspect();
    if (!mounted) return;
    setState(() => _checkingVelock = false);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_velockReadinessTitle(readiness.availability)),
        content: Text(_velockReadinessMessage(readiness.availability)),
        actions: [
          if (readiness.canRetry)
            TextButton(
              key: const Key('retry-velock-readiness'),
              onPressed: () {
                Navigator.pop(dialogContext);
                _inspectVelock();
              },
              child: const Text('重试'),
            ),
          if (readiness.canCreate)
            FilledButton(
              key: const Key('begin-velock-pairing'),
              onPressed: () {
                Navigator.pop(dialogContext);
                _beginVelockPairing(readiness.descriptor!);
              },
              child: const Text('开始配对'),
            )
          else
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('完成'),
            ),
        ],
      ),
    );
  }

  Future<void> _beginVelockPairing(VelockPairingDescriptor descriptor) async {
    setState(() => _checkingVelock = true);
    try {
      final appInstanceId = await ref.read(velockSyncAppInstanceIdProvider)();
      final session = await ref
          .read(velockPairingSessionServiceProvider)
          .begin(descriptor: descriptor, syncAppInstanceId: appInstanceId);
      if (!mounted) return;
      setState(() {
        _checkingVelock = false;
        _velockPairingSession = session;
      });
      await _showPairingApprovalDialog(session);
    } on Object {
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      _showMessage(context, '无法发起安全配对；未创建任何 Profile。');
    }
  }

  Future<void> _showPairingApprovalDialog(VelockPairingSession session) async {
    var checking = false;
    var statusMessage = 'Velock 已打开。请解锁并明确批准本次配对，然后返回这里检查结果。';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('步骤 3 / 7 · 在 Velock 中批准'),
          content: Text(statusMessage),
          actions: [
            TextButton(
              onPressed: checking ? null : () => Navigator.pop(dialogContext),
              child: const Text('稍后继续'),
            ),
            FilledButton(
              key: const Key('check-velock-pairing'),
              onPressed: checking
                  ? null
                  : () async {
                      setDialogState(() => checking = true);
                      try {
                        final state = await ref
                            .read(velockPairingSessionServiceProvider)
                            .inspect(session);
                        if (!mounted || !dialogContext.mounted) return;
                        if (state.isApproved) {
                          final approval = state.response!;
                          setState(() => _velockPairingApproval = approval);
                          Navigator.pop(dialogContext);
                          await Future<void>.delayed(Duration.zero);
                          if (mounted) {
                            await _continueVelockProfile(session, approval);
                          }
                          return;
                        }
                        setDialogState(() {
                          checking = false;
                          statusMessage = switch (state.status) {
                            VelockPairingControlStatus.pending =>
                              'Velock 尚未批准。请在 Velock 中确认后再次检查。',
                            VelockPairingControlStatus.denied =>
                              '你已在 Velock 中拒绝本次配对；未创建任何 Profile。',
                            VelockPairingControlStatus.expired =>
                              '本次配对已过期；请关闭后重新发起。',
                            VelockPairingControlStatus.revoked =>
                              'Velock 已撤销本次授权；未创建任何 Profile。',
                            VelockPairingControlStatus.approved =>
                              '配对响应无效；为保护身份，本应用不会继续。',
                          };
                        });
                      } on Object {
                        if (!dialogContext.mounted) return;
                        setDialogState(() {
                          checking = false;
                          statusMessage = '配对响应未通过验证；未创建任何 Profile。';
                        });
                      }
                    },
              child: checking
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('检查批准结果'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _continueVelockProfile(
    VelockPairingSession session,
    VelockPairingControlResponse approval,
  ) async {
    try {
      final connections = (await ref.read(velockWizardConnectionsProvider)())
          .where((connection) => connection.status == ConnectionStatus.active)
          .toList(growable: false);
      if (!mounted) return;
      if (connections.isEmpty) {
        _showMessage(context, '没有可用的远端连接。请先创建并验证连接，再回来继续。');
        return;
      }

      final connection = await _chooseVelockConnection(connections);
      if (connection == null || !mounted) return;
      if (!await _confirmVelockTarget(connection) || !mounted) return;

      final defaults =
          (await ref.read(syncSettingsServiceProvider).load()).settings;
      if (!mounted) return;
      final backgroundPolicy = await _chooseVelockBackgroundPolicy(defaults);
      if (backgroundPolicy == null || !mounted) return;

      final review = await _reviewVelockProfile(
        approval: approval,
        connection: connection,
        backgroundPolicy: backgroundPolicy,
      );
      if (review == null || !mounted) return;

      setState(() => _checkingVelock = true);
      final result = await ref
          .read(velockProfileFinalizerProvider)
          .finalize(
            session: session,
            approval: approval,
            connectionId: connection.id,
            displayName: review.displayName,
            backgroundPolicy: backgroundPolicy,
            userConfirmed: true,
          );
      if (!mounted) return;
      setState(() {
        _checkingVelock = false;
        _velockFinalization = result;
        if (result.pairingAcknowledged) {
          _velockPairingSession = null;
          _velockPairingApproval = null;
        }
      });
      _showMessage(
        context,
        result.pairingAcknowledged
            ? '已创建“${result.profile.displayName}”。'
            : 'Profile 已安全保存，但配对清理尚未确认；可在本页重试。',
      );
    } on Object {
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      _showMessage(context, '未能完成 Velock Profile；配对响应未被提前消费。');
    }
  }

  Future<ConnectionModel?> _chooseVelockConnection(
    List<ConnectionModel> connections,
  ) => showDialog<ConnectionModel>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('步骤 4 / 7 · 选择远端连接'),
      children: [
        for (final connection in connections)
          SimpleDialogOption(
            key: Key('velock-connection-${connection.id}'),
            onPressed: () => Navigator.pop(dialogContext, connection),
            child: ListTile(
              leading: const Icon(Icons.cloud_done_outlined),
              title: Text(connection.name),
              subtitle: Text(connection.protocol.targetLabel),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
      ],
    ),
  );

  Future<bool> _confirmVelockTarget(ConnectionModel connection) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('步骤 5 / 7 · 确认远端目标'),
          content: Text(
            '${connection.name}\n${connection.target}\n\n'
            'Velock 数据会以加密同步对象写入此目标；不会把 Velock 数据库或密钥交给 Sync。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('返回'),
            ),
            FilledButton(
              key: const Key('confirm-velock-target'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认目标'),
            ),
          ],
        ),
      ) ??
      false;

  Future<SyncProfileBackgroundPolicy?> _chooseVelockBackgroundPolicy(
    SyncGlobalSettings defaults,
  ) {
    var enabled = defaults.backgroundEnabled;
    var allowCellular = defaults.defaultAllowCellular;
    var requiresCharging = defaults.defaultRequiresCharging;
    var maximumBytes = defaults.defaultCellularMaxTransferBytes;
    const choices = <int>[10, 50, 100];
    if (!choices.map((value) => value * 1024 * 1024).contains(maximumBytes)) {
      maximumBytes = 50 * 1024 * 1024;
    }
    return showDialog<SyncProfileBackgroundPolicy>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('步骤 6 / 7 · 后台同步策略'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  key: const Key('velock-background-enabled'),
                  title: const Text('允许后台同步'),
                  value: enabled,
                  onChanged: (value) => setDialogState(() => enabled = value),
                ),
                SwitchListTile(
                  title: const Text('允许使用蜂窝网络'),
                  value: allowCellular,
                  onChanged: enabled
                      ? (value) => setDialogState(() => allowCellular = value)
                      : null,
                ),
                SwitchListTile(
                  title: const Text('仅充电时运行'),
                  value: requiresCharging,
                  onChanged: enabled
                      ? (value) =>
                            setDialogState(() => requiresCharging = value)
                      : null,
                ),
                DropdownButtonFormField<int>(
                  initialValue: maximumBytes,
                  decoration: const InputDecoration(labelText: '蜂窝网络单次上限'),
                  items: [
                    for (final value in choices)
                      DropdownMenuItem(
                        value: value * 1024 * 1024,
                        child: Text('$value MiB'),
                      ),
                  ],
                  onChanged: enabled && allowCellular
                      ? (value) {
                          if (value != null) {
                            setDialogState(() => maximumBytes = value);
                          }
                        }
                      : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('返回'),
            ),
            FilledButton(
              key: const Key('confirm-velock-background'),
              onPressed: () => Navigator.pop(
                dialogContext,
                SyncProfileBackgroundPolicy(
                  enabled: enabled,
                  allowCellular: enabled && allowCellular,
                  requiresCharging: enabled && requiresCharging,
                  cellularMaxTransferBytes: maximumBytes,
                ),
              ),
              child: const Text('继续'),
            ),
          ],
        ),
      ),
    );
  }

  Future<_VelockProfileReview?> _reviewVelockProfile({
    required VelockPairingControlResponse approval,
    required ConnectionModel connection,
    required SyncProfileBackgroundPolicy backgroundPolicy,
  }) {
    var displayName = approval.vaultDisplayName;
    return showDialog<_VelockProfileReview>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('步骤 7 / 7 · 最终确认'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  key: const Key('velock-profile-name'),
                  initialValue: displayName,
                  onChanged: (value) =>
                      setDialogState(() => displayName = value),
                  maxLength: 128,
                  decoration: const InputDecoration(labelText: 'Profile 名称'),
                ),
                Text('Vault：${approval.vaultDisplayName}'),
                Text('设备：${approval.deviceDisplayName}'),
                Text('远端：${connection.name} · ${connection.target}'),
                Text(
                  '后台：${backgroundPolicy.enabled ? '开启' : '关闭'}'
                  '${backgroundPolicy.allowCellular ? '，允许蜂窝网络' : ''}',
                ),
                const SizedBox(height: 12),
                const Text('确认后先原子保存 Profile，成功后才消费本次一次性配对响应。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('返回'),
            ),
            FilledButton(
              key: const Key('finalize-velock-profile'),
              onPressed: displayName.trim().isEmpty
                  ? null
                  : () => Navigator.pop(
                      dialogContext,
                      _VelockProfileReview(displayName: displayName.trim()),
                    ),
              child: const Text('确认并创建'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _retryVelockAcknowledgement() async {
    final session = _velockPairingSession;
    if (session == null) return;
    setState(() => _checkingVelock = true);
    final acknowledged = await ref
        .read(velockProfileFinalizerProvider)
        .retryAcknowledgement(session);
    if (!mounted) return;
    setState(() {
      _checkingVelock = false;
      if (acknowledged) {
        _velockPairingSession = null;
        _velockPairingApproval = null;
        final result = _velockFinalization;
        if (result != null) {
          _velockFinalization = VelockProfileFinalizationResult(
            profile: result.profile,
            pairingAcknowledged: true,
          );
        }
      }
    });
    _showMessage(context, acknowledged ? '配对清理已确认。' : '仍无法确认配对清理，请稍后重试。');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('新建同步配置')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('步骤 1 / 7 · 选择数据集'),
        const SizedBox(height: 8),
        const Text('配置过程中只保存安全存储引用，不保存密钥或登录凭据。失败或取消不会创建半成品 Profile。'),
        const SizedBox(height: 16),
        if (_velockPairingSession != null && _velockPairingApproval == null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.pending_actions_outlined),
              title: const Text('Velock 配对等待批准'),
              subtitle: const Text('请求仍在有效期内；可返回 Velock 批准后继续。'),
              onTap: () => _showPairingApprovalDialog(_velockPairingSession!),
            ),
          ),
        if (_velockPairingApproval != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(_velockPairingApproval!.vaultDisplayName),
              subtitle: Text(
                '已验证 ${_velockPairingApproval!.deviceDisplayName}；尚未创建 Profile。',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _checkingVelock
                  ? null
                  : () => _continueVelockProfile(
                      _velockPairingSession!,
                      _velockPairingApproval!,
                    ),
            ),
          ),
        if (_velockFinalization case final result?)
          Card(
            child: ListTile(
              key: const Key('velock-finalization-result'),
              leading: Icon(
                result.pairingAcknowledged
                    ? Icons.check_circle_outline
                    : Icons.sync_problem_outlined,
              ),
              title: Text(result.profile.displayName),
              subtitle: Text(
                result.pairingAcknowledged
                    ? 'Profile 已保存，配对响应已安全消费。'
                    : 'Profile 已保存；配对清理尚未确认。',
              ),
              trailing: result.pairingAcknowledged
                  ? null
                  : TextButton(
                      key: const Key('retry-velock-acknowledgement'),
                      onPressed: _checkingVelock
                          ? null
                          : _retryVelockAcknowledgement,
                      child: const Text('重试清理'),
                    ),
            ),
          ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Selected Folder'),
            subtitle: const Text('选择目录、连接和远端目标，并在原子创建前完成访问预检。'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/selected-folder-profiles'),
          ),
        ),
        Card(
          child: ListTile(
            key: const Key('inspect-velock-readiness'),
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Velock managed data'),
            subtitle: const Text('检查独立 Velock App、签名保护的 Exchange、授权与配对能力。'),
            trailing: _checkingVelock
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            enabled: !_checkingVelock,
            onTap: _checkingVelock ? null : _inspectVelock,
          ),
        ),
      ],
    ),
  );
}

class _VelockProfileReview {
  const _VelockProfileReview({required this.displayName});

  final String displayName;
}

class SyncProfileDetail extends ConsumerStatefulWidget {
  const SyncProfileDetail({super.key, required this.profileId});

  final String profileId;

  @override
  ConsumerState<SyncProfileDetail> createState() => _SyncProfileDetailState();
}

class _SyncProfileDetailState extends ConsumerState<SyncProfileDetail> {
  late Future<_DetailData> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_DetailData> _load() async {
    final database = ref.read(syncStateDatabaseProvider);
    final profile = await ref
        .read(syncProfileRepositoryProvider)
        .read(widget.profileId);
    final values = await Future.wait<Object?>([
      database.latestSyncRun(widget.profileId),
      database.listRecentSyncRuns(profileId: widget.profileId),
      database.listTransferJobs(profileId: widget.profileId),
      database.listUnresolvedConflicts(profileId: widget.profileId),
    ]);
    return _DetailData(
      profile: profile,
      latestRun: values[0] as SyncRunRecord?,
      runs: values[1] as List<SyncRunRecord>,
      transfers: values[2] as List<TransferJobRecord>,
      conflicts: values[3] as List<SyncConflictRecord>,
    );
  }

  void _refresh() => setState(() {
    _data = _load();
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<_DetailData>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasError) {
        return Scaffold(
          appBar: AppBar(),
          body: _RetryState(onRetry: _refresh, message: '无法读取同步配置详情。'),
        );
      }
      final data = snapshot.requireData;
      final profile = data.profile;
      if (profile == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('找不到该同步配置。')),
        );
      }
      return DefaultTabController(
        length: 5,
        child: Scaffold(
          appBar: AppBar(
            title: Text(profile.displayName),
            bottom: const TabBar(
              isScrollable: true,
              tabs: [
                Tab(text: 'Overview'),
                Tab(text: 'Pending'),
                Tab(text: 'History'),
                Tab(text: 'Conflicts'),
                Tab(text: 'Settings'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              _OverviewTab(
                profile: profile,
                latestRun: data.latestRun,
                onChanged: _refresh,
              ),
              _PendingTab(transfers: data.transfers),
              _HistoryTab(runs: data.runs),
              _ConflictsTab(conflicts: data.conflicts),
              _ProfileSettingsTab(profile: profile, onChanged: _refresh),
            ],
          ),
        ),
      );
    },
  );
}

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab({
    required this.profile,
    required this.latestRun,
    required this.onChanged,
  });
  final SyncProfileEnvelope profile;
  final SyncRunRecord? latestRun;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      ListTile(
        title: const Text('数据集'),
        subtitle: Text(_kindLabel(profile.kind)),
      ),
      ListTile(
        title: const Text('状态'),
        subtitle: Text(_stateLabel(profile.state)),
      ),
      ListTile(
        title: const Text('最近同步'),
        subtitle: Text(latestRun == null ? '尚未运行' : _latestRunLabel(latestRun)),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const Key('sync-now-button'),
        onPressed: profile.state == SyncProfileState.active
            ? () async {
                final result = await ref
                    .read(syncProfileRunServiceProvider)
                    .runNow(profile.profileId);
                if (context.mounted) {
                  _showMessage(
                    context,
                    result.didRun
                        ? '同步任务已完成。'
                        : '同步未启动：${_dispatchLabel(result.status)}',
                  );
                }
                onChanged();
              }
            : null,
        icon: const Icon(Icons.sync),
        label: const Text('立即同步'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: () async {
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(
                profile.profileId,
                profile.state == SyncProfileState.paused
                    ? SyncProfileState.active
                    : SyncProfileState.paused,
              );
          onChanged();
        },
        child: Text(profile.state == SyncProfileState.paused ? '恢复同步' : '暂停同步'),
      ),
    ],
  );
}

class _PendingTab extends StatelessWidget {
  const _PendingTab({required this.transfers});
  final List<TransferJobRecord> transfers;

  @override
  Widget build(BuildContext context) => transfers.isEmpty
      ? const Center(child: Text('没有待处理传输。'))
      : ListView.builder(
          itemCount: transfers.length,
          itemBuilder: (context, index) {
            final transfer = transfers[index];
            return ListTile(
              leading: Icon(
                transfer.direction == TransferJobDirection.upload
                    ? Icons.upload
                    : Icons.download,
              ),
              title: Text(
                '${transfer.direction.name} · ${transfer.state.name}',
              ),
              subtitle: Text(
                '${transfer.completedBytes}${transfer.expectedSize == null ? '' : ' / ${transfer.expectedSize}'} B',
              ),
            );
          },
        );
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.runs});
  final List<SyncRunRecord> runs;

  @override
  Widget build(BuildContext context) => runs.isEmpty
      ? const Center(child: Text('尚无同步历史。'))
      : ListView.builder(
          itemCount: runs.length,
          itemBuilder: (context, index) {
            final run = runs[index];
            return ListTile(
              title: Text(run.state),
              subtitle: Text(
                '${_formatTime(run.startedAt)}${run.errorCode == null ? '' : ' · ${run.errorCode}'}',
              ),
            );
          },
        );
}

class _ConflictsTab extends StatelessWidget {
  const _ConflictsTab({required this.conflicts});
  final List<SyncConflictRecord> conflicts;

  @override
  Widget build(BuildContext context) => conflicts.isEmpty
      ? const Center(child: Text('没有待处理冲突。'))
      : ListView.builder(
          itemCount: conflicts.length,
          itemBuilder: (context, index) {
            final conflict = conflicts[index];
            return ListTile(
              leading: const Icon(Icons.warning_amber_rounded),
              title: Text(_conflictLabel(conflict.type)),
              subtitle: Text(
                '对象 ${_shortId(conflict.entityId)} · ${_formatTime(conflict.createdAt)}',
              ),
              trailing: TextButton(
                onPressed: () => context.go('/activity'),
                child: const Text('在活动中处理'),
              ),
            );
          },
        );
}

class _ProfileSettingsTab extends ConsumerWidget {
  const _ProfileSettingsTab({required this.profile, required this.onChanged});
  final SyncProfileEnvelope profile;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    children: [
      SwitchListTile(
        title: const Text('后台同步'),
        subtitle: const Text('仅在系统允许且配置处于活动状态时运行。'),
        value: profile.backgroundPolicy.enabled,
        onChanged: (value) =>
            _save(ref, profile.backgroundPolicy.copyWith(enabled: value)),
      ),
      SwitchListTile(
        title: const Text('允许蜂窝网络'),
        value: profile.backgroundPolicy.allowCellular,
        onChanged: profile.backgroundPolicy.enabled
            ? (value) => _save(
                ref,
                profile.backgroundPolicy.copyWith(allowCellular: value),
              )
            : null,
      ),
      SwitchListTile(
        title: const Text('仅充电时运行'),
        value: profile.backgroundPolicy.requiresCharging,
        onChanged: profile.backgroundPolicy.enabled
            ? (value) => _save(
                ref,
                profile.backgroundPolicy.copyWith(requiresCharging: value),
              )
            : null,
      ),
      const Divider(),
      ListTile(
        title: const Text('移除同步配置'),
        subtitle: const Text('不会删除远端数据或安全存储中的凭据。运行中的配置无法移除。'),
        textColor: Theme.of(context).colorScheme.error,
        onTap: () async {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('移除同步配置？'),
              content: const Text('此操作只移除本地配置。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('移除'),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
          try {
            await ref
                .read(syncProfileRepositoryProvider)
                .remove(profile.profileId);
            if (context.mounted) context.go('/dashboard');
          } on SyncProfileRemovalWhileRunningException {
            if (context.mounted) _showMessage(context, '同步正在运行，暂时无法移除。');
          }
        },
      ),
    ],
  );

  Future<void> _save(WidgetRef ref, SyncProfileBackgroundPolicy policy) async {
    await ref
        .read(syncProfileRepositoryProvider)
        .save(profile.copyWith(backgroundPolicy: policy));
    onChanged();
  }
}

class SyncSettings extends ConsumerStatefulWidget {
  const SyncSettings({super.key});

  @override
  ConsumerState<SyncSettings> createState() => _SyncSettingsState();
}

class _SyncSettingsState extends ConsumerState<SyncSettings> {
  late Future<SyncSettingsSnapshot> _snapshot;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _snapshot = ref.read(syncSettingsServiceProvider).load();
  }

  void _reload() {
    setState(() {
      _snapshot = ref.read(syncSettingsServiceProvider).load();
    });
  }

  Future<void> _save(SyncGlobalSettings settings) async {
    setState(() {
      _busy = true;
      _snapshot = ref.read(syncSettingsServiceProvider).save(settings);
    });
    try {
      await _snapshot;
    } on Object {
      if (mounted) {
        _showMessage(context, '无法保存全局同步设置。');
        _reload();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cleanupStaging() async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(syncSettingsServiceProvider)
          .cleanupStaging();
      if (!mounted) return;
      _showMessage(
        context,
        '已释放 ${_formatBytes(result.freedBytes)}；'
        '保留 ${result.preservedRecoverableBatchCount} 个可恢复批次'
        '${result.busyProfileCount == 0 ? '。' : '，${result.busyProfileCount} 个运行中配置未清理。'}',
      );
      _reload();
    } on Object {
      if (mounted) _showMessage(context, '暂存空间清理未完成，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showDiagnostics() async {
    setState(() => _busy = true);
    try {
      final diagnostics = await ref
          .read(syncSettingsServiceProvider)
          .exportSanitizedDiagnostics();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('脱敏诊断'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: SelectionArea(
                child: Text(
                  diagnostics,
                  key: const Key('sanitized-diagnostics-content'),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const Key('copy-sanitized-diagnostics'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: diagnostics));
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('复制'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    } on Object {
      if (mounted) _showMessage(context, '无法生成脱敏诊断。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: FutureBuilder<SyncSettingsSnapshot>(
      future: _snapshot,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: Semantics(
              label: '正在加载同步设置',
              child: const CircularProgressIndicator(),
            ),
          );
        }
        if (snapshot.hasError) {
          return _RetryState(onRetry: _reload, message: '无法读取同步设置。');
        }
        final value = snapshot.requireData;
        final settings = value.settings;
        return ListView(
          children: [
            const _SettingsHeader('后台同步'),
            SwitchListTile(
              key: const Key('global-background-enabled'),
              title: const Text('全局后台同步'),
              subtitle: Text(
                value.backgroundSupported
                    ? '${value.backgroundEligibleProfileCount} 个配置已启用后台同步'
                    : '当前系统或构建不支持后台任务',
              ),
              value: settings.backgroundEnabled,
              onChanged: _busy || !value.backgroundSupported
                  ? null
                  : (enabled) =>
                        _save(settings.copyWith(backgroundEnabled: enabled)),
            ),
            ListTile(
              leading: Icon(
                value.backgroundSupported
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
              ),
              title: const Text('系统后台状态'),
              subtitle: Text(value.backgroundSupported ? '可用' : '不可用'),
            ),
            const _SettingsHeader('新配置默认策略'),
            SwitchListTile(
              key: const Key('default-allow-cellular'),
              title: const Text('默认允许蜂窝网络'),
              subtitle: const Text('只影响此后创建的配置；已有配置保持自己的策略。'),
              value: settings.defaultAllowCellular,
              onChanged: _busy
                  ? null
                  : (enabled) =>
                        _save(settings.copyWith(defaultAllowCellular: enabled)),
            ),
            SwitchListTile(
              key: const Key('default-requires-charging'),
              title: const Text('默认仅充电时运行'),
              value: settings.defaultRequiresCharging,
              onChanged: _busy
                  ? null
                  : (enabled) => _save(
                      settings.copyWith(defaultRequiresCharging: enabled),
                    ),
            ),
            ListTile(
              title: const Text('默认蜂窝网络传输上限'),
              subtitle: const Text('加密内容按单个传输对象限制。'),
              trailing: DropdownButton<int>(
                key: const Key('default-cellular-limit'),
                value: _supportedCellularLimit(
                  settings.defaultCellularMaxTransferBytes,
                ),
                onChanged: _busy
                    ? null
                    : (bytes) {
                        if (bytes != null) {
                          _save(
                            settings.copyWith(
                              defaultCellularMaxTransferBytes: bytes,
                            ),
                          );
                        }
                      },
                items: const [
                  DropdownMenuItem(
                    value: 10 * 1024 * 1024,
                    child: Text('10 MiB'),
                  ),
                  DropdownMenuItem(
                    value: 50 * 1024 * 1024,
                    child: Text('50 MiB'),
                  ),
                  DropdownMenuItem(
                    value: 100 * 1024 * 1024,
                    child: Text('100 MiB'),
                  ),
                ],
              ),
            ),
            const _SettingsHeader('暂存空间'),
            ListTile(
              title: Text(_formatBytes(value.staging.totalBytes)),
              subtitle: Text(
                '${value.staging.batchCount} 个批次 · ${value.staging.fileCount} 个文件。'
                '清理会保留可恢复批次，并跳过正在同步的配置。',
              ),
              trailing: OutlinedButton.icon(
                key: const Key('cleanup-staging'),
                onPressed: _busy ? null : _cleanupStaging,
                icon: const Icon(Icons.cleaning_services_outlined),
                label: const Text('安全清理'),
              ),
            ),
            const _SettingsHeader('隐私与诊断'),
            const ListTile(
              title: Text('隐私保护'),
              subtitle: Text(
                '日志和诊断不包含凭据、密钥、原始路径、Profile 标识、'
                'Velock 业务内容或受保护冲突详情。',
              ),
            ),
            ListTile(
              title: const Text('导出脱敏诊断'),
              subtitle: const Text('仅导出版本、系统能力、聚合计数、稳定错误码和暂存用量。'),
              trailing: FilledButton.icon(
                key: const Key('export-sanitized-diagnostics'),
                onPressed: _busy ? null : _showDiagnostics,
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('生成'),
              ),
            ),
            const _SettingsHeader('版本与许可'),
            const ListTile(
              title: Text('协议版本'),
              subtitle: Text(syncProtocolDisplayVersion),
            ),
            const ListTile(
              title: Text('应用版本'),
              subtitle: Text(syncAppDisplayVersion),
            ),
            ListTile(
              title: const Text('About / Licenses'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Velock Sync',
                applicationVersion: syncAppDisplayVersion,
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _DetailData {
  const _DetailData({
    required this.profile,
    required this.latestRun,
    required this.runs,
    required this.transfers,
    required this.conflicts,
  });
  final SyncProfileEnvelope? profile;
  final SyncRunRecord? latestRun;
  final List<SyncRunRecord> runs;
  final List<TransferJobRecord> transfers;
  final List<SyncConflictRecord> conflicts;
}

class _RetryState extends StatelessWidget {
  const _RetryState({required this.onRetry, required this.message});
  final VoidCallback onRetry;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      label: message,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

String _kindLabel(SyncDatasetKind? kind) => switch (kind) {
  SyncDatasetKind.selectedFolder => 'Selected Folder',
  SyncDatasetKind.velockManaged => 'Velock managed',
  null => '不可用',
};

IconData _kindIcon(SyncDatasetKind? kind) => switch (kind) {
  SyncDatasetKind.selectedFolder => Icons.folder_outlined,
  SyncDatasetKind.velockManaged => Icons.shield_outlined,
  null => Icons.error_outline,
};

String _stateLabel(SyncProfileState state) => switch (state) {
  SyncProfileState.active => '已启用',
  SyncProfileState.paused => '已暂停',
  SyncProfileState.accessRequired => '需要授权',
  SyncProfileState.reauthorizationRequired => '需要重新授权',
  SyncProfileState.blockedByConfiguration => '配置不完整',
  SyncProfileState.error => '需要处理',
};

String _activityText(SyncProfileActivitySummary? activity) {
  if (activity == null) {
    return '';
  }
  if (activity.unresolvedConflictCount > 0) {
    return ' · ${activity.unresolvedConflictCount} 个冲突';
  }
  if (activity.pendingUploadCount + activity.pendingDownloadCount > 0) {
    return ' · 有待传输项目';
  }
  return '';
}

String _latestRunLabel(SyncRunRecord? latestRun) {
  final run = latestRun;
  if (run == null) return '尚未运行';
  return '${run.state} · ${_formatTime(run.startedAt)}';
}

String _dispatchLabel(SyncProfileDispatchStatus status) => switch (status) {
  SyncProfileDispatchStatus.completed => '已完成',
  SyncProfileDispatchStatus.skippedNotRunnable => '当前状态不允许同步',
  SyncProfileDispatchStatus.skippedUnsupported => '此配置不受支持',
  SyncProfileDispatchStatus.failed => '发生错误',
};

String _velockReadinessTitle(VelockWizardAvailability availability) =>
    switch (availability) {
      VelockWizardAvailability.ready => '可以开始 Velock 安全配对',
      VelockWizardAvailability.appNotInstalled => '未找到 Velock App',
      VelockWizardAvailability.authorizationRequired => '需要在 Velock 中授权',
      VelockWizardAvailability.unsupportedVersion => 'Velock 版本不受支持',
      VelockWizardAvailability.signatureMismatch => 'Velock 身份验证失败',
      VelockWizardAvailability.configurationMissing => '配对通道尚未配置',
      VelockWizardAvailability.temporarilyUnavailable => 'Velock 暂时不可用',
      VelockWizardAvailability.unsupportedPlatform => '当前平台不受支持',
    };

String _velockReadinessMessage(VelockWizardAvailability availability) =>
    switch (availability) {
      VelockWizardAvailability.ready =>
        '已验证独立 Velock App、发布签名、Exchange V1 和公开配对身份。'
            '下一步会切换到 Velock，由你解锁并明确批准一次性挑战；此时仍不会创建 Profile。',
      VelockWizardAvailability.appNotInstalled =>
        '请先安装独立的 Velock App，完成初始化后返回重试。',
      VelockWizardAvailability.authorizationRequired =>
        'Velock 的 Exchange 拒绝了访问。请在 Velock 中明确允许 Velock Sync 后重试。',
      VelockWizardAvailability.unsupportedVersion =>
        '当前 Velock App 不支持 Exchange V1，请升级 Velock 后重试。',
      VelockWizardAvailability.signatureMismatch =>
        '已安装应用未通过发布签名校验。为保护数据，本应用不会继续连接。',
      VelockWizardAvailability.configurationMissing =>
        '受保护的 Exchange 数据通道可探测，但当前构建尚未提供签名授权/配对控制通道。'
            '本应用不会猜测身份，也不会创建半成品 Profile。',
      VelockWizardAvailability.temporarilyUnavailable =>
        'Velock 的受保护 Exchange 当前无法访问；未保存任何配置，可稍后重试。',
      VelockWizardAvailability.unsupportedPlatform =>
        'Velock managed data 仅支持已配置 Android 或 Apple Exchange 的构建。',
    };

String _conflictLabel(String type) => switch (type.split(':').first) {
  'modify-modify' => '两个设备都修改了内容',
  'delete-modify' => '删除与修改发生冲突',
  _ => '需要处理的同步冲突',
};

String _shortId(String value) =>
    value.length <= 12 ? value : '${value.substring(0, 12)}…';
String _formatTime(DateTime value) =>
    '${value.toLocal().year}-${value.toLocal().month.toString().padLeft(2, '0')}-${value.toLocal().day.toString().padLeft(2, '0')} ${value.toLocal().hour.toString().padLeft(2, '0')}:${value.toLocal().minute.toString().padLeft(2, '0')}';
int _supportedCellularLimit(int value) {
  const tenMiB = 10 * 1024 * 1024;
  const hundredMiB = 100 * 1024 * 1024;
  if (value == tenMiB || value == hundredMiB) return value;
  return 50 * 1024 * 1024;
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '$bytes B';
}

void _showMessage(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));
