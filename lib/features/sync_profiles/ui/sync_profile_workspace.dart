import 'dart:async';

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_service.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_pairing_control_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/android_exchange_channel.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_queue_probe.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/device_signing_key_store.dart';
import 'package:velock_sync/infrastructure/secure_storage/vault_key_store.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_core/crypto/vault_recovery_package.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher_factory.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/diagnostics/remote_inventory_service.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_profile_finalizer.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'package:velock_sync/widgets/app_format.dart';

/// UI-level seam so widget tests can verify the Velock action without
/// executing platform IPC, providers, or a remote transfer.
abstract interface class SyncProfileRunService {
  Future<SyncProfileDispatchResult> runNow(String profileId);
}

/// Reads the Velock app's local sync queue (Apple App Group only).
final velockExchangeQueueProbeProvider = Provider<VelockExchangeQueueProbe>(
  (ref) => const VelockExchangeQueueProbe(),
);

/// Read-only remote inventory used by the detail page.
final remoteInventoryServiceProvider = Provider<RemoteInventoryService>(
  (ref) => RemoteInventoryService(
    connections: ref.watch(connectionRepositoryProvider),
  ),
);

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
    final selectedFolderProfiles = SelectedFolderSyncProfileRepository(
      _database,
    );
    final selectedFolderService = SelectedFolderSyncService(
      database: _database,
      profiles: selectedFolderProfiles,
      connections: connections,
      vaultKeys: SecureVaultKeyStore(),
      signingKeys: SecureDeviceSigningKeyStore(),
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
    void createProfile() => context.push(AppRoutes.syncProfilesNew.path);
    return FutureBuilder<_SyncProfilesLoadResult>(
      future: _profiles,
      builder: (context, snapshot) => AdaptiveSliverScaffold(
        title: '备份与同步',
        actions: [
          if (isApplePlatform(context))
            Semantics(
              button: true,
              label: '新建同步',
              child: AdaptiveIconButton(
                key: const Key('sync-profile-create'),
                tooltip: '新建同步',
                onPressed: createProfile,
                icon: const Icon(CupertinoIcons.add),
              ),
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
                tooltip: '新建同步',
                onPressed: createProfile,
                icon: const Icon(Icons.add_rounded),
                label: const Text('新建同步'),
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
          child: AdaptiveLoadingState(label: '正在加载备份与同步配置'),
        ),
      ];
    }
    if (snapshot.hasError) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveErrorState(message: '无法读取备份与同步配置。', onRetry: _refresh),
        ),
      ];
    }

    final loaded = snapshot.requireData;
    final profiles = loaded.profiles;
    final velockProfiles = profiles
        .where((profile) => profile.kind == SyncDatasetKind.velockManaged)
        .toList(growable: false);
    final folderProfiles = profiles
        .where((profile) => profile.kind == SyncDatasetKind.selectedFolder)
        .toList(growable: false);
    final unavailableProfiles = profiles
        .where((profile) => profile.kind == null)
        .toList(growable: false);
    final velockIssue =
        loaded.velockAvailability != null &&
        loaded.velockAvailability != VelockWizardAvailability.ready &&
        velockProfiles.isNotEmpty;
    final velockStatus = _velockDomainStatus(
      profiles: velockProfiles,
      velockAvailability: loaded.velockAvailability,
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
        child: AdaptiveListSection(
          header: '格间',
          // The disconnection banner right above already carries the next step,
          // so the header only states the condition it summarises.
          headerDetail: velockIssue || velockStatus.detail == null
              ? null
              : _SectionStatusDetail(
                  message: velockStatus.detail!,
                  tone: velockStatus.tone,
                ),
          // The intro belongs to the moment before anything exists; once a
          // profile is listed it only repeats itself.
          footer: velockProfiles.isEmpty
              ? const Text('零知识备份：只搬运格间已加密的数据，恢复由格间本体处理。')
              : null,
          emptyContent: Align(
            alignment: Alignment.centerLeft,
            child: AppTextButton(
              key: const Key('velock-backup-enable'),
              icon: adaptiveIcon(
                context,
                material: Icons.add_rounded,
                cupertino: CupertinoIcons.add,
              ),
              label: '开启格间备份',
              onPressed: () =>
                  context.pushNamed(AppRoutes.velockDatasetWizard.name),
            ),
          ),
          children: [
            for (final profile in velockProfiles)
              _ProfileTile(
                summary: profile,
                onChanged: _refresh,
                velockAvailability: loaded.velockAvailability,
              ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '其他文件',
          emptyContent: Align(
            alignment: Alignment.centerLeft,
            child: AppTextButton(
              key: const Key('selected-folder-create'),
              icon: adaptiveIcon(
                context,
                material: Icons.add_rounded,
                cupertino: CupertinoIcons.add,
              ),
              label: '新建文件夹同步',
              onPressed: () =>
                  context.pushNamed(AppRoutes.selectedFolderProfiles.name),
            ),
          ),
          children: [
            for (final profile in folderProfiles)
              _ProfileTile(summary: profile, onChanged: _refresh),
          ],
        ),
      ),
      if (unavailableProfiles.isNotEmpty)
        SliverToBoxAdapter(
          child: AdaptiveListSection(
            header: '无法读取的配置',
            children: [
              for (final profile in unavailableProfiles)
                _ProfileTile(summary: profile, onChanged: _refresh),
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

/// State of the「格间」domain as shown by the section header.
///
/// A status is neither an instance the user can open nor an entry that starts
/// a new sync, so it never renders as a grouped list row: the header keeps one
/// line of context, and only speaks up when something needs attention.
class _DomainStatus {
  const _DomainStatus({required this.tone, this.detail});

  final AppTone tone;

  /// One sentence of context, or null when the section holds nothing but an
  /// entry to start the domain.
  final String? detail;
}

_DomainStatus _velockDomainStatus({
  required List<SyncProfileSummary> profiles,
  required VelockWizardAvailability? velockAvailability,
}) {
  if (profiles.isEmpty) {
    // The empty slot below already reads as "not set up yet", so the header
    // adds nothing here.
    return const _DomainStatus(tone: AppTone.neutral);
  }

  final velockUnavailable =
      velockAvailability != null &&
      velockAvailability != VelockWizardAvailability.ready;
  if (velockUnavailable) {
    return const _DomainStatus(
      tone: AppTone.danger,
      detail: '请打开格间完成授权；恢复连接后备份会自动继续。',
    );
  }

  final attention = profiles.where(_velockProfileNeedsAttention).length;
  if (attention > 0) {
    return const _DomainStatus(
      tone: AppTone.attention,
      detail: '格间已重置或授权已失效。请移除下方配置，再用「＋ → 备份格间数据」重新配对。',
    );
  }

  // Nothing to report when the domain is healthy: the run itself carries its
  // timestamp, so the header stays text-free.
  return const _DomainStatus(tone: AppTone.ok);
}

bool _velockProfileNeedsAttention(SyncProfileSummary profile) =>
    profile.isIsolated ||
    profile.activity?.latestRun?.state == 'failed' ||
    profile.state == SyncProfileState.accessRequired ||
    profile.state == SyncProfileState.reauthorizationRequired ||
    profile.state == SyncProfileState.blockedByConfiguration ||
    profile.state == SyncProfileState.error;

/// One line of section-level context under a section header.
class _SectionStatusDetail extends StatelessWidget {
  const _SectionStatusDetail({required this.message, required this.tone});

  final String message;
  final AppTone tone;

  @override
  Widget build(BuildContext context) {
    final needsAction = tone == AppTone.attention || tone == AppTone.danger;
    return Text(
      message,
      style: AppType.rowSubtitle.copyWith(
        color: needsAction ? tone.color(context) : context.appSecondaryLabel,
      ),
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
    final presentation = _profileStatusPresentation(
      context,
      kind: summary.kind,
      state: summary.state,
      isIsolated: summary.isIsolated,
      lastRunFailed: summary.activity?.latestRun?.state == 'failed',
      velockAvailability: velockAvailability,
    );
    // When the pairing binding is gone the row already states the cause and
    // the next step, so the generic "sync unfinished" line is redundant.
    final failureSubtitle = summary.state == SyncProfileState.accessRequired
        ? null
        : summary.activity?.latestRun?.state == 'failed'
        ? _latestRunFailureSubtitle(summary.activity?.latestRun)
        : null;
    final baseSubtitle = summary.state == SyncProfileState.accessRequired
        ? '格间已重置或授权已失效，请移除本配置后重新配对。'
        : presentation.detail ?? _profileSecondaryText(summary);
    final subtitleText = failureSubtitle == null
        ? baseSubtitle
        : '$baseSubtitle，$failureSubtitle';

    return Semantics(
      label: '$title，$subtitleText，${presentation.label}',
      child: AdaptiveListTile(
        leading: AdaptiveIconBadge(
          icon: _adaptiveKindIcon(context, summary.kind),
          color: presentation.tone.color(context),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.rowTitleStrong,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    baseSubtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.rowSubtitle.copyWith(
                      color: context.appSecondaryLabel,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                AdaptiveStatusBadge(
                  label: presentation.label,
                  tone: presentation.tone,
                  icon: presentation.icon,
                ),
              ],
            ),
            if (failureSubtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                failureSubtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.rowSubtitle.copyWith(
                  color: presentation.tone.color(context),
                ),
              ),
            ],
          ],
        ),
        isThreeLine:
            failureSubtitle != null ||
            summary.state == SyncProfileState.accessRequired,
        enabled: !summary.isIsolated,
        onTap: () => context.push('/sync-profiles/${summary.profileId}'),
        trailing: AdaptiveActionMenu<_ProfileAction>(
          tooltip: '同步配置操作',
          onSelected: (action) => _runAction(context, ref, action),
          items: [
            if (summary.isRunnable && !summary.isIsolated)
              const AdaptiveActionItem(
                value: _ProfileAction.syncNow,
                label: '立即同步',
                icon: CupertinoIcons.arrow_2_circlepath,
              ),
            if (summary.state == SyncProfileState.active)
              const AdaptiveActionItem(
                value: _ProfileAction.pause,
                label: '暂停',
                icon: CupertinoIcons.pause,
              ),
            if (summary.state == SyncProfileState.paused)
              const AdaptiveActionItem(
                value: _ProfileAction.resume,
                label: '恢复',
                icon: CupertinoIcons.play,
              ),
            const AdaptiveActionItem(
              value: _ProfileAction.remove,
              label: '删除同步配置',
              icon: CupertinoIcons.delete,
              isDestructive: true,
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
          await _presentSyncResult(context, result);
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

/// Label, tone and optional detail for a profile's status pill.
///
/// Label and colour always come from the same source, so a healthy profile can
/// no longer show "已启用" tinted with the warning palette.
class _ProfileStatusPresentation {
  const _ProfileStatusPresentation({
    required this.label,
    required this.tone,
    this.icon,
    this.detail,
  });

  final String label;
  final AppTone tone;
  final IconData? icon;
  final String? detail;
}

_ProfileStatusPresentation _profileStatusPresentation(
  BuildContext context, {
  required SyncDatasetKind? kind,
  required SyncProfileState state,
  required bool isIsolated,
  required bool lastRunFailed,
  VelockWizardAvailability? velockAvailability,
}) {
  final velockUnavailable =
      kind == SyncDatasetKind.velockManaged &&
      velockAvailability != null &&
      velockAvailability != VelockWizardAvailability.ready;
  if (isIsolated) {
    return const _ProfileStatusPresentation(
      label: '需要处理',
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
      detail: '此配置无法安全读取，请重新创建同步配置。',
    );
  }
  if (velockUnavailable) {
    return _ProfileStatusPresentation(
      label: _velockAvailabilityLabel(velockAvailability),
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
      detail: _velockAvailabilitySubtitle(velockAvailability),
    );
  }
  if (lastRunFailed) {
    return const _ProfileStatusPresentation(
      label: '上次失败',
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
    );
  }
  return switch (state) {
    SyncProfileState.active => _ProfileStatusPresentation(
      label: kind == SyncDatasetKind.velockManaged ? '已保护' : '已同步',
      tone: AppTone.ok,
      icon: CupertinoIcons.check_mark_circled,
    ),
    SyncProfileState.paused => const _ProfileStatusPresentation(
      label: '已暂停',
      tone: AppTone.neutral,
      icon: CupertinoIcons.pause_circle,
    ),
    SyncProfileState.accessRequired => const _ProfileStatusPresentation(
      label: '需要授权',
      tone: AppTone.attention,
      icon: CupertinoIcons.exclamationmark_triangle,
    ),
    SyncProfileState.reauthorizationRequired =>
      const _ProfileStatusPresentation(
        label: '凭据失效',
        tone: AppTone.attention,
        icon: CupertinoIcons.exclamationmark_triangle,
      ),
    SyncProfileState.blockedByConfiguration => const _ProfileStatusPresentation(
      label: '配置不完整',
      tone: AppTone.attention,
      icon: CupertinoIcons.exclamationmark_triangle,
    ),
    SyncProfileState.error => const _ProfileStatusPresentation(
      label: '需要处理',
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
    ),
  };
}

enum _ProfileAction { syncNow, pause, resume, remove }

String _latestRunFailureMessage(SyncRunRecord? run) {
  if (run?.errorCode == 'provider.http.401') {
    return '上次同步失败：WebDAV 认证失败，请重新输入用户名和密码；地址和目录会保留。';
  }
  if (run?.errorCode == 'provider.http.403') {
    return '上次同步失败：当前账号没有远端同步目录的访问权限。';
  }
  if (run?.errorCode == 'provider.http.404') {
    return '上次同步失败：远端同步目录不存在，请检查 WebDAV 路径。';
  }
  if (run?.errorCode == 'provider.http.409') {
    return '上次同步失败：远端同步目录存在冲突，请确认没有其他设备同时同步。';
  }
  return '上次同步失败：${AppFormat.errorSummary(run?.errorCode)}';
}

String _latestRunFailureSubtitle(SyncRunRecord? run) {
  final message = _latestRunFailureMessage(run);
  return message.startsWith('上次同步失败：')
      ? message.substring('上次同步失败：'.length)
      : message;
}

String _firstSyncResultMessage(SyncProfileDispatchResult? result) {
  if (result == null) return '同步配置已创建；首次同步未执行，请稍后点击立即同步。';
  if (result.didRun) {
    final upload = result.run?.upload.publishedBatchCount ?? 0;
    final download = result.run?.download.importedBatchCount ?? 0;
    final pending = result.run?.download.pendingBatchCount ?? 0;
    if (pending > 0) {
      return '已下载 $pending 批格间数据，请打开格间并解锁以完成恢复。';
    }
    if (upload == 0 && download == 0) {
      return '同步配置已创建；当前没有新的数据需要同步。';
    }
    return '格间同步完成：上传 $upload 批，恢复 $download 批。';
  }
  return '同步配置已创建，但首次同步失败；请检查远端连接后点击“立即同步”。';
}

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
      title: '格间备份',
      body: ListView(
        children: [
          const SizedBox(height: AppSpacing.xs),
          AdaptiveListSection(
            header: '格间远程备份',
            footer: const Text(
              '格间是数据源，Velock Sync 只负责持续把已加密和认证的数据备份到你的远端。换机、重装或设备丢失后，恢复格间账号并连接同一远端即可恢复。',
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
                  title: const Text('格间数据'),
                  subtitle: Text(
                    '已连接 ${pairedVelock.displayName ?? '格间'}。如需重新配对，请先删除当前同步配置。',
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
                  title: const Text('格间数据'),
                  subtitle: const Text('持续备份格间中的密码、卡片、笔记、文档、文件和媒体。'),
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

enum _VelockReadinessAction { retry, pair, done }

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
        .where((connection) => connection.status == ConnectionStatus.active)
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
    final choice = await showAdaptiveAlert<_VelockReadinessAction>(
      context: context,
      title: _velockReadinessTitle(readiness.availability),
      message: _velockReadinessMessage(readiness.availability),
      actions: [
        if (readiness.canRetry)
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: '重试',
            value: _VelockReadinessAction.retry,
            key: const Key('retry-velock-readiness'),
          ),
        if (readiness.canCreate)
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: '开始配对',
            value: _VelockReadinessAction.pair,
            key: const Key('begin-velock-pairing'),
            isDefault: true,
            emphasized: true,
          )
        else
          AdaptiveAlertAction<_VelockReadinessAction>(
            label: '完成',
            value: _VelockReadinessAction.done,
            isDefault: true,
            emphasized: true,
          ),
      ],
    );
    switch (choice) {
      case _VelockReadinessAction.retry:
        await _inspectVelock();
      case _VelockReadinessAction.pair:
        await _beginVelockPairing(readiness.descriptor!);
      case _VelockReadinessAction.done:
      case null:
        break;
    }
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
    final action = await showAdaptiveAlert<_PairingRecoveryAction>(
      context: context,
      title: '尚未收到 Velock 批准',
      message: '如果你刚开启“允许新的配对”，请重新打开 Velock 并刷新待审批请求。仍看不到时，取消后重新发起。',
      icon: Icon(
        adaptiveIcon(
          context,
          material: Icons.sync_problem_outlined,
          cupertino: CupertinoIcons.exclamationmark_circle,
        ),
        color: context.appSecondaryLabel,
      ),
      actions: [
        AdaptiveAlertAction<_PairingRecoveryAction>(
          label: '取消配对',
          value: _PairingRecoveryAction.cancel,
          key: const Key('cancel-velock-pairing'),
        ),
        AdaptiveAlertAction<_PairingRecoveryAction>(
          label: '重新打开 Velock',
          value: _PairingRecoveryAction.reopen,
          key: const Key('reopen-velock-pairing'),
          isDefault: true,
          emphasized: true,
        ),
      ],
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
    final retry = await showAdaptiveConfirmation(
      context,
      title: title,
      message: message,
      confirmLabel: '重新发起',
      cancelLabel: '关闭',
    );
    if (retry == true && mounted) await _inspectVelock();
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
        ref.read(velockWizardSessionProvider.notifier).connectionMissing();
        _showMessage(context, '还没有可用的云端连接。先添加并验证 WebDAV 连接，返回后会继续完成格间同步。');
        return;
      }
      // A connection is available: the approved pairing can proceed, so the
      // "还需要一个远端连接" banner must not keep the flow stuck.
      ref.read(velockWizardSessionProvider.notifier).connectionResolved();

      final connection = connections.length == 1
          ? connections.single
          : await _chooseVelockConnection(connections);
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
      if (!result.pairingAcknowledged) {
        _showMessage(context, '同步配置已保存，但配对清理尚未确认；可在本页重试。');
        return;
      }

      // Creating the profile is not the user's goal. The user's goal is that
      // the first backup/recovery actually runs. Start it before leaving this
      // flow, so a successful setup always has a visible transfer result.
      final firstRun = await _runSyncWithProgress(
        context,
        ref,
        result.profile.profileId,
      );
      if (!mounted) return;
      ref.read(velockWizardSessionProvider.notifier).reset();
      if (context.mounted) {
        await _presentFirstSyncResult(context, firstRun);
      }
      if (!mounted) return;
      context.goNamed(AppRoutes.dashboard.name);
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
  ) => showAdaptiveActionSheet<ConnectionModel>(
    context: context,
    title: '步骤 2 / 3 · 选择远端连接',
    message: '选定后进入最终确认，可在那里核对远端目标。',
    barrierDismissible: false,
    actions: [
      for (final connection in connections)
        AdaptiveAction<ConnectionModel>(
          label: connection.name,
          caption: connection.protocol.targetLabel,
          value: connection,
          key: Key('velock-connection-${connection.id}'),
        ),
    ],
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
    return showAdaptiveForm<_VelockProfileReview>(
      context: context,
      title: '步骤 3 / 3 · 确认并创建',
      barrierDismissible: false,
      builder: (context, setDialogState) =>
          AdaptiveFormSpec<_VelockProfileReview>(
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AdaptiveTextField(
                    key: const Key('velock-profile-name'),
                    label: 'Profile 名称',
                    initialValue: displayName,
                    maxLength: 128,
                    onChanged: (value) =>
                        setDialogState(() => displayName = value),
                  ),
                  const SizedBox(height: 10),
                  Text('Vault：${approval.vaultDisplayName}'),
                  Text('设备：${approval.deviceDisplayName}'),
                  Text('远端：${connection.name} · ${connection.target}'),
                  const Divider(height: 20),
                  AdaptiveSwitchRow(
                    key: const Key('velock-background-enabled'),
                    title: '允许后台同步',
                    value: enabled,
                    onChanged: (value) => setDialogState(() => enabled = value),
                  ),
                  AdaptiveSwitchRow(
                    title: '允许使用蜂窝网络',
                    value: allowCellular,
                    onChanged: enabled
                        ? (value) => setDialogState(() => allowCellular = value)
                        : null,
                  ),
                  AdaptiveSwitchRow(
                    title: '仅充电时运行',
                    value: requiresCharging,
                    onChanged: enabled
                        ? (value) =>
                              setDialogState(() => requiresCharging = value)
                        : null,
                  ),
                  const SizedBox(height: 8),
                  AdaptiveOptionPicker<int>(
                    label: '蜂窝网络单次上限',
                    value: maximumBytes,
                    options: [
                      for (final value in choices)
                        ('$value MB', value * 1024 * 1024),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => maximumBytes = value),
                  ),
                  const Divider(height: 20),
                  Text(
                    '确认后先原子保存 Profile，成功后才消费本次一次性配对响应。',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.appSecondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              const AdaptiveAlertAction<_VelockProfileReview>(label: '返回'),
              AdaptiveAlertAction<_VelockProfileReview>(
                label: '确认并创建',
                key: const Key('finalize-velock-profile'),
                enabled: displayName.trim().isNotEmpty,
                isDefault: true,
                emphasized: true,
                value: _VelockProfileReview(
                  displayName: displayName.trim(),
                  backgroundPolicy: SyncProfileBackgroundPolicy(
                    enabled: enabled,
                    allowCellular: enabled && allowCellular,
                    requiresCharging: enabled && requiresCharging,
                    cellularMaxTransferBytes: maximumBytes,
                  ),
                ),
              ),
            ],
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
      title: '格间备份',
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
      child: Text(
        existingVelockProfiles.isEmpty
            ? '只需配对一次：在格间中批准本次请求后，会建立持续加密备份；以后新增或修改只传输增量。'
            : '本机已经有格间备份配置；如需更换远端或重新授权，请先移除当前配置再重新连接。',
        style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
      ),
    ),
    if (existingVelockProfiles.isNotEmpty)
      AdaptiveListSection(
        header: '已连接的格间备份',
        footer: const Text('同一时间只保留一个格间备份配置。需要更换远端或重新授权时，请先在上方配置中移除它。'),
        children: [
          for (final profile in existingVelockProfiles)
            Builder(
              builder: (context) {
                final presentation = _profileStatusPresentation(
                  context,
                  kind: profile.kind,
                  state: profile.state,
                  isIsolated: profile.isIsolated,
                  lastRunFailed: profile.activity?.latestRun?.state == 'failed',
                );
                return AdaptiveListTile(
                  leading: AdaptiveIconBadge(
                    icon: _adaptiveKindIcon(context, profile.kind),
                    color: presentation.tone.color(context),
                  ),
                  title: Text(
                    profile.displayName ?? '格间同步配置',
                    style: AppType.rowTitleStrong,
                  ),
                  subtitle: Text(
                    '${_kindLabel(profile.kind)} · ${presentation.label}',
                    maxLines: 2,
                  ),
                  showChevron: true,
                  onTap: () =>
                      context.push('/sync-profiles/${profile.profileId}'),
                );
              },
            ),
        ],
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
            child: AppPrimaryButton(
              key: const Key('go-create-connection'),
              label: '去创建连接',
              icon: CupertinoIcons.arrow_up_right,
              expand: true,
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
            title: const Text('开始连接格间'),
            subtitle: const Text('检查格间授权并发起配对。配置保存后会立即执行第一次上传或恢复。'),
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
      database.readSyncedDataSnapshot(widget.profileId),
      database.listTransferHistory(profileId: widget.profileId, limit: 100),
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
      synced: values[4] as SyncedDataSnapshot,
      history: values[5] as List<TransferJobRecord>,
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
            synced: data.synced,
            history: data.history,
            velockAvailability: data.velockAvailability,
            onChanged: _refresh,
          ),
        ),
        _DetailMaterialSurface(child: _PendingTab(transfers: data.transfers)),
        _DetailMaterialSurface(
          child: _HistoryTab(runs: data.runs, history: data.history),
        ),
        _DetailMaterialSurface(child: _ConflictsTab(conflicts: data.conflicts)),
        _DetailMaterialSurface(
          child: _ProfileSettingsTab(profile: profile, onChanged: _refresh),
        ),
      ];
      const labels = ['概览', '待处理', '历史', '冲突', '设置'];
      if (isApplePlatform(context)) {
        return AdaptiveScaffold(
          title: profile.displayName,
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.xs,
                  AppSpacing.page,
                  AppSpacing.xs,
                ),
                child: AppSegmentedTabs(
                  tabs: labels,
                  index: _selectedTab,
                  onChanged: (value) => setState(() => _selectedTab = value),
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
    required this.synced,
    required this.history,
    this.velockAvailability,
    required this.onChanged,
  });
  final SyncProfileEnvelope profile;
  final SyncRunRecord? latestRun;
  final SyncedDataSnapshot synced;
  final List<TransferJobRecord> history;
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
      await _presentSyncResult(context, result);
    } on Object catch (error, stackTrace) {
      final code = error is SyncFailureException
          ? error.syncFailure.errorCode
          : error.runtimeType.toString();
      logw('Sync profile action failed: $code', stackTrace: stackTrace);
      if (!mounted) return;
      _showMessage(context, '同步失败：${AppFormat.errorSummary(code)}');
    } finally {
      if (mounted) setState(() => _running = false);
    }
    if (mounted) widget.onChanged();
  }

  Future<void> _updateConnection() async {
    final confirmed = await showAdaptiveConfirmation(
      context,
      title: '连接已失效',
      message: '格间已重置或授权已失效，当前连接无法继续使用。是否更新连接（重新配对）？远端已有数据不会丢失。',
      confirmLabel: '更新连接',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    await ref
        .read(syncProfileRepositoryProvider)
        .remove(widget.profile.profileId);
    if (!mounted) return;
    context.push('/sync-profiles/new/velock');
  }

  @override
  Widget build(BuildContext context) {
    final isPaused = widget.profile.state == SyncProfileState.paused;
    final velockUnavailable =
        widget.profile.kind == SyncDatasetKind.velockManaged &&
        widget.velockAvailability != null &&
        widget.velockAvailability != VelockWizardAvailability.ready;
    final lastRunFailed = widget.latestRun?.state == 'failed';
    final presentation = _profileStatusPresentation(
      context,
      kind: widget.profile.kind,
      state: widget.profile.state,
      isIsolated: false,
      lastRunFailed: lastRunFailed,
      velockAvailability: widget.velockAvailability,
    );
    // A dead pairing keeps 「立即同步」 tappable: the tap opens the
    // "connection is stale — update it?" prompt instead of a greyed row.
    final needsConnectionUpdate =
        widget.profile.state == SyncProfileState.accessRequired;
    final canSync =
        widget.profile.state == SyncProfileState.active &&
        !_running &&
        !velockUnavailable;
    final latestRun = widget.latestRun;
    final runSummary = latestRun == null
        ? '还没有运行记录'
        : '${_runStateLabel(latestRun.state)} · '
              '${AppFormat.relativeTime(latestRun.completedAt ?? latestRun.startedAt)}';
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
        _ProfileSummaryCard(
          title: widget.profile.displayName,
          subtitle: widget.profile.kind == SyncDatasetKind.velockManaged
              ? '格间已加密数据的零知识远程备份'
              : '用户选择文件夹的加密双向同步',
          icon: _adaptiveKindIcon(context, widget.profile.kind),
          presentation: presentation,
          datasetLabel: _kindLabel(widget.profile.kind),
          lastRunLabel: runSummary,
          backgroundLabel: widget.profile.backgroundPolicy.enabled
              ? '已开启'
              : '已关闭',
        ),
        if (widget.profile.state == SyncProfileState.accessRequired)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              0,
              AppSpacing.page,
              AppSpacing.xs,
            ),
            child: AppNotice(
              tone: AppTone.danger,
              title: '连接已失效',
              message: '格间已重置或授权已失效。远端数据不会丢失；更新连接会移除当前配置并重新配对。',
              action: AppSecondaryButton(
                label: '更新连接',
                onPressed: _updateConnection,
              ),
            ),
          )
        else if (lastRunFailed)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              0,
              AppSpacing.page,
              AppSpacing.xs,
            ),
            child: AppNotice(
              tone: AppTone.danger,
              title: '上次同步未完成',
              message: _latestRunFailureSubtitle(latestRun),
            ),
          ),
        _SyncedDataSection(
          snapshot: widget.synced,
          profile: widget.profile,
          history: widget.history,
        ),
        AdaptiveListSection(
          header: '配置操作',
          children: [
            Semantics(
              button: true,
              label: '立即同步',
              onTap: needsConnectionUpdate
                  ? _updateConnection
                  : (canSync ? _runNow : null),
              child: AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.sync_rounded,
                    cupertino: CupertinoIcons.arrow_2_circlepath,
                  ),
                  color: context.appPrimary,
                ),
                title: Text(
                  needsConnectionUpdate
                      ? '立即同步'
                      : _running
                      ? '正在同步…'
                      : '立即同步',
                ),
                subtitle: Text(
                  needsConnectionUpdate
                      ? '连接已失效，点按可更新连接（重新配对）。'
                      : '立即检查远端并执行待处理同步。',
                ),
                enabled: canSync || needsConnectionUpdate,
                onTap: needsConnectionUpdate ? _updateConnection : _runNow,
              ),
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
      ],
    );
  }
}

/// Profile header: identity + status first, then the facts as label/value rows.
///
/// The previous surface mixed a dataset name, a run state and a toggle state
/// into one stat row, which made "失败" look like a peer of "格间数据".
class _ProfileSummaryCard extends StatelessWidget {
  const _ProfileSummaryCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.presentation,
    required this.datasetLabel,
    required this.lastRunLabel,
    required this.backgroundLabel,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final _ProfileStatusPresentation presentation;
  final String datasetLabel;
  final String lastRunLabel;
  final String backgroundLabel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.page,
      0,
      AppSpacing.page,
      AppSpacing.xs,
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: context.appGroupedSurface,
        borderRadius: BorderRadius.circular(AppRadii.large),
        border: Border.all(
          color: context.appSeparator.withValues(
            alpha: AppOpacity.groupedBorder,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdaptiveIconBadge(
                  icon: icon,
                  color: presentation.tone.color(context),
                  size: AppSizes.listLeading,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppType.cardTitle.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: AppType.rowSubtitle.copyWith(
                          color: context.appSecondaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.md,
            ),
            child: AdaptiveStatusBadge(
              label: presentation.label,
              tone: presentation.tone,
              icon: presentation.icon,
            ),
          ),
          Container(
            height: 0.5,
            color: context.appSeparator.withValues(
              alpha: AppOpacity.groupedDivider,
            ),
          ),
          AppFormRow(label: '数据集', value: datasetLabel),
          AppFormRow(
            label: '最近同步',
            child: Text(
              lastRunLabel,
              style: AppType.rowTitle.copyWith(
                color: presentation.tone == AppTone.ok
                    ? Theme.of(context).colorScheme.onSurface
                    : presentation.tone.color(context),
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          AppFormRow(label: '后台同步', value: backgroundLabel),
        ],
      ),
    ),
  );
}

Future<void> _presentSyncResult(
  BuildContext context,
  SyncProfileDispatchResult result,
) async {
  final pending = result.run?.download.pendingBatchCount ?? 0;
  if (result.didRun && pending > 0) {
    await _offerOpenVelock(context, pending);
    return;
  }
  _showMessage(context, _syncResultMessage(result));
}

Future<void> _presentFirstSyncResult(
  BuildContext context,
  SyncProfileDispatchResult? result,
) async {
  final pending = result?.run?.download.pendingBatchCount ?? 0;
  if (result?.didRun == true && pending > 0) {
    await _offerOpenVelock(context, pending);
    return;
  }
  _showMessage(context, _firstSyncResultMessage(result));
}

Future<void> _offerOpenVelock(BuildContext context, int pending) async {
  final shouldOpen = await showAdaptiveConfirmation(
    context,
    title: '同步完成',
    message: '已下载 $pending 批格间数据。\n是否现在打开格间继续恢复？',
    confirmLabel: '打开格间',
    cancelLabel: '稍后',
  );
  if (!shouldOpen || !context.mounted) return;
  final launched = await launchUrl(
    Uri.parse('velock://open'),
    mode: LaunchMode.externalApplication,
  );
  if (!launched && context.mounted) {
    _showMessage(context, '无法打开格间，请手动打开。');
  }
}

String _syncResultMessage(SyncProfileDispatchResult result) {
  if (result.didFail) {
    final failure = SyncFailureClassifier.classify(result.error!);
    if (failure.providerStatusCode == 409) {
      return '同步失败：远端同步目录存在冲突（HTTP 409）。请确认没有其他设备同时同步，或检查远端目录后重试。';
    }
    return '同步失败：${failure.suggestedAction}';
  }
  if (!result.didRun) {
    return '同步未启动：${_dispatchLabel(result.status)}';
  }
  final upload = result.run?.upload.publishedBatchCount ?? 0;
  final imported = result.run?.download.importedBatchCount ?? 0;
  final pending = result.run?.download.pendingBatchCount ?? 0;
  if (pending > 0) {
    return '已下载 $pending 批远端数据，请打开格间并解锁以完成恢复。';
  }
  if (upload > 0 && imported > 0) {
    return '同步完成：已上传 $upload 批本地变更，并恢复 $imported 批远端数据。';
  }
  if (upload > 0) {
    return '已上传 $upload 批本地变更。';
  }
  if (imported > 0) {
    return '已恢复 $imported 批远端数据。';
  }
  return '没有新的本地变更或远端数据。';
}

class _PendingTab extends StatelessWidget {
  const _PendingTab({required this.transfers});
  final List<TransferJobRecord> transfers;

  @override
  Widget build(BuildContext context) => transfers.isEmpty
      ? AdaptiveEmptyState(
          icon: CupertinoIcons.tray_arrow_down,
          tone: AppTone.ok,
          title: '没有待处理传输',
          message: '所有传输都已完成。新的上传和下载任务启动时会显示在这里。',
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
                      '${transfer.direction == TransferJobDirection.upload ? '上传' : '下载'} · ${_transferStateLabel(transfer.state)}',
                    ),
                    subtitle: Text(
                      transfer.expectedSize == null
                          ? AppFormat.bytes(transfer.completedBytes)
                          : '${AppFormat.bytes(transfer.completedBytes)} / ${AppFormat.bytes(transfer.expectedSize)}',
                      maxLines: 2,
                    ),
                    enabled: transfer.state != TransferJobState.failed,
                  ),
              ],
            ),
          ],
        );
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.runs, required this.history});
  final List<SyncRunRecord> runs;
  final List<TransferJobRecord> history;

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
                          AppFormat.relativeTime(
                            run.completedAt ?? run.startedAt,
                          ),
                          maxLines: 2,
                        ),
                        showChevron: true,
                        onTap: () =>
                            _showRunDetails(context, run, history: history),
                      );
                    },
                  ),
              ],
            ),
          ],
        );
}

/// Read-only run record. Human conclusion first; raw protocol fields stay in
/// the collapsed technical footnote instead of the primary copy.

/// Full itemised list of everything this device has moved.
Future<void> _showSyncedObjectsSheet(
  BuildContext context,
  List<TransferJobRecord> history,
) => showAppDetailSheet(
  context,
  title: '已同步对象明细',
  rows: [
    for (final transfer in history)
      AppDetailSheetRow(
        label:
            '${_syncedKindLabel(remoteInventoryKind(transfer.logicalKey))} · '
            '${transfer.direction == TransferJobDirection.upload ? '上传' : '恢复'}',
        value:
            '${AppFormat.bytes(transfer.completedBytes)} · '
            '${AppFormat.stamp(transfer.completedAt)}',
      ),
  ],
  footnote: '格间备份以加密对象为单位（批次 / 数据块 / 提交）；原始文件名只在格间 App 内可见。',
);

Future<void> _showRunDetails(
  BuildContext context,
  SyncRunRecord run, {
  List<TransferJobRecord> history = const [],
}) {
  final runEnd = run.completedAt;
  final transferred = [
    for (final transfer in history)
      if (transfer.completedAt != null &&
          !transfer.completedAt!.isBefore(run.startedAt) &&
          (runEnd == null || !transfer.completedAt!.isAfter(runEnd)))
        transfer,
  ];
  final uploaded = transferred
      .where((transfer) => transfer.direction == TransferJobDirection.upload)
      .toList(growable: false);
  final downloaded = transferred
      .where((transfer) => transfer.direction == TransferJobDirection.download)
      .toList(growable: false);
  int bytesOf(List<TransferJobRecord> items) =>
      items.fold(0, (sum, item) => sum + item.completedBytes);
  final detailLines = [
    for (final transfer in transferred)
      '${_syncedKindLabel(remoteInventoryKind(transfer.logicalKey))} · '
          '${transfer.direction == TransferJobDirection.upload ? '上传' : '恢复'} · '
          '${AppFormat.bytes(transfer.completedBytes)} · '
          '${AppFormat.stamp(transfer.completedAt)}',
  ];

  final failed = run.state == 'failed';
  final technical = <String>[
    if (run.errorCode != null) '错误代码：${run.errorCode}',
    if (run.errorCategory != null) '错误分类：${run.errorCategory}',
    if (run.providerStatusCode != null) '服务状态码：${run.providerStatusCode}',
    if (run.retryable != null) '可重试：${run.retryable! ? '是' : '否'}',
    if (run.retryAfter != null) '建议等待：${run.retryAfter!.inSeconds} 秒',
  ].join('\n');
  return showAppDetailSheet(
    context,
    title: '同步记录 · ${_runStateLabel(run.state)}',
    rows: [
      AppDetailSheetRow(label: '开始时间', value: AppFormat.stamp(run.startedAt)),
      AppDetailSheetRow(label: '结束时间', value: AppFormat.stamp(run.completedAt)),
      AppDetailSheetRow(
        label: '结果',
        value: _runStateLabel(run.state),
        tone: failed ? AppTone.danger : AppTone.ok,
      ),
      if (failed)
        AppDetailSheetRow(
          label: '可能原因',
          value: AppFormat.errorSummary(run.errorCode),
        ),
      if (run.suggestedAction != null)
        AppDetailSheetRow(label: '建议操作', value: run.suggestedAction!),
      AppDetailSheetRow(
        label: '上传对象',
        value: '${uploaded.length} 个 · ${AppFormat.bytes(bytesOf(uploaded))}',
      ),
      AppDetailSheetRow(
        label: '恢复对象',
        value:
            '${downloaded.length} 个 · ${AppFormat.bytes(bytesOf(downloaded))}',
      ),
      AppDetailSheetRow(
        label: '传输明细',
        value: detailLines.isEmpty ? '本次没有传输任何对象' : detailLines.join('\n'),
      ),
    ],
    footnote: technical.isEmpty ? null : '技术详情\n$technical',
  );
}

class _ConflictsTab extends StatelessWidget {
  const _ConflictsTab({required this.conflicts});
  final List<SyncConflictRecord> conflicts;

  @override
  Widget build(BuildContext context) => conflicts.isEmpty
      ? AdaptiveEmptyState(
          icon: CupertinoIcons.shield_lefthalf_fill,
          tone: AppTone.ok,
          title: '没有待处理冲突',
          message: '同一对象在两台设备上被同时修改时，冲突会出现在这里，并可在活动页选择处理方式。',
          secondaryAction: AppSecondaryButton(
            label: '前往活动页',
            onPressed: () => context.go('/activity'),
          ),
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
      if (profile.kind == SyncDatasetKind.selectedFolder)
        AdaptiveListSection(
          header: '恢复与安全',
          footer: const Text('恢复包用于在另一台设备重新加入这个同步空间。恢复包和口令应通过不同渠道保存。'),
          children: [
            Semantics(
              button: true,
              label: '生成恢复包',
              onTap: () => _exportSelectedFolderRecovery(context, ref, profile),
              child: AdaptiveListTile(
                widgetKey: const Key('selected-folder-export-recovery'),
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: Icons.key_outlined,
                    cupertino: CupertinoIcons.lock,
                  ),
                  color: context.appPrimary,
                ),
                title: const Text('生成恢复包'),
                subtitle: const Text('创建带恢复口令的一次性凭据。'),
                showChevron: true,
                onTap: () =>
                    _exportSelectedFolderRecovery(context, ref, profile),
              ),
            ),
          ],
        ),
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
              final confirmed = await showAdaptiveConfirmation(
                context,
                title: '移除同步配置？',
                message: '此操作只移除本地配置。',
                confirmLabel: '移除',
                isDestructive: true,
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
                if (!context.mounted) return;
                // A removed profile must disappear from the sync home and the
                // Velock wizard immediately. Both reload when this revision
                // changes; without the bump they keep the stale list and the
                // removal looks like it failed.
                ref.read(profilesRevisionProvider.notifier).bump();
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/dashboard');
                }
              } on SyncProfileRemovalWhileRunningException {
                if (context.mounted) _showMessage(context, '同步正在运行，暂时无法移除。');
              } on Object {
                if (context.mounted) _showMessage(context, '移除失败，请稍后重试。');
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
        '已释放 ${AppFormat.bytes(result.freedBytes)}；'
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
      final choice = await showAdaptiveAlert<String>(
        context: context,
        title: '脱敏诊断',
        details: SizedBox(
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
          AdaptiveAlertAction<String>(
            label: '复制',
            value: 'copy',
            key: const Key('copy-sanitized-diagnostics'),
          ),
          AdaptiveAlertAction<String>(
            label: '完成',
            value: 'done',
            isDefault: true,
            emphasized: true,
          ),
        ],
      );
      if (choice == 'copy') {
        await Clipboard.setData(ClipboardData(text: diagnostics));
      }
    } on Object {
      if (mounted) _showMessage(context, '无法生成脱敏诊断。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseCellularLimit(SyncGlobalSettings settings) async {
    final selected = await showAdaptiveActionSheet<int>(
      context: context,
      title: '默认蜂窝网络传输上限',
      message: '加密内容按单个传输对象限制。',
      actions: [
        for (final bytes in const [
          10 * 1024 * 1024,
          50 * 1024 * 1024,
          100 * 1024 * 1024,
        ])
          AdaptiveAction<int>(label: AppFormat.bytes(bytes), value: bytes),
      ],
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
    final gc = value.garbageCollection;
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
              additionalInfo: Text(
                value.backgroundSupported ? '可用' : '受限',
                style: TextStyle(
                  color: value.backgroundSupported
                      ? AppTone.ok.color(context)
                      : context.appSecondaryLabel,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
                  ? Text(AppFormat.bytes(currentLimit))
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
                          child: Text('10 MB'),
                        ),
                        DropdownMenuItem(
                          value: 50 * 1024 * 1024,
                          child: Text('50 MB'),
                        ),
                        DropdownMenuItem(
                          value: 100 * 1024 * 1024,
                          child: Text('100 MB'),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '删除保护',
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                gc == null
                    ? '完成一次包含有效检查点的同步后才会开始安全清理。'
                    : gc.state == 'completed'
                    ? '本次检查 ${gc.candidateCount} 个候选，'
                          '${gc.eligibleCandidateCount} 个满足清理条件，'
                          '已删除 ${gc.deletedObjectCount} 个对象。'
                    : gc.skipReason == 'checkpoint-missing'
                    ? '尚未获得可信检查点，本次安全清理已跳过。'
                    : '本次安全清理已跳过。',
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '实际清理额外保留 7 天缓冲。任一活跃设备未确认前，远端不会清理；'
                '长期离线不会自动失效，请在格间设置 → 数据同步 → 已授权设备中移除。',
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Sync 只负责安全清理，不展示最近删除列表、文件名、路径或恢复按钮。',
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
            ],
          ),
          children: [
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: CupertinoIcons.delete,
                color: AppTone.ok.color(context),
              ),
              title: const Text('删除保护'),
              subtitle: const Text('最近 30 天内的删除可恢复。', maxLines: 2),
              trailing: AdaptiveStatusBadge(
                label: '已开启',
                tone: AppTone.ok,
                icon: CupertinoIcons.check_mark_circled,
              ),
            ),
            AppFormRow(
              label: '最近清理',
              value: gc?.completedAt == null
                  ? '尚未执行'
                  : AppFormat.relativeTime(gc!.completedAt),
            ),
            AppFormRow(
              label: '等待确认',
              value: '${gc?.unackedDeviceCount ?? 0} 台设备',
            ),
            AppFormRow(label: '活跃设备', value: '${gc?.activeDeviceCount ?? 0} 台'),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '暂存空间',
          children: [
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: CupertinoIcons.archivebox,
                color: AppTone.brand.color(context),
              ),
              title: Text(
                AppFormat.bytes(value.staging.totalBytes),
                style: AppType.rowTitleStrong,
              ),
              subtitle: Text(
                '${value.staging.batchCount} 个批次 · ${value.staging.fileCount} 个文件。'
                '清理会保留可恢复批次，并跳过正在同步的配置。',
                maxLines: 2,
              ),
              trailing: AppSecondaryButton(
                key: const Key('cleanup-staging'),
                label: '清理',
                onPressed: _busy ? null : _cleanupStaging,
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
                '日志和诊断不包含凭据、密钥、原始路径、配置标识、'
                '格间业务内容或受保护冲突详情。',
                maxLines: 3,
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
              subtitle: const Text('仅导出版本、系统能力、聚合计数、稳定错误码和暂存用量。', maxLines: 2),
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

/// "What has actually been synced" — the reassurance view.
///
/// Two sources are shown side by side: durable local counters (what this
/// device moved) and an on-demand scan of the remote vault prefix (what is
/// actually stored). Everything is aggregated — no keys, paths or file names.
class _SyncedDataSection extends ConsumerStatefulWidget {
  const _SyncedDataSection({
    required this.snapshot,
    required this.profile,
    required this.history,
  });

  final SyncedDataSnapshot snapshot;
  final SyncProfileEnvelope profile;
  final List<TransferJobRecord> history;

  @override
  ConsumerState<_SyncedDataSection> createState() => _SyncedDataSectionState();
}

class _SyncedDataSectionState extends ConsumerState<_SyncedDataSection> {
  RemoteInventorySnapshot? _remote;
  VelockExchangeQueueSnapshot? _queue;
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.profile.kind == SyncDatasetKind.velockManaged) {
      unawaited(_loadQueue());
    }
  }

  Future<void> _loadQueue() async {
    final snapshot = await ref.read(velockExchangeQueueProbeProvider).read();
    if (!mounted || snapshot == null) return;
    setState(() => _queue = snapshot);
  }

  Future<void> _scanRemote() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final snapshot = await ref
          .read(remoteInventoryServiceProvider)
          .scan(
            connectionId: widget.profile.connectionId,
            vaultId: widget.profile.vaultId,
          );
      if (!mounted) return;
      setState(() => _remote = snapshot);
    } on Object {
      if (!mounted) return;
      setState(() => _error = '无法读取远端清单，请检查连接后重试。');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final remote = _remote;
    final lastActivity = snapshot.lastActivityAt;
    final pendingTransfers =
        snapshot.pendingUploadCount + snapshot.pendingDownloadCount;
    final kinds = _mergedKinds();
    return AdaptiveListSection(
      header: '已同步的数据',
      footer: Text(
        remote != null && remote.totalCount == 0
            ? '远端目前没有这个空间的加密对象。'
            : widget.profile.kind == SyncDatasetKind.velockManaged
            ? '格间备份按加密对象统计（批次 / 数据块 / 提交）；原始文件名只在格间 App 内可见。'
            : '按加密对象统计；文件路径不会离开本机。',
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.rowHorizontal,
            AppSpacing.sm,
            AppSpacing.rowHorizontal,
            AppSpacing.sm,
          ),
          child: AppMetricGrid(
            metrics: [
              AppMetric(value: '${snapshot.uploadedCount}', label: '本机已上传'),
              AppMetric(value: '${snapshot.downloadedCount}', label: '本机已恢复'),
              AppMetric(
                value: AppFormat.bytes(snapshot.totalBytes),
                label: '本机累计流量',
              ),
            ],
          ),
        ),
        if (lastActivity != null)
          _SyncedDataRow(
            icon: Icons.schedule_outlined,
            label: '最近同步',
            value: AppFormat.relativeTime(lastActivity),
          ),
        _SyncedDataRow(
          icon: Icons.layers_outlined,
          label: '增量批次',
          value:
              '已发布 ${snapshot.publishedOutgoingCount} · '
              '已应用 ${snapshot.appliedIncomingCount}',
        ),
        if (pendingTransfers > 0)
          _SyncedDataRow(
            icon: Icons.sync_outlined,
            label: '待传输对象',
            value:
                '上传 ${snapshot.pendingUploadCount} · '
                '下载 ${snapshot.pendingDownloadCount}',
          ),
        for (final kind in kinds) _SyncedKindRow(kind: kind),
        for (final device in snapshot.devices)
          _SyncedDataRow(
            icon: Icons.devices_outlined,
            label: '远端设备 ${_shortId(device.deviceId)}',
            value: '已应用 ${device.appliedSequence} 个增量',
          ),
        if (widget.history.isNotEmpty) ...[
          AdaptiveListTile(
            key: const Key('synced-objects-entry'),
            leading: AdaptiveIconBadge(
              icon: adaptiveIcon(
                context,
                material: Icons.inventory_2_outlined,
                cupertino: CupertinoIcons.cube_box,
              ),
              size: AppSizes.listLeadingCompact,
            ),
            title: const Text('已同步对象明细'),
            subtitle: Text(
              '共 ${widget.history.length} 个对象，最近 ${AppFormat.relativeTime(widget.history.first.completedAt)}',
            ),
            showChevron: true,
            onTap: () => _showSyncedObjectsSheet(context, widget.history),
          ),
        ],
        if (_queue != null) ...[
          _SyncedDataRow(
            icon: Icons.outbox_outlined,
            label: '格间待上传批次',
            value: '${_queue!.outboxReadyCount} 个',
          ),
          _SyncedDataRow(
            icon: Icons.move_to_inbox_outlined,
            label: '待格间导入',
            value: '${_queue!.inboxReadyCount} 个',
          ),
          if (_queue!.lastOutboxReceiptAt != null)
            _SyncedDataRow(
              icon: Icons.handshake_outlined,
              label: '上次数据交接',
              value: AppFormat.relativeTime(_queue!.lastOutboxReceiptAt),
            ),
          if (_queue!.isEmpty && snapshot.uploadedCount == 0)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.rowHorizontal,
                vertical: AppSpacing.xs,
              ),
              child: Text(
                '格间目前没有新的待同步内容；在格间里新增或修改数据后会自动排队。',
                style: AppType.rowSubtitle.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
            ),
        ],
        _SyncedDataRow(
          icon: Icons.cloud_outlined,
          label: '远端已保存',
          value: remote == null
              ? '未扫描'
              : '${remote.totalCount} 个对象 · ${AppFormat.bytes(remote.totalBytes)}',
        ),
        if (remote != null && remote.lastUpdatedAt != null)
          _SyncedDataRow(
            icon: Icons.update_outlined,
            label: '远端最近更新',
            value: AppFormat.relativeTime(remote.lastUpdatedAt),
          ),
        if (remote != null)
          for (final entry in remote.entries)
            _SyncedKindRow(
              kind: SyncedDataKindSummary(
                kind: entry.kind,
                bytes: entry.bytes,
                remoteCount: entry.count,
              ),
            ),
        if (remote != null && remote.truncated)
          const Padding(
            padding: EdgeInsets.symmetric(
              horizontal: AppSpacing.rowHorizontal,
              vertical: AppSpacing.xs,
            ),
            child: Text('清单较大，仅统计了前 600 个对象。'),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.rowHorizontal,
              vertical: AppSpacing.xs,
            ),
            child: Text(_error!, style: TextStyle(color: context.appDanger)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.rowHorizontal,
            AppSpacing.xs,
            AppSpacing.rowHorizontal,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '从远端存储读取实际已保存的加密对象。',
                  style: AppType.rowSubtitle.copyWith(
                    color: context.appSecondaryLabel,
                  ),
                ),
              ),
              if (_scanning)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  child: CupertinoActivityIndicator(),
                )
              else
                TextButton(
                  onPressed: _scanRemote,
                  child: Text(remote == null ? '扫描远端' : '重新扫描'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Upload/download buckets merged into one list per content kind.
  List<SyncedDataKindSummary> _mergedKinds() {
    final counts = <String, ({int upload, int download, int bytes})>{};
    for (final kind in widget.snapshot.uploadedKinds) {
      final current = counts[kind.kind] ?? (upload: 0, download: 0, bytes: 0);
      counts[kind.kind] = (
        upload: current.upload + kind.count,
        download: current.download,
        bytes: current.bytes + kind.bytes,
      );
    }
    for (final kind in widget.snapshot.downloadedKinds) {
      final current = counts[kind.kind] ?? (upload: 0, download: 0, bytes: 0);
      counts[kind.kind] = (
        upload: current.upload,
        download: current.download + kind.count,
        bytes: current.bytes + kind.bytes,
      );
    }
    final summaries = [
      for (final entry in counts.entries)
        SyncedDataKindSummary(
          kind: entry.key,
          uploadedCount: entry.value.upload,
          downloadedCount: entry.value.download,
          bytes: entry.value.bytes,
        ),
    ];
    summaries.sort((a, b) => b.bytes.compareTo(a.bytes));
    return summaries;
  }
}

class SyncedDataKindSummary {
  const SyncedDataKindSummary({
    required this.kind,
    this.uploadedCount = 0,
    this.downloadedCount = 0,
    required this.bytes,
    this.remoteCount,
  });

  final String kind;
  final int uploadedCount;
  final int downloadedCount;
  final int bytes;

  /// Set when the row describes the remote listing instead of local transfers.
  final int? remoteCount;
}

class _SyncedKindRow extends StatelessWidget {
  const _SyncedKindRow({required this.kind});

  final SyncedDataKindSummary kind;

  @override
  Widget build(BuildContext context) => AdaptiveListTile(
    leading: AdaptiveIconBadge(
      icon: _syncedKindIcon(context, kind.kind),
      size: AppSizes.listLeadingCompact,
    ),
    title: Text(_syncedKindLabel(kind.kind)),
    subtitle: Text(
      kind.remoteCount != null
          ? '远端 ${kind.remoteCount} 个对象'
          : '上传 ${kind.uploadedCount} 项 · 下载 ${kind.downloadedCount} 项',
    ),
    trailing: Text(
      AppFormat.bytes(kind.bytes),
      style: AppType.rowSubtitle.copyWith(color: context.appSecondaryLabel),
    ),
  );
}

class _SyncedDataRow extends StatelessWidget {
  const _SyncedDataRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.rowHorizontal,
      vertical: AppSpacing.sm,
    ),
    child: Row(
      children: [
        Icon(icon, size: 18, color: context.appSecondaryLabel),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            label,
            style: AppType.rowSubtitle.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        Text(
          value,
          style: AppType.rowSubtitle.copyWith(color: context.appSecondaryLabel),
        ),
      ],
    ),
  );
}

String _syncedKindLabel(String kind) => switch (kind) {
  'batches' => '增量批次',
  'blobs' => '数据块',
  'commits' => '提交校验',
  'checkpoints' => '检查点',
  'acknowledgements' => '同步回执',
  'protocol' => '协议与设备',
  'maintenance' => '保留与清理',
  _ => '其他对象',
};

IconData _syncedKindIcon(BuildContext context, String kind) => switch (kind) {
  'batches' => adaptiveIcon(
    context,
    material: Icons.layers_outlined,
    cupertino: CupertinoIcons.square_stack_3d_up,
  ),
  'blobs' => adaptiveIcon(
    context,
    material: Icons.data_object,
    cupertino: CupertinoIcons.cube_box,
  ),
  'commits' => adaptiveIcon(
    context,
    material: Icons.verified_outlined,
    cupertino: CupertinoIcons.checkmark_seal,
  ),
  'checkpoints' => adaptiveIcon(
    context,
    material: Icons.flag_outlined,
    cupertino: CupertinoIcons.flag,
  ),
  'acknowledgements' => adaptiveIcon(
    context,
    material: Icons.done_all,
    cupertino: CupertinoIcons.checkmark_alt,
  ),
  'protocol' => adaptiveIcon(
    context,
    material: Icons.badge_outlined,
    cupertino: CupertinoIcons.person_badge_plus,
  ),
  'maintenance' => adaptiveIcon(
    context,
    material: Icons.auto_delete_outlined,
    cupertino: CupertinoIcons.trash,
  ),
  _ => adaptiveIcon(
    context,
    material: Icons.inventory_2_outlined,
    cupertino: CupertinoIcons.cube_box,
  ),
};

class _DetailData {
  const _DetailData({
    required this.profile,
    required this.latestRun,
    required this.runs,
    required this.transfers,
    required this.conflicts,
    required this.synced,
    required this.history,
    this.velockAvailability,
  });
  final SyncProfileEnvelope? profile;
  final SyncRunRecord? latestRun;
  final List<SyncRunRecord> runs;
  final List<TransferJobRecord> transfers;
  final List<SyncConflictRecord> conflicts;
  final SyncedDataSnapshot synced;
  final List<TransferJobRecord> history;
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

Future<void> _exportSelectedFolderRecovery(
  BuildContext context,
  WidgetRef ref,
  SyncProfileEnvelope profile,
) async {
  final rootKeyRef = profile.dataset['rootKeyRef'];
  if (rootKeyRef is! String || rootKeyRef.isEmpty) {
    _showMessage(context, '无法读取此配置的恢复密钥引用。');
    return;
  }
  final passphrase = await _requestProfileRecoveryPassphrase(context);
  if (passphrase == null || !context.mounted) return;
  try {
    final recoveryPackage =
        await GenericVaultRecoveryService(
          ref.read(vaultKeyStoreProvider),
        ).exportBundle(
          rootKeyRef: rootKeyRef,
          vaultId: profile.vaultId,
          trustedDevices: await ref
              .read(syncStateDatabaseProvider)
              .readTrustedDevicePublicKeys(vaultId: profile.vaultId),
          passphrase: passphrase,
        );
    if (context.mounted) {
      await _showProfileRecoveryPackage(context, recoveryPackage);
    }
  } on Object catch (error, stackTrace) {
    logw(
      'Selected Folder recovery export failed: ${error.runtimeType}',
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      _showMessage(context, '无法生成恢复包；请检查本机密钥状态。');
    }
  }
}

Future<String?> _requestProfileRecoveryPassphrase(BuildContext context) async {
  final values = await showAdaptiveTextInputs(
    context: context,
    title: '生成恢复包',
    message: '恢复包和口令需通过不同的受保护渠道保存。',
    inputs: const [
      AdaptiveTextInput(
        label: '恢复口令',
        placeholder: '恢复口令',
        obscureText: true,
        autocorrect: false,
      ),
      AdaptiveTextInput(
        label: '再次输入恢复口令',
        placeholder: '再次输入恢复口令',
        obscureText: true,
        autocorrect: false,
      ),
    ],
    confirmLabel: '生成',
    isValid: (values) => values[0].isNotEmpty && values[0] == values[1],
  );
  if (values == null) return null;
  return values[0];
}

Future<void> _showProfileRecoveryPackage(
  BuildContext context,
  String recoveryPackage,
) => showAdaptiveNotice(
  context: context,
  title: '一次性恢复包',
  message: '请安全保存。此窗口关闭后应用不会保留或自动复制该恢复包。',
  details: SelectableText(recoveryPackage),
  confirmLabel: '我已安全保存',
);

String _kindLabel(SyncDatasetKind? kind) => switch (kind) {
  SyncDatasetKind.selectedFolder => '文件夹同步',
  SyncDatasetKind.velockManaged => '格间备份',
  null => '不可用',
};

IconData _adaptiveKindIcon(BuildContext context, SyncDatasetKind? kind) =>
    switch (kind) {
      SyncDatasetKind.selectedFolder => adaptiveIcon(
        context,
        material: Icons.folder_outlined,
        cupertino: CupertinoIcons.folder,
      ),
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
      VelockWizardAvailability.accessRevoked => '格间已重置或授权被撤销，请移除本配置后重新配对。',
      VelockWizardAvailability.unsupportedVersion => '请升级 Velock 本体后重试。',
      VelockWizardAvailability.signatureMismatch => '已安装的 Velock 本体无法验证。',
      VelockWizardAvailability.configurationMissing => 'Velock 本体的同步通道不可用。',
      VelockWizardAvailability.temporarilyUnavailable => 'Velock 本体暂时无法访问。',
      VelockWizardAvailability.unsupportedPlatform => '当前平台不支持 Velock 本体。',
      VelockWizardAvailability.ready => 'Velock 安全空间',
    };

String _transferStateLabel(TransferJobState state) => switch (state) {
  TransferJobState.queued => '等待中',
  TransferJobState.running => '进行中',
  TransferJobState.paused => '已暂停',
  TransferJobState.retryWaiting => '等待重试',
  TransferJobState.completed => '已完成',
  TransferJobState.failed => '失败',
  TransferJobState.cancelled => '已取消',
};

String _runStateLabel(String state) => switch (state) {
  'running' => '运行中',
  'completed' => '已完成',
  'failed' => '失败',
  _ => state,
};

/// One short line under a profile name.
///
/// The section header already names the domain, and the state badge already
/// names the state, so the row only answers "when did it last run" — the long
/// "格间备份 · 后台同步已开启 · 最近成功备份：…" line repeated everything the
/// rest of the row said.
String _profileSecondaryText(SyncProfileSummary summary) {
  final activity = summary.activity;
  if (activity != null && activity.unresolvedConflictCount > 0) {
    return '${activity.unresolvedConflictCount} 个冲突待处理';
  }
  if (activity != null &&
      activity.pendingUploadCount + activity.pendingDownloadCount > 0) {
    return '有待传输项目';
  }
  final run = activity?.latestRun;
  if (run == null) {
    return summary.kind == SyncDatasetKind.selectedFolder ? '尚未同步' : '尚未备份';
  }
  if (run.state == 'running') return '正在同步…';
  return AppFormat.relativeTime(run.completedAt ?? run.startedAt);
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
        '格间备份仅支持已配置的 Apple Exchange 构建。',
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

void _showMessage(BuildContext context, String message) =>
    showPlatformMessage(context, message);
