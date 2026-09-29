/// The two product domains have separate destinations; they never share a list.
library;

import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_queue_probe.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_storage_help.dart';
import 'package:velock_sync/features/cloud_backup/application/velock_snapshot_providers.dart';

import 'dart:async';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_actions.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_history_help.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/features/cloud_backup/ui/velock_companion_gate.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'sync_profile_workspace_shared.dart';
import 'sync_profile_providers.dart';

class SyncProfilesHome extends ConsumerStatefulWidget {
  const SyncProfilesHome({
    super.key,
    this.kind = SyncDatasetKind.velockManaged,
  });
  final SyncDatasetKind kind;
  @override
  ConsumerState<SyncProfilesHome> createState() => _SyncProfilesHomeState();
}

class _SyncProfilesHomeState extends ConsumerState<SyncProfilesHome>
    with WidgetsBindingObserver {
  late Future<_HomeData> _profiles;
  final Set<String> _running = {};
  Timer? _runRefresh;
  int _loadGeneration = 0;
  bool _checkingSnapshotContinuation = false;
  bool _rechecking = false;
  bool get _isVelock => widget.kind == SyncDatasetKind.velockManaged;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _profiles = _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_continueAppliedSnapshots());
    });
  }

  @override
  void dispose() {
    _runRefresh?.cancel();
    _loadGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _refresh();
      unawaited(_continueAppliedSnapshots());
    }
  }

  Future<void> _continueAppliedSnapshots() async {
    if (!_isVelock || _checkingSnapshotContinuation) return;
    _checkingSnapshotContinuation = true;
    try {
      final profiles = await ref
          .read(syncProfileRepositoryProvider)
          .listSummaries();
      for (final profile in profiles) {
        if (!mounted) return;
        if (profile.kind != SyncDatasetKind.velockManaged ||
            profile.isIsolated ||
            _running.contains(profile.profileId)) {
          continue;
        }
        bool ready;
        try {
          ready = await ref.read(snapshotContinuationReadyProvider)(
            profile.profileId,
          );
        } on Object {
          // Keep the existing action visible; an unavailable local exchange
          // is never treated as a completed restore.
          continue;
        }
        if (!mounted) return;
        if (!ready) continue;
        setState(() => _running.add(profile.profileId));
        try {
          final result = await runSyncWithProgress(
            context,
            ref,
            profile.profileId,
          );
          if (mounted) await presentFirstSyncResult(context, result);
        } on Object catch (error) {
          if (mounted) {
            await presentSyncFailureAlert(context: context, error: error);
          }
        } finally {
          if (mounted) {
            setState(() => _running.remove(profile.profileId));
            _refresh();
          }
        }
      }
    } finally {
      _checkingSnapshotContinuation = false;
    }
  }

  VelockOutboxStatus? _velockStatus;

  /// Velock's hand-over hint is read beside the page load, never inside it:
  /// the card must not wait on the shared folder.
  Future<void> _loadVelockStatus(int generation) async {
    VelockOutboxStatus? status;
    try {
      status = (await ref.read(velockExchangeQueueProbeProvider).read())
          ?.velockStatus;
    } on Object {
      return;
    }
    if (!mounted || generation != _loadGeneration) return;
    if (status?.needsVelock == _velockStatus?.needsVelock &&
        status?.pendingConflicts == _velockStatus?.pendingConflicts &&
        status?.unpackagedChanges == _velockStatus?.unpackagedChanges) {
      return;
    }
    _velockStatus = status;
    _refresh();
  }

  Future<_HomeData> _load() async {
    final generation = ++_loadGeneration;
    final all = await ref.read(syncProfileRepositoryProvider).listSummaries();
    final profiles = all
        .where((p) => p.kind == widget.kind && !p.isIsolated)
        .toList();
    VelockWizardAvailability? availability;
    VelockOutboxStatus? velockStatus;
    final snapshots = <String, SyncedDataSnapshot>{};
    if (_isVelock && profiles.isNotEmpty) {
      final ready = await ref
          .read(velockWizardReadinessServiceProvider)
          .inspect(syncAppInstanceId: profiles.first.deviceId)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => const VelockWizardReadiness(
              VelockWizardAvailability.temporarilyUnavailable,
            ),
          );
      availability = ready.availability;
      velockStatus = _velockStatus;
      unawaited(_loadVelockStatus(generation));
      for (final p in profiles) {
        snapshots[p.profileId] = await ref
            .read(syncStateDatabaseProvider)
            .readSyncedDataSnapshot(p.profileId);
      }
    } else if (_isVelock) {
      // Before anything is set up, only a gated state (old Velock, or a
      // build/platform without the exchange) changes what is offered here.
      // Everything else is handled step by step inside the wizard.
      final ready = await ref
          .read(velockWizardReadinessServiceProvider)
          .inspect()
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => const VelockWizardReadiness(
              VelockWizardAvailability.temporarilyUnavailable,
            ),
          );
      if (isVelockBackupGated(ready.availability)) {
        availability = ready.availability;
      }
    }
    if (mounted && generation == _loadGeneration) {
      _runRefresh?.cancel();
      if (profiles.any((p) => p.activity?.latestRun?.state == 'running')) {
        _runRefresh = Timer(const Duration(seconds: 1), () {
          if (mounted) _refresh();
        });
      }
    }
    return _HomeData(
      profiles,
      snapshots,
      availability,
      all.where((p) => p.isIsolated).toList(),
      velockStatus,
    );
  }

  void _refresh() {
    if (mounted) {
      setState(() {
        _profiles = _load();
      });
    }
  }

  Future<void> _refreshAndWait() async {
    final pending = _load();
    setState(() {
      _profiles = pending;
    });
    await pending;
  }

  Future<void> _recheck() async {
    if (_rechecking) return;
    setState(() => _rechecking = true);
    try {
      await _refreshAndWait();
    } finally {
      if (mounted) setState(() => _rechecking = false);
    }
  }

  Future<void> _open(String route) async {
    await context.push(route);
    if (mounted) _refresh();
  }

  Future<void> _action(
    SyncProfileSummary profile,
    BackupPresentation state,
  ) async {
    if (_running.contains(profile.profileId)) return;
    switch (state.action) {
      case BackupAction.openVelock:
        await openVelockForBackup(context, ref, profileId: profile.profileId);
        return;
      case BackupAction.checkStorage:
        final saved = await ref
            .read(syncProfileRepositoryProvider)
            .read(profile.profileId);
        if (!mounted) return;
        if (saved != null) await showBackupStorageHelp(context, saved);
        if (mounted) _refresh();
        return;
      case BackupAction.reviewHistory:
        final saved = await ref
            .read(syncProfileRepositoryProvider)
            .read(profile.profileId);
        if (!mounted) return;
        if (saved != null) await showBackupHistoryHelp(context, saved);
        if (mounted) _refresh();
        return;
      case BackupAction.manage:
      case BackupAction.resolve:
        await _open('/sync-profiles/${profile.profileId}');
        return;
      case BackupAction.resume:
        setState(() => _running.add(profile.profileId));
        try {
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(profile.profileId, SyncProfileState.active);
          if (mounted) _refresh();
        } on Object {
          if (mounted) {
            showMessage(
              context,
              syncText(
                context,
                _isVelock ? '暂时无法继续备份，请稍后重试。' : '暂时无法继续同步，请稍后重试。',
                _isVelock
                    ? 'Could not resume the backup. Please try again.'
                    : 'Could not resume the sync. Please try again.',
              ),
            );
          }
        } finally {
          if (mounted) setState(() => _running.remove(profile.profileId));
        }
        return;
      case BackupAction.transfer:
        setState(() => _running.add(profile.profileId));
        try {
          final result = await runSyncWithProgress(
            context,
            ref,
            profile.profileId,
          );
          if (mounted) {
            setState(() => _running.remove(profile.profileId));
            _refresh();
            await presentFirstSyncResult(context, result);
          }
        } on Object catch (error) {
          if (mounted) {
            setState(() => _running.remove(profile.profileId));
            _refresh();
            await presentSyncFailureAlert(context: context, error: error);
          }
        } finally {
          if (mounted) {
            setState(() => _running.remove(profile.profileId));
            _refresh();
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(profilesRevisionProvider, (before, after) {
      if (before != after) _refresh();
    });
    return FutureBuilder<_HomeData>(
      future: _profiles,
      builder: (context, snapshot) => AdaptiveSliverScaffold(
        title: syncText(
          context,
          _isVelock ? '格间备份' : '文件同步',
          _isVelock ? 'Velock backup' : 'File sync',
        ),
        onRefresh: _refreshAndWait,
        actions: [
          AdaptiveIconButton(
            tooltip: syncText(context, '刷新状态', 'Refresh status'),
            onPressed: _refreshAndWait,
            icon: const Icon(CupertinoIcons.refresh),
          ),
        ],
        slivers: _slivers(snapshot),
      ),
    );
  }

  List<Widget> _slivers(AsyncSnapshot<_HomeData> snapshot) {
    if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveLoadingState(
            label: syncText(context, '正在读取状态', 'Loading status'),
          ),
        ),
      ];
    }
    if (snapshot.hasError) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: AdaptiveErrorState(
            message: syncText(
              context,
              '暂时无法读取状态，未改动你的数据。',
              'Could not load the status. Your data has not been changed.',
            ),
            onRetry: _refresh,
          ),
        ),
      ];
    }
    final data = snapshot.requireData;
    return [
      SliverToBoxAdapter(
        child: Column(
          children: [
            const SizedBox(height: 8),
            if (_isVelock) ...[
              if (data.profiles.isEmpty &&
                  isVelockBackupGated(data.availability))
                VelockCompanionGateCard(
                  availability: data.availability!,
                  checking: _rechecking,
                  onOpenVelock: () => openVelockForBackup(context, ref),
                  onRecheck: _recheck,
                )
              else if (data.profiles.isEmpty)
                BackupWelcomeCard(
                  onStart: () => _open(AppRoutes.velockDatasetWizard.path),
                ),
              for (final profile in data.profiles)
                // Details live inside the card, exactly like a plain sync
                // location: a separate row for the same destination was noise.
                BackupStatusCard(
                  name: profile.displayName ?? 'Velock',
                  presentation: _presentation(profile, data),
                  onAction: () =>
                      _action(profile, _presentation(profile, data)),
                  secondaryLabel: syncText(context, '详情', 'Details'),
                  secondaryKey: Key(
                    'velock-backup-details-${profile.profileId}',
                  ),
                  onSecondary: () =>
                      _open('/sync-profiles/${profile.profileId}'),
                ),
              // Restoring needs the same Velock support as backing up.
              if (!(data.profiles.isEmpty &&
                  isVelockBackupGated(data.availability)))
                AdaptiveListSection(
                  children: [
                    AdaptiveListTile(
                      widgetKey: const Key('velock-cloud-restore'),
                      leading: Icon(
                        CupertinoIcons.cloud_download,
                        color: context.appPrimary,
                      ),
                      title: Text(
                        syncText(context, '从云端恢复', 'Restore from cloud'),
                      ),
                      subtitle: Text(
                        syncText(
                          context,
                          '换手机、重装，或找回原来的数据',
                          'A new phone, a reinstall, or your existing data',
                        ),
                      ),
                      showChevron: true,
                      onTap: () => _open(AppRoutes.velockRecovery.path),
                    ),
                  ],
                ),
            ] else ...[
              if (data.profiles.isEmpty)
                BackupCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        CupertinoIcons.folder,
                        color: context.appPrimary,
                        size: 38,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        syncText(
                          context,
                          '同步你的文件夹',
                          'Keep your folders in sync',
                        ),
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        syncText(
                          context,
                          '选择一个文件夹，在设备之间保持一致。它与格间备份相互独立。',
                          'Choose a folder to keep up to date across devices. This is separate from Velock backup.',
                        ),
                      ),
                      const SizedBox(height: 22),
                      BackupActionButton(
                        key: const Key('selected-folder-create'),
                        label: syncText(context, '添加文件夹', 'Add a folder'),
                        onPressed: () =>
                            _open(AppRoutes.selectedFolderProfiles.path),
                      ),
                    ],
                  ),
                ),
              if (data.profiles.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
                  child: Text(
                    syncText(
                      context,
                      '文件夹同步与格间备份是独立任务，状态分别记录。',
                      'Folder sync and Velock backup are separate tasks with independent status.',
                    ),
                    style: TextStyle(color: context.appSecondaryLabel),
                  ),
                ),
                for (final profile in data.profiles) ...[
                  BackupStatusCard(
                    name:
                        profile.displayName ??
                        syncText(context, '同步文件夹', 'Synced folder'),
                    presentation: _presentation(profile, data),
                    isVelock: false,
                    onAction: () =>
                        _action(profile, _presentation(profile, data)),
                  ),
                  AdaptiveListSection(
                    children: [
                      AdaptiveListTile(
                        leading: const Icon(CupertinoIcons.slider_horizontal_3),
                        title: Text(
                          syncText(
                            context,
                            '同步详情与管理',
                            'Sync details and settings',
                          ),
                        ),
                        subtitle: Text(
                          syncText(
                            context,
                            '保存位置、需要处理的事项和详细记录',
                            'Cloud location, items needing attention and history',
                          ),
                        ),
                        showChevron: true,
                        onTap: () =>
                            _open('/sync-profiles/${profile.profileId}'),
                      ),
                    ],
                  ),
                ],
                AdaptiveListSection(
                  children: [
                    AdaptiveListTile(
                      widgetKey: const Key('selected-folder-create'),
                      leading: const Icon(CupertinoIcons.add),
                      title: Text(syncText(context, '添加文件夹', 'Add a folder')),
                      showChevron: true,
                      onTap: () => _open(AppRoutes.selectedFolderProfiles.path),
                    ),
                  ],
                ),
              ],
            ],
            if (data.isolated.isNotEmpty)
              AdaptiveListSection(
                header: syncText(
                  context,
                  '需要检查的旧连接',
                  'Existing connections needing attention',
                ),
                children: [
                  for (final profile in data.isolated)
                    _ProfileTile(summary: profile, onChanged: _refresh),
                ],
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    ];
  }

  BackupPresentation _presentation(SyncProfileSummary p, _HomeData data) =>
      BackupPresentation.from(
        state: p.state,
        locationChangedAt: p.locationChangedAt,
        activity: p.activity,
        availability: data.availability,
        pendingIncoming: data.snapshots[p.profileId]?.pendingIncomingCount ?? 0,
        pendingOutgoing: data.snapshots[p.profileId]?.pendingOutgoingCount ?? 0,
        isolated: p.isIsolated,
        running: _running.contains(p.profileId),
        velockHoldsChanges:
            data.velockStatus?.vaultId == p.vaultId &&
            data.velockStatus?.needsVelock == true,
      );
}

class _HomeData {
  const _HomeData(
    this.profiles,
    this.snapshots,
    this.availability,
    this.isolated, [
    this.velockStatus,
  ]);
  final List<SyncProfileSummary> profiles;
  final Map<String, SyncedDataSnapshot> snapshots;
  final VelockWizardAvailability? availability;
  final List<SyncProfileSummary> isolated;
  final VelockOutboxStatus? velockStatus;
}

class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({required this.summary, required this.onChanged});

  final SyncProfileSummary summary;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title =
        summary.displayName ??
        syncText(context, '不可用的同步配置', "Unavailable sync profile");
    final presentation = profileStatusPresentation(
      context,
      kind: summary.kind,
      state: summary.state,
      isIsolated: summary.isIsolated,
      lastRunFailed: summary.activity?.latestRun?.state == 'failed',
      velockAvailability: null,
    );
    // When the pairing binding is gone the row already states the cause and
    // the next step, so the generic "sync unfinished" line is redundant.
    final failureSubtitle = summary.state == SyncProfileState.accessRequired
        ? null
        : summary.activity?.latestRun?.state == 'failed'
        ? latestRunFailureSubtitle(
            summary.activity?.latestRun,
            context: context,
          )
        : null;
    final baseSubtitle = summary.state == SyncProfileState.accessRequired
        ? syncText(
            context,
            '格间已重置或授权已失效，请移除本配置后重新配对。',
            "Velock was reset or access expired. Remove this profile and pair again.",
          )
        : presentation.detail ??
              profileSecondaryText(summary, context: context);
    final subtitleText = failureSubtitle == null
        ? baseSubtitle
        : '$baseSubtitle，$failureSubtitle';

    return Semantics(
      label: '$title，$subtitleText，${presentation.label}',
      child: AdaptiveListTile(
        leading: AdaptiveIconBadge(
          icon: adaptiveKindIcon(context, summary.kind),
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
          tooltip: syncText(context, '同步配置操作', "Sync profile actions"),
          onSelected: (action) => _runAction(context, ref, action),
          items: [
            if (summary.isRunnable && !summary.isIsolated)
              AdaptiveActionItem(
                value: _ProfileAction.syncNow,
                label: syncText(context, '立即同步', "Sync now"),
                icon: CupertinoIcons.arrow_2_circlepath,
              ),
            if (summary.state == SyncProfileState.active)
              AdaptiveActionItem(
                value: _ProfileAction.pause,
                label: syncText(context, '暂停', "Pause"),
                icon: CupertinoIcons.pause,
              ),
            if (summary.state == SyncProfileState.paused)
              AdaptiveActionItem(
                value: _ProfileAction.resume,
                label: syncText(context, '恢复', "Resume"),
                icon: CupertinoIcons.play,
              ),
            AdaptiveActionItem(
              value: _ProfileAction.remove,
              label: syncText(context, '删除同步配置', "Delete sync profile"),
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
          final result = await runSyncWithProgress(
            context,
            ref,
            summary.profileId,
          );
          if (!context.mounted || result == null) return;
          onChanged();
          await presentSyncResult(context, result);
        case _ProfileAction.pause:
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(summary.profileId, SyncProfileState.paused);
        case _ProfileAction.resume:
          await ref
              .read(syncProfileRepositoryProvider)
              .setState(summary.profileId, SyncProfileState.active);
        case _ProfileAction.remove:
          if (!await confirmSyncProfileRemoval(
            context,
            summary.displayName ??
                syncText(context, '不可用的同步配置', "Unavailable sync profile"),
          )) {
            return;
          }
          await ref
              .read(syncProfileRepositoryProvider)
              .remove(summary.profileId);
      }
      onChanged();
    } on SyncProfileRemovalWhileRunningException {
      if (context.mounted) {
        showMessage(
          context,
          syncText(
            context,
            '同步正在运行，暂时无法删除。',
            "Sync is running. The profile cannot be deleted yet.",
          ),
        );
      }
    } on Object catch (error) {
      if (context.mounted) {
        if (action == _ProfileAction.syncNow) {
          onChanged();
          await presentSyncFailureAlert(context: context, error: error);
          return;
        }
        showMessage(
          context,
          syncText(
            context,
            '操作未完成，请稍后重试。',
            "Could not complete the action. Please try again later.",
          ),
        );
      }
    }
  }
}

/// Label, tone and optional detail for a profile's status pill.
///
/// Label and colour always come from the same source, so a healthy profile can

enum _ProfileAction { syncNow, pause, resume, remove }
