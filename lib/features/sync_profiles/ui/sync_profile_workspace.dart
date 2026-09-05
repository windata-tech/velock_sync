import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_pairing_control_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher_factory.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_profile_finalizer.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

/// UI-level seam so widget tests can verify the Velock action without
/// executing platform IPC, providers, or a remote transfer.
abstract interface class SyncProfileRunService {
  Future<SyncProfileDispatchResult> runNow(String profileId);
}

final syncProfileRunServiceProvider = Provider<SyncProfileRunService>(
  (ref) => _ForegroundSyncProfileRunService(
    database: ref.watch(syncStateDatabaseProvider),
    profiles: ref.watch(syncProfileRepositoryProvider),
    connections: ref.watch(connectionRepositoryProvider),
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

/// Existing Velock-managed sync profiles. A device may only keep one Velock
/// pairing, so a created profile blocks starting another pairing until it is
/// deleted. Auto-disposed so leaving and re-entering the wizard re-reads the
/// repository after a deletion.
final velockExistingProfilesProvider =
    FutureProvider.autoDispose<List<SyncProfileSummary>>((ref) {
      ref.watch(profilesRevisionProvider);
      return ref
          .watch(syncProfileRepositoryProvider)
          .listSummaries(kind: SyncDatasetKind.velockManaged);
    });

/// App-scoped pairing state for the Velock wizard. Holding the session outside
/// the page keeps an approved pairing usable after the user leaves the wizard
/// to create a missing connection and returns.
class VelockWizardSessionState {
  const VelockWizardSessionState({
    this.session,
    this.approval,
    this.finalization,
    this.connectionNeeded = false,
  });

  final VelockPairingSession? session;
  final VelockPairingControlResponse? approval;
  final VelockProfileFinalizationResult? finalization;

  /// Set when the wizard found no active remote connection while an approved
  /// pairing was waiting to continue.
  final bool connectionNeeded;

  VelockWizardSessionState copyWith({
    VelockPairingSession? session,
    VelockPairingControlResponse? approval,
    VelockProfileFinalizationResult? finalization,
    bool? connectionNeeded,
  }) => VelockWizardSessionState(
    session: session ?? this.session,
    approval: approval ?? this.approval,
    finalization: finalization ?? this.finalization,
    connectionNeeded: connectionNeeded ?? this.connectionNeeded,
  );
}

class VelockWizardSessionController extends Notifier<VelockWizardSessionState> {
  @override
  VelockWizardSessionState build() => const VelockWizardSessionState();

  void sessionStarted(VelockPairingSession session) =>
      state = VelockWizardSessionState(session: session);

  void approved(VelockPairingControlResponse approval) =>
      state = state.copyWith(approval: approval, connectionNeeded: false);

  void connectionMissing() => state = state.copyWith(connectionNeeded: true);

  /// The missing remote connection has since been created; the approved
  /// pairing can continue without the "connection needed" banner.
  void connectionResolved() => state = state.copyWith(connectionNeeded: false);

  void profileFinalized(VelockProfileFinalizationResult result) =>
      state = state.copyWith(
        finalization: result,
        session: result.pairingAcknowledged ? null : state.session,
        approval: result.pairingAcknowledged ? null : state.approval,
        connectionNeeded: false,
      );

  /// A freshly opened wizard must not keep showing an already-completed
  /// profile: the home list is the canonical place to see created profiles.
  /// In-progress pairings (approval waiting for a connection) are preserved.
  void clearCompletedFlow() {
    if (state.finalization == null) return;
    state = const VelockWizardSessionState();
  }

  void acknowledged() {
    final result = state.finalization;
    state = VelockWizardSessionState(
      finalization: result == null
          ? null
          : VelockProfileFinalizationResult(
              profile: result.profile,
              pairingAcknowledged: true,
            ),
    );
  }

  void reset() => state = const VelockWizardSessionState();
}

final velockWizardSessionProvider =
    NotifierProvider<VelockWizardSessionController, VelockWizardSessionState>(
      VelockWizardSessionController.new,
    );

/// Bumped whenever a profile is created so the Sync home can reload its list
/// even while its page state is kept alive by the navigation shell.
class ProfilesRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final profilesRevisionProvider = NotifierProvider<ProfilesRevision, int>(
  ProfilesRevision.new,
);

class _ForegroundSyncProfileRunService implements SyncProfileRunService {
  _ForegroundSyncProfileRunService({
    required SyncStateDatabase database,
    required SyncProfileRepository profiles,
    required this.connections,
  }) : _database = database,
       _profiles = profiles;

  final SyncStateDatabase _database;
  final SyncProfileRepository _profiles;
  final ConnectionRepository connections;
  Future<SyncProfileDispatcher>? _dispatcher;

  @override
  Future<SyncProfileDispatchResult> runNow(String profileId) async =>
      (await (_dispatcher ??= _buildDispatcher())).dispatch(profileId);

  Future<SyncProfileDispatcher> _buildDispatcher() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final stagingRoot = Directory('${supportDirectory.path}/staging');
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
  late Future<_SyncProfilesLoadResult> _profiles;

  @override
  void initState() {
    super.initState();
    _profiles = _load();
  }

  Future<_SyncProfilesLoadResult> _load() async {
    final profiles = await ref
        .read(syncProfileRepositoryProvider)
        .listSummaries();
    final hasVelockProfile = profiles.any(
      (profile) => profile.kind == SyncDatasetKind.velockManaged,
    );
    if (!hasVelockProfile) {
      return _SyncProfilesLoadResult(profiles: profiles);
    }
    final velockProfile = profiles.firstWhere(
      (profile) => profile.kind == SyncDatasetKind.velockManaged,
    );
    final readiness = await ref
        .read(velockWizardReadinessServiceProvider)
        .inspect(syncAppInstanceId: velockProfile.deviceId)
        .timeout(
          const Duration(seconds: 1),
          onTimeout: () => const VelockWizardReadiness(
            VelockWizardAvailability.temporarilyUnavailable,
          ),
        );
    if (readiness.availability == VelockWizardAvailability.accessRevoked) {
      await ref
          .read(syncProfileRepositoryProvider)
          .setState(velockProfile.profileId, SyncProfileState.accessRequired);
    }
    return _SyncProfilesLoadResult(
      profiles: profiles,
      velockAvailability: readiness.availability,
    );
  }

  void _refresh() => setState(() {
    _profiles = _load();
  });

  Future<void> _refreshAndWait() async {
    final profiles = _load();
    setState(() {
      _profiles = profiles;
    });
    await profiles;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(profilesRevisionProvider, (previous, next) {
      if (previous != next) _refresh();
    });
    void createProfile() => context.push('/sync-profiles/new');
    return FutureBuilder<_SyncProfilesLoadResult>(
      future: _profiles,
      builder: (context, snapshot) => AdaptiveSliverScaffold(
        title: '同步',
        showTitle: false,
        useLargeTitle: false,
        actions: [
          if (isApplePlatform(context))
            AdaptiveIconButton(
              key: const Key('sync-profile-create'),
              tooltip: '新建同步配置',
              onPressed: createProfile,
              icon: const Icon(CupertinoIcons.add),
            ),
          AdaptiveIconButton(
            tooltip: '刷新同步配置',
            onPressed: _refreshAndWait,
            icon: Icon(
              adaptiveIcon(
                context,
                material: Icons.refresh_rounded,
                cupertino: CupertinoIcons.refresh,
              ),
            ),
          ),
        ],
        floatingActionButton: isApplePlatform(context)
            ? null
            : FloatingActionButton.extended(
                key: const Key('sync-profile-create'),
                tooltip: '新建同步配置',
                onPressed: createProfile,
                icon: const Icon(Icons.add_rounded),
                label: const Text('新建'),
              ),
        slivers: _profileSlivers(context, snapshot, onCreate: createProfile),
      ),
    );
  }

  List<Widget> _profileSlivers(
    BuildContext context,
    AsyncSnapshot<_SyncProfilesLoadResult> snapshot, {
    required VoidCallback onCreate,
  }) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveLoadingState(label: '正在加载同步配置'),
        ),
      ];
    }
    if (snapshot.hasError) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveErrorState(message: '无法读取同步配置。', onRetry: _refresh),
        ),
      ];
    }
    final loaded = snapshot.requireData;
    final profiles = loaded.profiles;
    if (profiles.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Semantics(
            label: '没有同步配置',
            child: AdaptiveEmptyState(
              icon: adaptiveIcon(
                context,
                material: Icons.sync_rounded,
                cupertino: CupertinoIcons.arrow_2_circlepath,
              ),
              title: '开始你的第一次同步',
              message: '还没有同步配置。请新建一个配置开始同步。',
              action: isApplePlatform(context)
                  ? CupertinoButton.filled(
                      onPressed: onCreate,
                      child: const Text('新建同步配置'),
                    )
                  : FilledButton.icon(
                      onPressed: onCreate,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('新建同步配置'),
                    ),
            ),
          ),
        ),
      ];
    }
    final velockIssue =
        loaded.velockAvailability != null &&
        loaded.velockAvailability != VelockWizardAvailability.ready &&
        profiles.any(
          (profile) => profile.kind == SyncDatasetKind.velockManaged,
        );
    return [
      if (velockIssue)
        SliverToBoxAdapter(
          child: _VelockConnectionBanner(
            availability: loaded.velockAvailability!,
            onRetry: _refresh,
          ),
        ),
      SliverToBoxAdapter(
        child: _SyncOverview(
          profiles: profiles,
          velockAvailability: loaded.velockAvailability,
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          topPadding: AppSpacing.xs,
          header: '同步配置',
          headerTrailing: Text(
            '${profiles.length} 个',
            style: TextStyle(
              color: context.appSecondaryLabel,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.15,
            ),
          ),
          children: [
            for (final profile in profiles)
              _ProfileTile(
                summary: profile,
                onChanged: _refresh,
                velockAvailability: loaded.velockAvailability,
              ),
          ],
        ),
      ),
    ];
  }
}

class _SyncProfilesLoadResult {
  const _SyncProfilesLoadResult({
    required this.profiles,
    this.velockAvailability,
  });

  final List<SyncProfileSummary> profiles;
  final VelockWizardAvailability? velockAvailability;
}

class _VelockConnectionBanner extends StatelessWidget {
  const _VelockConnectionBanner({
    required this.availability,
    required this.onRetry,
  });

  final VelockWizardAvailability availability;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final title = switch (availability) {
      VelockWizardAvailability.appNotInstalled => 'Velock 本体未安装，连接已断开',
      VelockWizardAvailability.authorizationRequired => 'Velock 连接未授权',
      VelockWizardAvailability.accessRevoked => 'Velock 已撤销同步授权',
      VelockWizardAvailability.unsupportedVersion => 'Velock 版本不受支持',
      VelockWizardAvailability.signatureMismatch => 'Velock 身份验证失败',
      VelockWizardAvailability.configurationMissing => 'Velock 连接已断开',
      VelockWizardAvailability.temporarilyUnavailable => 'Velock 连接暂不可用',
      VelockWizardAvailability.unsupportedPlatform => '当前平台不支持 Velock 连接',
      VelockWizardAvailability.ready => 'Velock 连接正常',
    };
    return Container(
      key: const Key('velock-connection-banner'),
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.page,
        AppSpacing.page,
        AppSpacing.xs,
      ),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.large),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdaptiveIconBadge(
            icon: adaptiveIcon(
              context,
              material: Icons.link_off_rounded,
              cupertino: CupertinoIcons.link_circle,
            ),
            color: AppColors.danger,
            size: 36,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.danger,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _velockAvailabilitySubtitle(availability),
                  style: TextStyle(
                    color: context.appSecondaryLabel,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('retry-velock-connection'),
            onPressed: onRetry,
            child: const Text('重新检测'),
          ),
        ],
      ),
    );
  }
}

class _SyncOverview extends StatelessWidget {
  const _SyncOverview({required this.profiles, this.velockAvailability});

  final List<SyncProfileSummary> profiles;
  final VelockWizardAvailability? velockAvailability;

  @override
  Widget build(BuildContext context) {
    final velockUnavailable =
        velockAvailability != null &&
        velockAvailability != VelockWizardAvailability.ready;
    bool isUnavailable(SyncProfileSummary profile) =>
        velockUnavailable && profile.kind == SyncDatasetKind.velockManaged;
    final active = profiles
        .where((profile) => profile.isRunnable && !isUnavailable(profile))
        .length;
    final background = profiles
        .where(
          (profile) => profile.isBackgroundEligible && !isUnavailable(profile),
        )
        .length;
    final attention = profiles
        .where(
          (profile) =>
              profile.isIsolated ||
              isUnavailable(profile) ||
              profile.state == SyncProfileState.accessRequired ||
              profile.state == SyncProfileState.reauthorizationRequired ||
              profile.state == SyncProfileState.blockedByConfiguration ||
              profile.state == SyncProfileState.error,
        )
        .length;
    final isHealthy = attention == 0;
    final hasVelockIssue = profiles.any((profile) => isUnavailable(profile));
    final color = hasVelockIssue
        ? AppColors.danger
        : isHealthy
        ? AppColors.success
        : AppColors.warning;
    return AdaptiveSummaryCard(
      icon: adaptiveIcon(
        context,
        material: isHealthy
            ? Icons.shield_outlined
            : Icons.warning_amber_rounded,
        cupertino: isHealthy
            ? CupertinoIcons.shield
            : CupertinoIcons.exclamationmark_triangle,
      ),
      color: color,
      eyebrow: '同步概览',
      title: hasVelockIssue
          ? 'Velock 连接已断开'
          : isHealthy
          ? '同步运行正常'
          : '$attention 项需要关注',
      status: AdaptiveStatusBadge(
        label: hasVelockIssue
            ? '连接断开'
            : isHealthy
            ? '状态良好'
            : '需处理',
        color: color,
      ),
      metrics: [
        AdaptiveSummaryMetric(value: '$active', label: '可运行'),
        AdaptiveSummaryMetric(value: '$background', label: '后台开启'),
        AdaptiveSummaryMetric(value: '$attention', label: '需要处理'),
      ],
    );
  }
}

class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({
    required this.summary,
    required this.onChanged,
    this.velockAvailability,
  });

  final SyncProfileSummary summary;
  final VoidCallback onChanged;
  final VelockWizardAvailability? velockAvailability;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = summary.displayName ?? '不可用的同步配置';
    final velockUnavailable =
        summary.kind == SyncDatasetKind.velockManaged &&
        velockAvailability != null &&
        velockAvailability != VelockWizardAvailability.ready;
    final statusColor = velockUnavailable
        ? AppColors.danger
        : _profileStateColor(context, summary.state);
    final statusLabel = velockUnavailable
        ? _velockAvailabilityLabel(velockAvailability!)
        : _stateLabel(summary.state);
    final subtitleText = velockUnavailable
        ? '${_kindLabel(summary.kind)}，${_velockAvailabilitySubtitle(velockAvailability!)}'
        : summary.isIsolated
        ? '此配置无法安全读取。'
        : _profileSecondaryText(summary);
    final subtitle = velockUnavailable
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_kindLabel(summary.kind)),
              Text(_velockAvailabilitySubtitle(velockAvailability!)),
            ],
          )
        : Text(
            subtitleText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.25),
          );
    return Semantics(
      label: '$title，$subtitleText，$statusLabel',
      child: AdaptiveListTile(
        leading: AdaptiveIconBadge(
          icon: _adaptiveKindIcon(context, summary.kind),
          color: statusColor,
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, height: 1.2),
        ),
        subtitle: subtitle,
        isThreeLine: velockUnavailable,
        enabled: !summary.isIsolated,
        onTap: () => context.push('/sync-profiles/${summary.profileId}'),
        trailing: AdaptiveTrailingGroup(
          children: [
            AdaptiveStatusBadge(label: statusLabel, color: statusColor),
            AdaptiveActionMenu<_ProfileAction>(
              tooltip: '同步配置操作',
              onSelected: (action) => _runAction(context, ref, action),
              items: [
                if (summary.isRunnable && !velockUnavailable)
                  const AdaptiveActionItem(
                    value: _ProfileAction.syncNow,
                    label: '立即同步',
                    icon: Icons.sync_rounded,
                  ),
                if (summary.state == SyncProfileState.active)
                  const AdaptiveActionItem(
                    value: _ProfileAction.pause,
                    label: '暂停',
                    icon: Icons.pause_rounded,
                  ),
                if (summary.state == SyncProfileState.paused)
                  const AdaptiveActionItem(
                    value: _ProfileAction.resume,
                    label: '恢复',
                    icon: Icons.play_arrow_rounded,
                  ),
                const AdaptiveActionItem(
                  value: _ProfileAction.remove,
                  label: '删除同步配置',
                  icon: Icons.delete_outline_rounded,
                  isDestructive: true,
                ),
              ],
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
        case _ProfileAction.syncNow:
          final result = await _runSyncWithProgress(
            context,
            ref,
            summary.profileId,
          );
          if (!context.mounted || result == null) return;
          _showMessage(context, _syncResultMessage(result));
        case _ProfileAction.pause:
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(summary.profileId, SyncProfileState.paused);
        case _ProfileAction.resume:
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(summary.profileId, SyncProfileState.active);
        case _ProfileAction.remove:
          if (!await _confirmSyncProfileRemoval(
            context,
            summary.displayName ?? '不可用的同步配置',
          )) {
            return;
          }
          final forceRunning =
              summary.kind == SyncDatasetKind.velockManaged &&
              velockAvailability != null &&
              velockAvailability != VelockWizardAvailability.ready;
          await ref
              .read(syncProfileRepositoryProvider)
              .remove(summary.profileId, forceRunning: forceRunning);
      }
      onChanged();
    } on SyncProfileRemovalWhileRunningException {
      if (context.mounted) {
        _showMessage(context, '同步正在运行，暂时无法删除。');
      }
    } on Object {
      if (context.mounted) {
        _showMessage(context, '操作未完成，请稍后重试。');
      }
    }
  }
}

enum _ProfileAction { syncNow, pause, resume, remove }

Future<SyncProfileDispatchResult?> _runSyncWithProgress(
  BuildContext context,
  WidgetRef ref,
  String profileId,
) async {
  showAdaptiveBlockingProgress(
    context,
    key: const Key('sync-progress-dialog'),
    message: '正在同步…',
  );
  try {
    return await ref.read(syncProfileRunServiceProvider).runNow(profileId);
  } finally {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
}

Future<bool> _confirmSyncProfileRemoval(
  BuildContext context,
  String displayName,
) => showAdaptiveConfirmation(
  context,
  title: '删除同步配置？',
  message: '“$displayName”将从本机删除。远端同步空间和文件不会被删除。',
  confirmLabel: '删除',
  isDestructive: true,
);

/* Future<String?> _requestProfileRecoveryPassphrase(BuildContext context) async {
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
} */

/* Future<void> _showProfileRecoveryPackage(
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
} */

class SyncProfileWizard extends ConsumerStatefulWidget {
  const SyncProfileWizard({super.key});
  @override
  ConsumerState<SyncProfileWizard> createState() => _SyncProfileWizardState();
}

class _SyncProfileWizardState extends ConsumerState<SyncProfileWizard> {
  @override
  void initState() {
    super.initState();
    // A freshly opened wizard must not keep showing an already-completed
    // flow; in-progress pairings survive in the app-scoped session provider.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(velockWizardSessionProvider.notifier).clearCompletedFlow();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final existingVelockProfiles =
        ref.watch(velockExistingProfilesProvider).asData?.value ??
        const <SyncProfileSummary>[];
    final pairedVelock = existingVelockProfiles.isEmpty
        ? null
        : existingVelockProfiles.first;
    return AdaptiveScaffold(
      title: '新建同步配置',
      body: ListView(
        children: [
          const SizedBox(height: AppSpacing.xs),
          AdaptiveListSection(
            header: '选择数据集',
            footer: const Text(
              '配置过程中只保存安全存储引用，不保存密钥或登录凭据。失败或取消不会创建半成品 Profile。',
            ),
            children: [
              if (pairedVelock != null)
                AdaptiveListTile(
                  widgetKey: const Key('velock-already-paired'),
                  enabled: false,
                  leading: AdaptiveIconBadge(
                    icon: adaptiveIcon(
                      context,
                      material: Icons.shield_outlined,
                      cupertino: CupertinoIcons.shield,
                    ),
                    color: AppColors.success,
                  ),
                  title: const Text('Velock managed data'),
                  subtitle: Text(
                    '已配对 ${pairedVelock.displayName ?? 'Velock'}。如需重新配对，请到首页 Sync 删除该配置后再使用。',
                  ),
                  trailing: Icon(
                    adaptiveIcon(
                      context,
                      material: Icons.lock_outline,
                      cupertino: CupertinoIcons.lock,
                    ),
                  ),
                )
              else
                AdaptiveListTile(
                  widgetKey: const Key('enter-velock-flow'),
                  leading: AdaptiveIconBadge(
                    icon: adaptiveIcon(
                      context,
                      material: Icons.shield_outlined,
                      cupertino: CupertinoIcons.shield,
                    ),
                  ),
                  title: const Text('Velock managed data'),
                  subtitle: const Text(
                    '检查独立 Velock App、签名保护的 Exchange、授权与配对能力。',
                  ),
                  showChevron: true,
                  onTap: () => context.push(AppRoutes.velockDatasetWizard.path),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class VelockDatasetWizard extends ConsumerStatefulWidget {
  const VelockDatasetWizard({super.key});

  @override
  ConsumerState<VelockDatasetWizard> createState() =>
      _VelockDatasetWizardState();
}

enum _PairingRecoveryAction { cancel, reopen }

class _VelockDatasetWizardState extends ConsumerState<VelockDatasetWizard>
    with WidgetsBindingObserver {
  bool _checkingVelock = false;
  bool _inspectingPairing = false;
  bool _pairingProblemDialogVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Returning from Velock automatically inspects a pending approval. The
    // post-frame entry check also resumes retained pairing/connection state.
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareWizardEntry());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _handleVelockAppResume();
  }

  Future<void> _handleVelockAppResume() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    final wizard = ref.read(velockWizardSessionProvider);
    if (wizard.session == null || wizard.approval != null) return;
    await _inspectPendingVelockPairing(wizard.session!);
  }

  Future<void> _prepareWizardEntry() async {
    if (!mounted) return;
    // Do not re-surface a previously completed profile in a new wizard entry.
    // Deferred to the post-frame phase: modifying provider state during
    // initState/build throws "tried to modify a provider while building".
    ref.read(velockWizardSessionProvider.notifier).clearCompletedFlow();
    final wizard = ref.read(velockWizardSessionProvider);
    if (wizard.session != null && wizard.approval == null) {
      await _inspectPendingVelockPairing(wizard.session!);
      return;
    }
    await _autoResumeVelockWizard();
  }

  Future<void> _autoResumeVelockWizard() async {
    if (!mounted) return;
    final wizard = ref.read(velockWizardSessionProvider);
    final session = wizard.session;
    final approval = wizard.approval;
    if (session == null || approval == null || !wizard.connectionNeeded) {
      return;
    }
    final connections = (await ref.read(velockWizardConnectionsProvider)())
        .where(
          (connection) =>
              connection.status == ConnectionStatus.active ||
              connection.status == ConnectionStatus.pending,
        )
        .toList(growable: false);
    if (!mounted || connections.isEmpty) return;
    ref.read(velockWizardSessionProvider.notifier).connectionResolved();
    await _continueVelockProfile(session, approval);
  }

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
      setState(() => _checkingVelock = false);
      ref.read(velockWizardSessionProvider.notifier).sessionStarted(session);
    } on Object {
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      _showMessage(context, '无法发起安全配对；未创建任何 Profile。');
    }
  }

  Future<void> _inspectPendingVelockPairing(
    VelockPairingSession session,
  ) async {
    if (!mounted || _inspectingPairing) return;
    _inspectingPairing = true;
    setState(() => _checkingVelock = true);
    try {
      final state = await ref
          .read(velockPairingSessionServiceProvider)
          .inspect(session);
      if (!mounted) return;
      _inspectingPairing = false;
      setState(() => _checkingVelock = false);
      if (state.isApproved) {
        final approval = state.response!;
        ref.read(velockWizardSessionProvider.notifier).approved(approval);
        await _continueVelockProfile(session, approval);
        return;
      }
      if (state.status == VelockPairingControlStatus.pending) {
        await _showPendingPairingProblem(session);
        return;
      }
      ref.read(velockWizardSessionProvider.notifier).reset();
      await _showEndedPairingProblem(state.status);
    } on Object {
      if (!mounted) return;
      _inspectingPairing = false;
      setState(() => _checkingVelock = false);
      ref.read(velockWizardSessionProvider.notifier).reset();
      await _showEndedPairingProblem(null);
    }
  }

  Future<void> _showPendingPairingProblem(VelockPairingSession session) async {
    if (!mounted || _pairingProblemDialogVisible) return;
    _pairingProblemDialogVisible = true;
    final action = await showDialog<_PairingRecoveryAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.sync_problem_outlined),
        title: const Text('尚未收到 Velock 批准'),
        content: const Text(
          '如果你刚开启“允许新的配对”，请重新打开 Velock 并刷新待审批请求。仍看不到时，取消后重新发起。',
        ),
        actions: [
          TextButton(
            key: const Key('cancel-velock-pairing'),
            onPressed: () =>
                Navigator.pop(dialogContext, _PairingRecoveryAction.cancel),
            child: const Text('取消配对'),
          ),
          FilledButton(
            key: const Key('reopen-velock-pairing'),
            onPressed: () =>
                Navigator.pop(dialogContext, _PairingRecoveryAction.reopen),
            child: const Text('重新打开 Velock'),
          ),
        ],
      ),
    );
    _pairingProblemDialogVisible = false;
    if (!mounted) return;
    switch (action) {
      case _PairingRecoveryAction.cancel:
        ref.read(velockWizardSessionProvider.notifier).reset();
      case _PairingRecoveryAction.reopen:
        await _reopenVelockPairing(session);
      case null:
        return;
    }
  }

  Future<void> _reopenVelockPairing(VelockPairingSession session) async {
    try {
      await ref.read(velockPairingSessionServiceProvider).reopen(session);
    } on Object {
      if (mounted) {
        _showMessage(context, '无法重新打开 Velock，请取消后重新发起。');
      }
    }
  }

  Future<void> _showEndedPairingProblem(
    VelockPairingControlStatus? status,
  ) async {
    if (!mounted) return;
    final (title, message) = switch (status) {
      VelockPairingControlStatus.denied => (
        '配对已拒绝',
        '你已在 Velock 中拒绝本次配对，未创建任何 Profile。',
      ),
      VelockPairingControlStatus.expired => ('配对已过期', '本次请求已过期，请重新发起。'),
      VelockPairingControlStatus.revoked => (
        '授权已撤销',
        'Velock 已撤销本次授权，未创建任何 Profile。',
      ),
      _ => ('无法验证配对结果', '配对响应无效或不可用，未创建任何 Profile。'),
    };
    final retry = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.error_outline),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重新发起'),
          ),
        ],
      ),
    );
    if (retry == true && mounted) await _inspectVelock();
  }

  Future<void> _continueVelockProfile(
    VelockPairingSession session,
    VelockPairingControlResponse approval,
  ) async {
    try {
      final connections = (await ref.read(velockWizardConnectionsProvider)())
          .where(
            (connection) =>
                connection.status == ConnectionStatus.active ||
                connection.status == ConnectionStatus.pending,
          )
          .toList(growable: false);
      if (!mounted) return;
      if (connections.isEmpty) {
        ref.read(velockWizardSessionProvider.notifier).connectionMissing();
        _showMessage(context, '没有可用的远端连接。请先创建并验证连接，再回来继续。');
        return;
      }
      // A connection is available: the approved pairing can proceed, so the
      // "还需要一个远端连接" banner must not keep the flow stuck.
      ref.read(velockWizardSessionProvider.notifier).connectionResolved();

      final connection = await _chooseVelockConnection(connections);
      if (connection == null || !mounted) return;

      final review = await _reviewVelockProfile(
        approval: approval,
        connection: connection,
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
            backgroundPolicy: review.backgroundPolicy,
            userConfirmed: true,
          );
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      ref.read(velockWizardSessionProvider.notifier).profileFinalized(result);
      ref.read(profilesRevisionProvider.notifier).bump();
      _showMessage(
        context,
        result.pairingAcknowledged
            ? '已创建“${result.profile.displayName}”。'
            : 'Profile 已安全保存，但配对清理尚未确认；可在本页重试。',
      );
      if (result.pairingAcknowledged && mounted) {
        ref.read(velockWizardSessionProvider.notifier).reset();
        context.goNamed(AppRoutes.dashboard.name);
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _checkingVelock = false);
      logw('Velock profile finalization failed: ${error.runtimeType}: $error');
      final message = switch (error) {
        VelockProfileFinalizationException(:final code) => switch (code) {
          'duplicate_pairing' => '该 Velock 账号已绑定同步配置，无需重复创建；请直接使用列表中的配置。',
          'connection_missing' => '所选远端连接已不存在，请返回重新选择。',
          'connection_unavailable' => '所选远端连接当前不可用，请先在连接页验证。',
          'invalid_pairing_response' => '配对响应未通过验证；请重新发起配对。',
          'invalid_display_name' => 'Profile 名称无效，请重新输入。',
          'confirmation_required' => '未确认创建；未创建任何 Profile。',
          _ => '创建 Profile 失败（$code）；未创建任何 Profile。',
        },
        _ => '未能完成 Velock Profile；未创建任何 Profile。',
      };
      _showMessage(context, message);
    }
  }

  Future<ConnectionModel?> _chooseVelockConnection(
    List<ConnectionModel> connections,
  ) => showDialog<ConnectionModel>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('步骤 2 / 3 · 选择远端连接'),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text('选定后进入最终确认，可在那里核对远端目标。'),
        ),
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

  Future<_VelockProfileReview?> _reviewVelockProfile({
    required VelockPairingControlResponse approval,
    required ConnectionModel connection,
  }) async {
    final defaults =
        (await ref.read(syncSettingsServiceProvider).load()).settings;
    var displayName = approval.vaultDisplayName;
    var enabled = defaults.backgroundEnabled;
    var allowCellular = defaults.defaultAllowCellular;
    var requiresCharging = defaults.defaultRequiresCharging;
    var maximumBytes = defaults.defaultCellularMaxTransferBytes;
    const choices = <int>[10, 50, 100];
    if (!choices.map((value) => value * 1024 * 1024).contains(maximumBytes)) {
      maximumBytes = 50 * 1024 * 1024;
    }
    if (!mounted) return null;
    return showDialog<_VelockProfileReview>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('步骤 3 / 3 · 确认并创建'),
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
                const SizedBox(height: 8),
                const Divider(height: 1),
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
                const Divider(height: 1),
                const SizedBox(height: 8),
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
                      _VelockProfileReview(
                        displayName: displayName.trim(),
                        backgroundPolicy: SyncProfileBackgroundPolicy(
                          enabled: enabled,
                          allowCellular: enabled && allowCellular,
                          requiresCharging: enabled && requiresCharging,
                          cellularMaxTransferBytes: maximumBytes,
                        ),
                      ),
                    ),
              child: const Text('确认并创建'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _retryVelockAcknowledgement() async {
    final session = ref.read(velockWizardSessionProvider).session;
    if (session == null) return;
    setState(() => _checkingVelock = true);
    final acknowledged = await ref
        .read(velockProfileFinalizerProvider)
        .retryAcknowledgement(session);
    if (!mounted) return;
    setState(() => _checkingVelock = false);
    if (acknowledged) {
      ref.read(velockWizardSessionProvider.notifier).acknowledged();
    }
    _showMessage(context, acknowledged ? '配对清理已确认。' : '仍无法确认配对清理，请稍后重试。');
  }

  @override
  Widget build(BuildContext context) {
    final wizard = ref.watch(velockWizardSessionProvider);
    final existingVelockProfiles = ref.watch(velockExistingProfilesProvider);
    return AdaptiveScaffold(
      title: 'Velock managed data',
      body: ListView(
        padding: const EdgeInsets.only(
          top: AppSpacing.sm,
          bottom: AppSpacing.xl,
        ),
        children: _velockFlowChildren(
          wizard,
          existingVelockProfiles.asData?.value ?? const [],
        ),
      ),
    );
  }

  List<Widget> _velockFlowChildren(
    VelockWizardSessionState wizard,
    List<SyncProfileSummary> existingVelockProfiles,
  ) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '步骤 1 / 3 · Velock managed data',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            existingVelockProfiles.isEmpty
                ? '先确认配对状态，或检查独立 Velock App 并开始新的安全配对。'
                : '已存在 Velock 同步配置。同一台设备只允许一个配对；如需重新配对，请先删除现有配置。',
            style: TextStyle(color: context.appSecondaryLabel, height: 1.4),
          ),
        ],
      ),
    ),
    if (wizard.session != null && wizard.approval == null)
      AdaptiveListSection(
        header: '配对状态',
        children: [
          AdaptiveListTile(
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.pending_actions_outlined,
                cupertino: CupertinoIcons.hourglass,
              ),
              color: context.appPrimary,
            ),
            title: const Text('Velock 配对等待批准'),
            subtitle: const Text('从 Velock 返回后会自动检查；也可点此重新检测。'),
            trailing: _checkingVelock
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    adaptiveIcon(
                      context,
                      material: Icons.chevron_right_rounded,
                      cupertino: CupertinoIcons.chevron_right,
                    ),
                  ),
            onTap: _checkingVelock
                ? null
                : () => _inspectPendingVelockPairing(wizard.session!),
          ),
        ],
      ),
    if (wizard.approval != null)
      AdaptiveListSection(
        header: '配对已验证',
        children: [
          AdaptiveListTile(
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.verified_user_outlined,
                cupertino: CupertinoIcons.checkmark_seal,
              ),
              color: AppColors.success,
            ),
            title: Text(wizard.approval!.vaultDisplayName),
            subtitle: Text(
              '已验证 ${wizard.approval!.deviceDisplayName}；尚未创建 Profile。',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const Key('abandon-velock-pairing'),
                  onPressed: _checkingVelock
                      ? null
                      : () => ref
                            .read(velockWizardSessionProvider.notifier)
                            .reset(),
                  child: const Text('放弃'),
                ),
                Icon(
                  adaptiveIcon(
                    context,
                    material: Icons.chevron_right_rounded,
                    cupertino: CupertinoIcons.chevron_right,
                  ),
                ),
              ],
            ),
            onTap: _checkingVelock
                ? null
                : () =>
                      _continueVelockProfile(wizard.session!, wizard.approval!),
          ),
        ],
      ),
    if (wizard.approval != null && wizard.connectionNeeded)
      AdaptiveListSection(
        header: '下一步',
        footer: const Text('配对已保留。创建并验证远端连接后，回来点击上方已验证的配对继续。'),
        children: [
          AdaptiveListTile(
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.add_link_rounded,
                cupertino: CupertinoIcons.link,
              ),
              color: AppColors.warning,
            ),
            title: const Text('还需要一个远端连接'),
            subtitle: const Text('先准备一个可用的 WebDAV、Google Drive 或 OneDrive 连接。'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: isApplePlatform(context)
                ? CupertinoButton.filled(
                    key: const Key('go-create-connection'),
                    onPressed: () {
                      ref
                          .read(connectionCreationProvider.notifier)
                          .prepareNewConnection(
                            name: '新建连接',
                            source: '格间',
                            target: null,
                          );
                      context.push(AppRoutes.newWebDav.path);
                    },
                    child: const Text('去创建连接'),
                  )
                : FilledButton.icon(
                    key: const Key('go-create-connection'),
                    onPressed: () {
                      ref
                          .read(connectionCreationProvider.notifier)
                          .prepareNewConnection(
                            name: '新建连接',
                            source: '格间',
                            target: null,
                          );
                      context.push(AppRoutes.newWebDav.path);
                    },
                    icon: const Icon(Icons.add_link_rounded),
                    label: const Text('去创建连接'),
                  ),
          ),
        ],
      ),
    if (wizard.finalization case final result?)
      AdaptiveListSection(
        header: '创建结果',
        children: [
          AdaptiveListTile(
            key: const Key('velock-finalization-result'),
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: result.pairingAcknowledged
                    ? Icons.check_circle_outline
                    : Icons.sync_problem_outlined,
                cupertino: result.pairingAcknowledged
                    ? CupertinoIcons.check_mark_circled
                    : CupertinoIcons.exclamationmark_triangle,
              ),
              color: result.pairingAcknowledged
                  ? AppColors.success
                  : AppColors.warning,
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
        ],
      ),
    if (wizard.session == null &&
        wizard.approval == null &&
        existingVelockProfiles.isEmpty)
      AdaptiveListSection(
        header: '开始',
        children: [
          AdaptiveListTile(
            key: const Key('inspect-velock-readiness'),
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.shield_outlined,
                cupertino: CupertinoIcons.shield,
              ),
              color: context.appPrimary,
            ),
            title: const Text('开始 Velock 配对'),
            subtitle: const Text(
              '检查独立 Velock App、签名保护的 Exchange、授权与配对能力，然后发起配对。',
            ),
            trailing: _checkingVelock
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    adaptiveIcon(
                      context,
                      material: Icons.chevron_right_rounded,
                      cupertino: CupertinoIcons.chevron_right,
                    ),
                  ),
            enabled: !_checkingVelock,
            onTap: _checkingVelock ? null : _inspectVelock,
          ),
        ],
      ),
  ];
}

class _VelockProfileReview {
  const _VelockProfileReview({
    required this.displayName,
    required this.backgroundPolicy,
  });

  final String displayName;
  final SyncProfileBackgroundPolicy backgroundPolicy;
}

class SyncProfileDetail extends ConsumerStatefulWidget {
  const SyncProfileDetail({super.key, required this.profileId});

  final String profileId;

  @override
  ConsumerState<SyncProfileDetail> createState() => _SyncProfileDetailState();
}

class _SyncProfileDetailState extends ConsumerState<SyncProfileDetail> {
  late Future<_DetailData> _data;
  int _selectedTab = 0;

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
    VelockWizardAvailability? velockAvailability;
    if (profile?.kind == SyncDatasetKind.velockManaged) {
      final readiness = await ref
          .read(velockWizardReadinessServiceProvider)
          .inspect(syncAppInstanceId: profile!.deviceId)
          .timeout(
            const Duration(seconds: 1),
            onTimeout: () => const VelockWizardReadiness(
              VelockWizardAvailability.temporarilyUnavailable,
            ),
          );
      velockAvailability = readiness.availability;
      if (readiness.availability == VelockWizardAvailability.accessRevoked) {
        await ref
            .read(syncProfileRepositoryProvider)
            .setState(profile.profileId, SyncProfileState.accessRequired);
      }
    }
    return _DetailData(
      profile: profile,
      latestRun: values[0] as SyncRunRecord?,
      runs: values[1] as List<SyncRunRecord>,
      transfers: values[2] as List<TransferJobRecord>,
      conflicts: values[3] as List<SyncConflictRecord>,
      velockAvailability: velockAvailability,
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
        return const AdaptiveScaffold(
          title: '同步配置',
          body: AdaptiveLoadingState(label: '正在加载同步配置详情'),
        );
      }
      if (snapshot.hasError) {
        return AdaptiveScaffold(
          title: '同步配置',
          body: _RetryState(onRetry: _refresh, message: '无法读取同步配置详情。'),
        );
      }
      final data = snapshot.requireData;
      final profile = data.profile;
      if (profile == null) {
        return const AdaptiveScaffold(
          title: '同步配置',
          body: Center(child: Text('找不到该同步配置。')),
        );
      }
      final children = [
        _DetailMaterialSurface(
          child: _OverviewTab(
            profile: profile,
            latestRun: data.latestRun,
            velockAvailability: data.velockAvailability,
            onChanged: _refresh,
          ),
        ),
        _DetailMaterialSurface(child: _PendingTab(transfers: data.transfers)),
        _DetailMaterialSurface(child: _HistoryTab(runs: data.runs)),
        _DetailMaterialSurface(child: _ConflictsTab(conflicts: data.conflicts)),
        _DetailMaterialSurface(
          child: _ProfileSettingsTab(profile: profile, onChanged: _refresh),
        ),
      ];
      if (isApplePlatform(context)) {
        const labels = ['概览', '待处理', '历史', '冲突', '设置'];
        return AdaptiveScaffold(
          title: profile.displayName,
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.xs,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: CupertinoSlidingSegmentedControl<int>(
                    groupValue: _selectedTab,
                    children: {
                      for (var index = 0; index < labels.length; index++)
                        index: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xxs,
                          ),
                          child: Text(labels[index]),
                        ),
                    },
                    onValueChanged: (value) {
                      if (value != null) setState(() => _selectedTab = value);
                    },
                  ),
                ),
              ),
              Expanded(
                child: IndexedStack(index: _selectedTab, children: children),
              ),
            ],
          ),
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
                Tab(text: '概览'),
                Tab(text: '待处理'),
                Tab(text: '历史'),
                Tab(text: '冲突'),
                Tab(text: '设置'),
              ],
            ),
          ),
          body: TabBarView(children: children),
        ),
      );
    },
  );
}

class _DetailMaterialSurface extends StatelessWidget {
  const _DetailMaterialSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Material(type: MaterialType.transparency, child: child);
}

class _OverviewTab extends ConsumerStatefulWidget {
  const _OverviewTab({
    required this.profile,
    required this.latestRun,
    this.velockAvailability,
    required this.onChanged,
  });
  final SyncProfileEnvelope profile;
  final SyncRunRecord? latestRun;
  final VelockWizardAvailability? velockAvailability;
  final VoidCallback onChanged;

  @override
  ConsumerState<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends ConsumerState<_OverviewTab> {
  bool _running = false;

  Future<void> _runNow() async {
    setState(() => _running = true);
    try {
      final result = await ref
          .read(syncProfileRunServiceProvider)
          .runNow(widget.profile.profileId);
      if (!mounted) return;
      _showMessage(context, _syncResultMessage(result));
    } finally {
      if (mounted) setState(() => _running = false);
    }
    if (mounted) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isPaused = widget.profile.state == SyncProfileState.paused;
    final velockUnavailable =
        widget.profile.kind == SyncDatasetKind.velockManaged &&
        widget.velockAvailability != null &&
        widget.velockAvailability != VelockWizardAvailability.ready;
    final statusColor = velockUnavailable
        ? AppColors.danger
        : _profileStateColor(context, widget.profile.state);
    final statusLabel = velockUnavailable
        ? _velockAvailabilityLabel(widget.velockAvailability!)
        : _stateLabel(widget.profile.state);
    final canSync =
        widget.profile.state == SyncProfileState.active &&
        !_running &&
        !velockUnavailable;
    Future<void> toggleState() async {
      await ref
          .read(syncProfileRepositoryProvider)
          .setState(
            widget.profile.profileId,
            isPaused ? SyncProfileState.active : SyncProfileState.paused,
          );
      widget.onChanged();
    }

    return ListView(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xl),
      children: [
        if (velockUnavailable)
          _VelockConnectionBanner(
            availability: widget.velockAvailability!,
            onRetry: widget.onChanged,
          ),
        AdaptiveSummaryCard(
          icon: _adaptiveKindIcon(context, widget.profile.kind),
          color: statusColor,
          eyebrow: '同步配置',
          title: widget.profile.displayName,
          status: AdaptiveStatusBadge(label: statusLabel, color: statusColor),
          metrics: [
            AdaptiveSummaryMetric(
              value: _kindLabel(widget.profile.kind),
              label: '数据集',
            ),
            AdaptiveSummaryMetric(
              value: widget.latestRun == null
                  ? '—'
                  : _runStateLabel(widget.latestRun!.state),
              label: '最近同步',
            ),
            AdaptiveSummaryMetric(
              value: widget.profile.backgroundPolicy.enabled ? '开启' : '关闭',
              label: '后台同步',
            ),
          ],
        ),
        AdaptiveListSection(
          header: '配置操作',
          children: [
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: adaptiveIcon(
                  context,
                  material: Icons.sync_rounded,
                  cupertino: CupertinoIcons.arrow_2_circlepath,
                ),
                color: context.appPrimary,
              ),
              title: Text(_running ? '正在同步…' : '立即同步'),
              subtitle: const Text('立即检查远端并执行待处理同步。'),
              enabled: canSync,
              onTap: _runNow,
            ),
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: adaptiveIcon(
                  context,
                  material: isPaused
                      ? Icons.play_arrow_rounded
                      : Icons.pause_rounded,
                  cupertino: isPaused
                      ? CupertinoIcons.play
                      : CupertinoIcons.pause,
                ),
                color: context.appSecondaryLabel,
              ),
              title: Text(isPaused ? '恢复同步' : '暂停同步'),
              subtitle: Text(isPaused ? '恢复后允许该配置再次运行。' : '暂停后不会删除远端数据。'),
              enabled: !_running,
              onTap: toggleState,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.sm,
            AppSpacing.page,
            0,
          ),
          child: isApplePlatform(context)
              ? CupertinoButton.filled(
                  key: const Key('sync-now-button'),
                  onPressed: canSync ? _runNow : null,
                  child: Text(_running ? '正在同步…' : '立即同步'),
                )
              : FilledButton.icon(
                  key: const Key('sync-now-button'),
                  onPressed: canSync ? _runNow : null,
                  icon: _running
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded),
                  label: Text(_running ? '正在同步…' : '立即同步'),
                ),
        ),
      ],
    );
  }
}

String _syncResultMessage(SyncProfileDispatchResult result) {
  if (!result.didRun) {
    return '同步未启动：${_dispatchLabel(result.status)}';
  }
  if (result.run == null || !result.run!.didTransfer) {
    return '同步检查完成，没有待同步内容。';
  }
  return '同步任务已完成。';
}

class _PendingTab extends StatelessWidget {
  const _PendingTab({required this.transfers});
  final List<TransferJobRecord> transfers;

  @override
  Widget build(BuildContext context) => transfers.isEmpty
      ? const AdaptiveEmptyState(
          icon: CupertinoIcons.check_mark_circled,
          title: '没有待处理传输',
          message: '新的上传和下载任务会显示在这里。',
        )
      : ListView(
          padding: const EdgeInsets.only(
            top: AppSpacing.sm,
            bottom: AppSpacing.xl,
          ),
          children: [
            AdaptiveListSection(
              header: '待恢复传输',
              children: [
                for (final transfer in transfers)
                  AdaptiveListTile(
                    leading: AdaptiveIconBadge(
                      icon: transfer.direction == TransferJobDirection.upload
                          ? CupertinoIcons.arrow_up
                          : CupertinoIcons.arrow_down,
                      color: context.appPrimary,
                    ),
                    title: Text(
                      '${transfer.direction == TransferJobDirection.upload ? '上传' : '下载'} · ${transfer.state.name}',
                    ),
                    subtitle: Text(
                      '${transfer.completedBytes}${transfer.expectedSize == null ? '' : ' / ${transfer.expectedSize}'} B',
                    ),
                    additionalInfo: Text(transfer.state.name),
                  ),
              ],
            ),
          ],
        );
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.runs});
  final List<SyncRunRecord> runs;

  @override
  Widget build(BuildContext context) => runs.isEmpty
      ? const AdaptiveEmptyState(
          icon: CupertinoIcons.clock,
          title: '尚无同步历史',
          message: '完成第一次同步后，运行记录会显示在这里。',
        )
      : ListView(
          padding: const EdgeInsets.only(
            top: AppSpacing.sm,
            bottom: AppSpacing.xl,
          ),
          children: [
            AdaptiveListSection(
              header: '同步历史',
              children: [
                for (final run in runs)
                  Builder(
                    builder: (context) {
                      final color = run.state == 'failed'
                          ? Theme.of(context).colorScheme.error
                          : run.state == 'running'
                          ? context.appPrimary
                          : AppColors.success;
                      return AdaptiveListTile(
                        widgetKey: Key('history-run-${run.runId}'),
                        leading: AdaptiveIconBadge(
                          icon: run.state == 'failed'
                              ? CupertinoIcons.exclamationmark_circle
                              : run.state == 'running'
                              ? CupertinoIcons.arrow_2_circlepath
                              : CupertinoIcons.check_mark,
                          color: color,
                        ),
                        title: Text(_runStateLabel(run.state)),
                        subtitle: Text(
                          '${_formatTime(run.startedAt)}${run.errorCode == null ? '' : ' · ${run.errorCode}'}',
                        ),
                        showChevron: true,
                        onTap: () => _showRunDetails(context, run),
                      );
                    },
                  ),
              ],
            ),
          ],
        );
}

Future<void> _showRunDetails(BuildContext context, SyncRunRecord run) =>
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('run-details-dialog'),
        title: Text('同步记录 · ${_runStateLabel(run.state)}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DetailRow(label: '开始时间', value: _formatTime(run.startedAt)),
              _DetailRow(
                label: '结束时间',
                value: run.completedAt == null
                    ? '—'
                    : _formatTime(run.completedAt!),
              ),
              if (run.errorCode != null)
                _DetailRow(label: '错误代码', value: run.errorCode!),
              if (run.errorCategory != null)
                _DetailRow(label: '错误分类', value: run.errorCategory!),
              if (run.providerStatusCode != null)
                _DetailRow(label: '服务状态码', value: '${run.providerStatusCode}'),
              if (run.retryable != null)
                _DetailRow(label: '可重试', value: run.retryable! ? '是' : '否'),
              if (run.retryAfter != null)
                _DetailRow(
                  label: '建议等待',
                  value: '${run.retryAfter!.inSeconds} 秒',
                ),
              if (run.suggestedAction != null)
                _DetailRow(label: '建议操作', value: run.suggestedAction!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

class _ConflictsTab extends StatelessWidget {
  const _ConflictsTab({required this.conflicts});
  final List<SyncConflictRecord> conflicts;

  @override
  Widget build(BuildContext context) => conflicts.isEmpty
      ? const AdaptiveEmptyState(
          icon: CupertinoIcons.check_mark_circled,
          title: '没有待处理冲突',
          message: '出现冲突时，你可以从活动页选择处理方式。',
        )
      : ListView(
          padding: const EdgeInsets.only(
            top: AppSpacing.sm,
            bottom: AppSpacing.xl,
          ),
          children: [
            AdaptiveListSection(
              header: '待处理冲突',
              children: [
                for (final conflict in conflicts)
                  AdaptiveListTile(
                    leading: AdaptiveIconBadge(
                      icon: CupertinoIcons.exclamationmark_triangle,
                      color: AppColors.warning,
                    ),
                    title: Text(_conflictLabel(conflict.type)),
                    subtitle: Text(
                      '对象 ${_shortId(conflict.entityId)} · ${_formatTime(conflict.createdAt)}',
                    ),
                    trailing: isApplePlatform(context)
                        ? CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: () => context.go('/activity'),
                            child: const Text('处理'),
                          )
                        : TextButton(
                            onPressed: () => context.go('/activity'),
                            child: const Text('处理'),
                          ),
                  ),
              ],
            ),
          ],
        );
}

class _ProfileSettingsTab extends ConsumerWidget {
  const _ProfileSettingsTab({required this.profile, required this.onChanged});
  final SyncProfileEnvelope profile;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xl),
    children: [
      AdaptiveListSection(
        header: '后台策略',
        children: [
          AdaptiveSwitchListTile(
            title: const Text('后台同步'),
            subtitle: const Text('仅在系统允许且配置处于活动状态时运行。'),
            value: profile.backgroundPolicy.enabled,
            onChanged: (value) =>
                _save(ref, profile.backgroundPolicy.copyWith(enabled: value)),
          ),
          AdaptiveSwitchListTile(
            title: const Text('允许蜂窝网络'),
            value: profile.backgroundPolicy.allowCellular,
            onChanged: profile.backgroundPolicy.enabled
                ? (value) => _save(
                    ref,
                    profile.backgroundPolicy.copyWith(allowCellular: value),
                  )
                : null,
          ),
          AdaptiveSwitchListTile(
            title: const Text('仅充电时运行'),
            value: profile.backgroundPolicy.requiresCharging,
            onChanged: profile.backgroundPolicy.enabled
                ? (value) => _save(
                    ref,
                    profile.backgroundPolicy.copyWith(requiresCharging: value),
                  )
                : null,
          ),
        ],
      ),
      AdaptiveListSection(
        header: '危险操作',
        children: [
          AdaptiveListTile(
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.delete_outline_rounded,
                cupertino: CupertinoIcons.delete,
              ),
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              '移除同步配置',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: const Text('不会删除远端数据或安全存储中的凭据。'),
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
                var forceRunning = false;
                if (profile.kind == SyncDatasetKind.velockManaged) {
                  final readiness = await ref
                      .read(velockWizardReadinessServiceProvider)
                      .inspect()
                      .timeout(
                        const Duration(seconds: 1),
                        onTimeout: () => const VelockWizardReadiness(
                          VelockWizardAvailability.temporarilyUnavailable,
                        ),
                      );
                  forceRunning =
                      readiness.availability != VelockWizardAvailability.ready;
                }
                await ref
                    .read(syncProfileRepositoryProvider)
                    .remove(profile.profileId, forceRunning: forceRunning);
                if (context.mounted) context.go('/dashboard');
              } on SyncProfileRemovalWhileRunningException {
                if (context.mounted) _showMessage(context, '同步正在运行，暂时无法移除。');
              }
            },
          ),
        ],
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
      if (isApplePlatform(context)) {
        await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('脱敏诊断'),
            content: SizedBox(
              height: 320,
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
              CupertinoDialogAction(
                key: const Key('copy-sanitized-diagnostics'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: diagnostics));
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                },
                child: const Text('复制'),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('完成'),
              ),
            ],
          ),
        );
      } else {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
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
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                },
                child: const Text('复制'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('完成'),
              ),
            ],
          ),
        );
      }
    } on Object {
      if (mounted) _showMessage(context, '无法生成脱敏诊断。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseCellularLimit(SyncGlobalSettings settings) async {
    if (!isApplePlatform(context)) return;
    final selected = await showCupertinoModalPopup<int>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('默认蜂窝网络传输上限'),
        message: const Text('加密内容按单个传输对象限制。'),
        actions: [
          for (final bytes in const [
            10 * 1024 * 1024,
            50 * 1024 * 1024,
            100 * 1024 * 1024,
          ])
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop(bytes),
              child: Text(_formatBytes(bytes)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected != null && mounted) {
      await _save(settings.copyWith(defaultCellularMaxTransferBytes: selected));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<SyncSettingsSnapshot>(
    future: _snapshot,
    builder: (context, snapshot) => AdaptiveSliverScaffold(
      title: '设置',
      showTitle: false,
      slivers: _settingsSlivers(context, snapshot),
    ),
  );

  List<Widget> _settingsSlivers(
    BuildContext context,
    AsyncSnapshot<SyncSettingsSnapshot> snapshot,
  ) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveLoadingState(label: '正在加载同步设置'),
        ),
      ];
    }
    if (snapshot.hasError) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveErrorState(message: '无法读取同步设置。', onRetry: _reload),
        ),
      ];
    }
    final value = snapshot.requireData;
    final settings = value.settings;
    final statusColor = value.backgroundSupported
        ? AppColors.success
        : context.appSecondaryLabel;
    final currentLimit = _supportedCellularLimit(
      settings.defaultCellularMaxTransferBytes,
    );
    return [
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '后台同步',
          footer: const Text('系统会根据网络、电量和各配置策略安排后台任务。'),
          children: [
            AdaptiveSwitchListTile(
              widgetKey: const Key('global-background-enabled'),
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
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: adaptiveIcon(
                  context,
                  material: value.backgroundSupported
                      ? Icons.check_rounded
                      : Icons.info_outline_rounded,
                  cupertino: value.backgroundSupported
                      ? CupertinoIcons.check_mark
                      : CupertinoIcons.info,
                ),
                color: statusColor,
              ),
              title: const Text('系统后台状态'),
              additionalInfo: Text(value.backgroundSupported ? '可用' : '不可用'),
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '新配置默认策略',
          footer: const Text('这些选项只影响此后创建的配置；已有配置保持自己的策略。'),
          children: [
            AdaptiveSwitchListTile(
              widgetKey: const Key('default-allow-cellular'),
              title: const Text('默认允许蜂窝网络'),
              subtitle: const Text('离开 Wi-Fi 后仍可继续同步。'),
              value: settings.defaultAllowCellular,
              onChanged: _busy
                  ? null
                  : (enabled) =>
                        _save(settings.copyWith(defaultAllowCellular: enabled)),
            ),
            AdaptiveSwitchListTile(
              widgetKey: const Key('default-requires-charging'),
              title: const Text('默认仅充电时运行'),
              value: settings.defaultRequiresCharging,
              onChanged: _busy
                  ? null
                  : (enabled) => _save(
                      settings.copyWith(defaultRequiresCharging: enabled),
                    ),
            ),
            AdaptiveListTile(
              widgetKey: isApplePlatform(context)
                  ? const Key('default-cellular-limit')
                  : null,
              title: const Text('默认蜂窝网络传输上限'),
              subtitle: const Text('加密内容按单个传输对象限制。'),
              additionalInfo: isApplePlatform(context)
                  ? Text(_formatBytes(currentLimit))
                  : null,
              showChevron: isApplePlatform(context),
              onTap: _busy || !isApplePlatform(context)
                  ? null
                  : () => _chooseCellularLimit(settings),
              trailing: isApplePlatform(context)
                  ? null
                  : DropdownButton<int>(
                      key: const Key('default-cellular-limit'),
                      value: currentLimit,
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
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '暂存空间',
          children: [
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: adaptiveIcon(
                  context,
                  material: Icons.storage_outlined,
                  cupertino: CupertinoIcons.archivebox,
                ),
              ),
              title: Text(_formatBytes(value.staging.totalBytes)),
              subtitle: Text(
                '${value.staging.batchCount} 个批次 · ${value.staging.fileCount} 个文件。'
                '清理会保留可恢复批次，并跳过正在同步的配置。',
              ),
              onTap: _busy ? null : _cleanupStaging,
              trailing: isApplePlatform(context)
                  ? CupertinoButton(
                      key: const Key('cleanup-staging'),
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(44, 44),
                      onPressed: _busy ? null : _cleanupStaging,
                      child: const Text('清理'),
                    )
                  : OutlinedButton.icon(
                      key: const Key('cleanup-staging'),
                      onPressed: _busy ? null : _cleanupStaging,
                      icon: const Icon(Icons.cleaning_services_outlined),
                      label: const Text('安全清理'),
                    ),
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '隐私与诊断',
          children: [
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: adaptiveIcon(
                  context,
                  material: Icons.privacy_tip_outlined,
                  cupertino: CupertinoIcons.lock_shield,
                ),
                color: AppColors.success,
              ),
              title: const Text('隐私保护'),
              subtitle: const Text(
                '日志和诊断不包含凭据、密钥、原始路径、Profile 标识、'
                'Velock 业务内容或受保护冲突详情。',
              ),
            ),
            AdaptiveListTile(
              widgetKey: const Key('export-sanitized-diagnostics'),
              leading: AdaptiveIconBadge(
                icon: adaptiveIcon(
                  context,
                  material: Icons.description_outlined,
                  cupertino: CupertinoIcons.doc_text,
                ),
              ),
              title: const Text('导出脱敏诊断'),
              subtitle: const Text('仅导出版本、系统能力、聚合计数、稳定错误码和暂存用量。'),
              showChevron: true,
              onTap: _busy ? null : _showDiagnostics,
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '版本与许可',
          children: [
            const AdaptiveListTile(
              title: Text('协议版本'),
              subtitle: Text(syncProtocolDisplayVersion),
            ),
            const AdaptiveListTile(
              title: Text('应用版本'),
              subtitle: Text(syncAppDisplayVersion),
            ),
            AdaptiveListTile(
              title: const Text('关于与开源许可'),
              showChevron: true,
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Velock Sync',
                applicationVersion: syncAppDisplayVersion,
              ),
            ),
          ],
        ),
      ),
    ];
  }
}

class _DetailData {
  const _DetailData({
    required this.profile,
    required this.latestRun,
    required this.runs,
    required this.transfers,
    required this.conflicts,
    this.velockAvailability,
  });
  final SyncProfileEnvelope? profile;
  final SyncRunRecord? latestRun;
  final List<SyncRunRecord> runs;
  final List<TransferJobRecord> transfers;
  final List<SyncConflictRecord> conflicts;
  final VelockWizardAvailability? velockAvailability;
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
  SyncDatasetKind.velockManaged => 'Velock 安全空间',
  null => '不可用',
};

IconData _adaptiveKindIcon(BuildContext context, SyncDatasetKind? kind) =>
    switch (kind) {
      SyncDatasetKind.velockManaged => adaptiveIcon(
        context,
        material: Icons.shield_outlined,
        cupertino: CupertinoIcons.shield,
      ),
      null => adaptiveIcon(
        context,
        material: Icons.error_outline,
        cupertino: CupertinoIcons.exclamationmark_triangle,
      ),
    };

Color _profileStateColor(BuildContext context, SyncProfileState state) =>
    switch (state) {
      SyncProfileState.active => AppColors.success,
      SyncProfileState.paused => context.appSecondaryLabel,
      SyncProfileState.accessRequired ||
      SyncProfileState.reauthorizationRequired ||
      SyncProfileState.blockedByConfiguration => AppColors.warning,
      SyncProfileState.error => Theme.of(context).colorScheme.error,
    };

String _stateLabel(SyncProfileState state) => switch (state) {
  SyncProfileState.active => '已启用',
  SyncProfileState.paused => '已暂停',
  SyncProfileState.accessRequired => '需要授权',
  SyncProfileState.reauthorizationRequired => '需要重新授权',
  SyncProfileState.blockedByConfiguration => '配置不完整',
  SyncProfileState.error => '需要处理',
};

String _velockAvailabilityLabel(VelockWizardAvailability availability) =>
    switch (availability) {
      VelockWizardAvailability.appNotInstalled => '本体未安装',
      VelockWizardAvailability.authorizationRequired => '本体未授权',
      VelockWizardAvailability.accessRevoked => '授权已撤销',
      VelockWizardAvailability.unsupportedVersion => '版本不支持',
      VelockWizardAvailability.signatureMismatch => '身份验证失败',
      VelockWizardAvailability.configurationMissing => '本体不可用',
      VelockWizardAvailability.temporarilyUnavailable => '本体暂不可用',
      VelockWizardAvailability.unsupportedPlatform => '平台不支持',
      VelockWizardAvailability.ready => '已启用',
    };

String _velockAvailabilitySubtitle(VelockWizardAvailability availability) =>
    switch (availability) {
      VelockWizardAvailability.appNotInstalled => '请先安装 Velock 本体。',
      VelockWizardAvailability.authorizationRequired => '请在 Velock 本体中重新授权。',
      VelockWizardAvailability.accessRevoked => 'Velock 已撤销本次授权，请重新配对后继续同步。',
      VelockWizardAvailability.unsupportedVersion => '请升级 Velock 本体后重试。',
      VelockWizardAvailability.signatureMismatch => '已安装的 Velock 本体无法验证。',
      VelockWizardAvailability.configurationMissing => 'Velock 本体的同步通道不可用。',
      VelockWizardAvailability.temporarilyUnavailable => 'Velock 本体暂时无法访问。',
      VelockWizardAvailability.unsupportedPlatform => '当前平台不支持 Velock 本体。',
      VelockWizardAvailability.ready => 'Velock 安全空间',
    };

String _runStateLabel(String state) => switch (state) {
  'running' => '运行中',
  'completed' => '已完成',
  'failed' => '失败',
  _ => state,
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

String _profileSecondaryText(SyncProfileSummary summary) {
  final details = <String>[_kindLabel(summary.kind)];
  if (summary.backgroundPolicy.enabled) {
    details.add('后台同步已开启');
  }
  final activity = _activityText(summary.activity);
  if (activity.isNotEmpty) {
    details.add(activity.substring(3));
  }
  return details.join(' · ');
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
      VelockWizardAvailability.accessRevoked => 'Velock 已撤销授权',
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
      VelockWizardAvailability.accessRevoked =>
        'Velock 已撤销此设备的同步授权。请在 Velock 中重新批准配对后继续。',
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

void _showMessage(BuildContext context, String message) =>
    showPlatformMessage(context, message);
