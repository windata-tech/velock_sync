/// Sync-profile detail page: overview, pending, history, conflicts, and
/// per-profile settings tabs.
library;

import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_actions.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_history_help.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'dart:async';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/widgets/app_format.dart';
import 'sync_profile_workspace_shared.dart';
import 'sync_profile_providers.dart';

class SyncProfileDetail extends ConsumerStatefulWidget {
  const SyncProfileDetail({super.key, required this.profileId});

  final String profileId;

  @override
  ConsumerState<SyncProfileDetail> createState() => _SyncProfileDetailState();
}

class _SyncProfileDetailState extends ConsumerState<SyncProfileDetail> {
  late Future<DetailData> _data;
  SyncDatasetKind? _kind;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<DetailData> _load() async {
    final database = ref.read(syncStateDatabaseProvider);
    final profile = await ref
        .read(syncProfileRepositoryProvider)
        .read(widget.profileId);
    _kind = profile?.kind;
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
    return DetailData(
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

  void _leaveDetail() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).maybePop();
    } else {
      // A wizard/deep link may have replaced the entire stack. A detail page
      // must still lead back to the correct product's tabbed home.
      GoRouter.of(
        context,
      ).go(_kind == SyncDatasetKind.selectedFolder ? '/files' : '/');
    }
  }

  Widget _detailScaffold({
    required String title,
    required Widget body,
    List<Widget> actions = const [],
  }) {
    final canPop = ModalRoute.of(context)?.canPop == true;
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !canPop) _leaveDetail();
      },
      child: AdaptiveScaffold(
        title: title,
        leading: AppBackButton(onPressed: _leaveDetail),
        actions: actions,
        body: body,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<DetailData>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return _detailScaffold(
          title: syncText(context, '连接详情', 'Connection details'),
          body: AdaptiveLoadingState(
            label: syncText(context, '正在读取状态', 'Loading status'),
          ),
        );
      }
      if (snapshot.hasError) {
        return _detailScaffold(
          title: syncText(context, '连接详情', 'Connection details'),
          body: RetryState(
            onRetry: _refresh,
            message: syncText(
              context,
              '暂时无法读取状态，请重试。',
              'Could not load the status. Please retry.',
            ),
          ),
        );
      }
      final data = snapshot.requireData;
      final profile = data.profile;
      if (profile == null) {
        return _detailScaffold(
          title: syncText(context, '连接详情', 'Connection details'),
          body: Center(
            child: Text(
              syncText(
                context,
                '这个连接已不存在。',
                'This connection no longer exists.',
              ),
            ),
          ),
        );
      }
      Future<void> openPage(String title, Widget page) async {
        await Navigator.of(context).push<void>(
          isApplePlatform(context)
              ? CupertinoPageRoute(
                  builder: (context) => AdaptiveScaffold(
                    title: title,
                    body: _DetailMaterialSurface(child: page),
                  ),
                )
              : MaterialPageRoute(
                  builder: (context) =>
                      AdaptiveScaffold(title: title, body: page),
                ),
        );
        if (mounted) _refresh();
      }

      return _detailScaffold(
        title: profile.kind == SyncDatasetKind.velockManaged
            ? syncText(context, '格间备份', 'Velock backup')
            : profile.displayName,
        actions: [
          AdaptiveIconButton(
            tooltip: syncText(context, '刷新', 'Refresh'),
            icon: const Icon(CupertinoIcons.refresh),
            onPressed: _refresh,
          ),
        ],
        body: _DetailMaterialSurface(
          child: _OverviewTab(
            profile: profile,
            latestRun: data.latestRun,
            synced: data.synced,
            history: data.history,
            velockAvailability: data.velockAvailability,
            onChanged: _refresh,
            conflicts: data.conflicts,
            onPending: () => openPage(
              syncText(context, '等待传输', 'Pending transfers'),
              _PendingTab(transfers: data.transfers),
            ),
            onHistory: () => openPage(
              syncText(context, '传输记录', 'Transfer history'),
              _HistoryTab(runs: data.runs, history: data.history),
            ),
            onConflicts: () => openPage(
              syncText(context, '需要选择的内容', 'Review changes'),
              _ConflictsTab(conflicts: data.conflicts),
            ),
            onSettings: () => openPage(
              syncText(context, '管理', 'Manage'),
              _ProfileSettingsTab(profile: profile, onChanged: _refresh),
            ),
            onDiagnostics: () => openPage(
              syncText(context, '详细记录与诊断', 'Details and diagnostics'),
              ListView(
                children: [
                  SyncedDataSection(
                    snapshot: data.synced,
                    profile: profile,
                    history: data.history,
                  ),
                ],
              ),
            ),
          ),
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
    required this.conflicts,
    required this.onPending,
    required this.onHistory,
    required this.onConflicts,
    required this.onSettings,
    required this.onDiagnostics,
  });
  final SyncProfileEnvelope profile;
  final SyncRunRecord? latestRun;
  final SyncedDataSnapshot synced;
  final List<TransferJobRecord> history;
  final VelockWizardAvailability? velockAvailability;
  final VoidCallback onChanged,
      onPending,
      onHistory,
      onConflicts,
      onSettings,
      onDiagnostics;
  final List<SyncConflictRecord> conflicts;
  @override
  ConsumerState<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends ConsumerState<_OverviewTab> {
  bool _running = false;
  bool get _isVelock => widget.profile.kind == SyncDatasetKind.velockManaged;
  BackupPresentation get _presentation => BackupPresentation.from(
    state: widget.profile.state,
    running: _running,
    availability: widget.velockAvailability,
    pendingIncoming: widget.synced.pendingIncomingCount,
    pendingOutgoing: widget.synced.pendingOutgoingCount,
    activity: SyncProfileActivitySummary(
      latestRun: widget.latestRun,
      pendingUploadCount: widget.synced.pendingUploadCount,
      pendingDownloadCount: widget.synced.pendingDownloadCount,
      transferredBytes: widget.synced.totalBytes,
      unresolvedConflictCount: widget.conflicts.length,
    ),
  );

  Future<void> _runNow() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      final result = await runSyncWithProgress(
        context,
        ref,
        widget.profile.profileId,
      );
      if (mounted) await presentFirstSyncResult(context, result);
    } on Object catch (error) {
      if (mounted) {
        showMessage(
          context,
          backupFailureMessage(
            context,
            SyncFailureClassifier.classify(error).errorCode,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
        widget.onChanged();
      }
    }
  }

  Future<void> _toggleState() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      await ref
          .read(syncProfileRepositoryProvider)
          .setState(
            widget.profile.profileId,
            widget.profile.state == SyncProfileState.paused
                ? SyncProfileState.active
                : SyncProfileState.paused,
          );
      if (mounted) widget.onChanged();
    } on Object {
      if (mounted) {
        showMessage(
          context,
          syncText(
            context,
            '操作未完成，请重试。',
            'Could not finish. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _primaryAction() async {
    switch (_presentation.action) {
      case BackupAction.transfer:
        await _runNow();
      case BackupAction.openVelock:
        await openVelockForBackup(context, ref);
      case BackupAction.resume:
        await _toggleState();
      case BackupAction.resolve:
        widget.onConflicts();
      case BackupAction.manage:
        widget.onSettings();
      case BackupAction.reviewHistory:
        await showBackupHistoryHelp(context, widget.profile);
        if (mounted) widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending =
        widget.synced.pendingUploadCount + widget.synced.pendingDownloadCount;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        BackupStatusCard(
          name: widget.profile.displayName,
          presentation: _presentation,
          isVelock: _isVelock,
          onAction: _primaryAction,
        ),
        if (widget.conflicts.isNotEmpty)
          AdaptiveListSection(
            children: [
              AdaptiveListTile(
                widgetKey: const Key('backup-conflicts'),
                leading: const Icon(CupertinoIcons.exclamationmark_triangle),
                title: Text(
                  syncText(
                    context,
                    '${widget.conflicts.length} 项内容需要你选择',
                    '${widget.conflicts.length} changes need review',
                  ),
                ),
                subtitle: Text(
                  syncText(
                    context,
                    '两台设备修改了同一内容，不会静默覆盖。',
                    'Edited on two devices. Nothing is silently overwritten.',
                  ),
                ),
                showChevron: true,
                onTap: widget.onConflicts,
              ),
            ],
          ),
        AdaptiveListSection(
          children: [
            _BackupLocationTile(connectionId: widget.profile.connectionId),
            AdaptiveListTile(
              leading: const Icon(CupertinoIcons.clock),
              title: Text(syncText(context, '传输记录', 'Transfer history')),
              subtitle: Text(
                widget.latestRun == null
                    ? syncText(context, '尚未传输', 'No transfers yet')
                    : '${runStateLabel(widget.latestRun!.state, context: context)} · ${AppFormat.stamp(widget.latestRun!.completedAt ?? widget.latestRun!.startedAt)}',
              ),
              showChevron: true,
              onTap: widget.onHistory,
            ),
            if (pending > 0)
              AdaptiveListTile(
                title: Text(
                  syncText(context, '查看等待传输的内容', 'View pending transfers'),
                ),
                showChevron: true,
                onTap: widget.onPending,
              ),
            AdaptiveListTile(
              leading: const Icon(CupertinoIcons.slider_horizontal_3),
              title: Text(syncText(context, '管理', 'Manage')),
              subtitle: Text(
                syncText(
                  context,
                  '自动传输、网络和连接',
                  'Automatic transfers, network and connection',
                ),
              ),
              showChevron: true,
              onTap: widget.onSettings,
            ),
          ],
        ),
        if (_isVelock)
          AdaptiveListSection(
            children: [
              AdaptiveListTile(
                leading: const Icon(CupertinoIcons.lock_shield),
                title: Text(
                  syncText(
                    context,
                    '恢复卡与已授权设备',
                    'Recovery card and authorized devices',
                  ),
                ),
                subtitle: Text(
                  syncText(context, '在格间中安全管理', 'Manage securely in Velock'),
                ),
                showChevron: true,
                onTap: () => openVelockBackupSettings(context, ref),
              ),
            ],
          ),
        if (widget.profile.state == SyncProfileState.active ||
            widget.profile.state == SyncProfileState.paused)
          AdaptiveListSection(
            footer: Text(
              syncText(
                context,
                '暂停不会删除本机或云端的数据。',
                'Pausing does not delete local or cloud data.',
              ),
            ),
            children: [
              AdaptiveListTile(
                title: Text(
                  syncText(
                    context,
                    widget.profile.state == SyncProfileState.paused
                        ? '继续传输'
                        : '暂停传输',
                    widget.profile.state == SyncProfileState.paused
                        ? 'Resume transfers'
                        : 'Pause transfers',
                  ),
                ),
                enabled: !_running,
                onTap: _toggleState,
              ),
            ],
          ),
        AdaptiveListSection(
          children: [
            AdaptiveListTile(
              widgetKey: const Key('backup-diagnostics'),
              title: Text(
                syncText(context, '详细记录与诊断', 'Details and diagnostics'),
              ),
              subtitle: Text(
                syncText(
                  context,
                  '仅在排查问题时需要',
                  'Only needed for troubleshooting',
                ),
              ),
              showChevron: true,
              onTap: widget.onDiagnostics,
            ),
          ],
        ),
      ],
    );
  }
}

class _BackupLocationTile extends ConsumerWidget {
  const _BackupLocationTile({required this.connectionId});
  final String connectionId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => AdaptiveListTile(
    leading: const Icon(CupertinoIcons.cloud),
    title: Text(syncText(context, '云端保存位置', 'Cloud location')),
    subtitle: Text(
      syncText(context, '查看当前账号和文件夹', 'View the account and folder'),
    ),
    showChevron: true,
    onTap: () => context.push('/connections/connection/$connectionId'),
  );
}

class _PendingTab extends StatelessWidget {
  const _PendingTab({required this.transfers});
  final List<TransferJobRecord> transfers;

  @override
  Widget build(BuildContext context) => transfers.isEmpty
      ? AdaptiveEmptyState(
          icon: CupertinoIcons.tray_arrow_down,
          tone: AppTone.ok,
          title: syncText(context, '没有待处理传输', "No pending transfers"),
          message: syncText(
            context,
            '所有传输都已完成。新的上传和下载任务启动时会显示在这里。',
            "All transfers are complete. New uploads and downloads will appear here when they start.",
          ),
        )
      : ListView(
          padding: const EdgeInsets.only(
            top: AppSpacing.sm,
            bottom: AppSpacing.xl,
          ),
          children: [
            AdaptiveListSection(
              header: syncText(context, '待恢复传输', "Recoverable transfers"),
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
                      syncText(
                        context,
                        '${transfer.direction == TransferJobDirection.upload ? '上传' : '下载'} · ${transferStateLabel(transfer.state, context: context)}',
                        "${transfer.direction == TransferJobDirection.upload ? 'Upload' : 'Download'} · ${transferStateLabel(transfer.state, context: context)}",
                      ),
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
      ? AdaptiveEmptyState(
          icon: CupertinoIcons.clock,
          title: syncText(context, '尚无同步历史', "No sync history"),
          message: syncText(
            context,
            '完成第一次同步后，运行记录会显示在这里。',
            "Run records will appear here after the first sync.",
          ),
        )
      : ListView(
          padding: const EdgeInsets.only(
            top: AppSpacing.sm,
            bottom: AppSpacing.xl,
          ),
          children: [
            AdaptiveListSection(
              header: syncText(context, '同步历史', "Sync history"),
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
                        title: Text(runStateLabel(run.state, context: context)),
                        subtitle: Text(
                          AppFormat.relativeTime(
                            run.completedAt ?? run.startedAt,
                            context: context,
                          ),
                          maxLines: 2,
                        ),
                        showChevron: true,
                        onTap: () =>
                            showRunDetails(context, run, history: history),
                      );
                    },
                  ),
              ],
            ),
          ],
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
          title: syncText(context, '没有待处理冲突', "No pending conflicts"),
          message: syncText(
            context,
            '同一对象在两台设备上被同时修改时，冲突会出现在这里，并可在活动页选择处理方式。',
            "Conflicts appear when the same object is edited on two devices. Resolve them on the Activity page.",
          ),
          secondaryAction: AppSecondaryButton(
            label: syncText(context, '前往活动页', "Go to Activity"),
            onPressed: () => context.push('/activity'),
          ),
        )
      : ListView(
          padding: const EdgeInsets.only(
            top: AppSpacing.sm,
            bottom: AppSpacing.xl,
          ),
          children: [
            AdaptiveListSection(
              header: syncText(context, '待处理冲突', "Pending conflicts"),
              children: [
                for (final conflict in conflicts)
                  AdaptiveListTile(
                    leading: AdaptiveIconBadge(
                      icon: CupertinoIcons.exclamationmark_triangle,
                      color: AppColors.warning,
                    ),
                    title: Text(conflictLabel(conflict.type, context: context)),
                    subtitle: Text(
                      syncText(
                        context,
                        '对象 ${shortId(conflict.entityId)} · ${formatTime(conflict.createdAt)}',
                        "Object ${shortId(conflict.entityId)} · ${formatTime(conflict.createdAt)}",
                      ),
                    ),
                    trailing: isApplePlatform(context)
                        ? CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: () => context.push('/activity'),
                            child: Text(syncText(context, '处理', "Resolve")),
                          )
                        : TextButton(
                            onPressed: () => context.push('/activity'),
                            child: Text(syncText(context, '处理', "Resolve")),
                          ),
                  ),
              ],
            ),
          ],
        );
}

class _ProfileSettingsTab extends ConsumerStatefulWidget {
  const _ProfileSettingsTab({required this.profile, required this.onChanged});
  final SyncProfileEnvelope profile;
  final VoidCallback onChanged;
  @override
  ConsumerState<_ProfileSettingsTab> createState() =>
      _ProfileSettingsTabState();
}

class _ProfileSettingsTabState extends ConsumerState<_ProfileSettingsTab> {
  late SyncProfileEnvelope profile = widget.profile;
  bool _saving = false;
  void onChanged() => widget.onChanged();
  Future<void> _reconnect() async {
    if (!await showAdaptiveConfirmation(
          context,
          title: syncText(context, '重新连接格间？', 'Reconnect Velock?'),
          message: syncText(
            context,
            '将停止使用本机旧授权，再请格间重新允许连接。不会删除格间或云端的数据，请继续使用原来的云端位置。',
            'Stop using the old authorization and ask Velock to allow access again. No Velock or cloud data is deleted. Continue using the original cloud location.',
          ),
          confirmLabel: syncText(context, '重新连接', 'Reconnect'),
        ) ||
        !mounted) {
      return;
    }
    try {
      await ref.read(syncProfileRepositoryProvider).remove(profile.profileId);
      if (!mounted) return;
      ref.read(profilesRevisionProvider.notifier).bump();
      context.go('/sync-profiles/new/velock');
    } on Object {
      if (mounted) {
        showMessage(
          context,
          syncText(
            context,
            '当前连接正在使用或暂时无法更新，请稍后重试。',
            'The connection is busy or could not be updated. Try again later.',
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xl),
    children: [
      if (profile.kind == SyncDatasetKind.velockManaged)
        AdaptiveListSection(
          children: [
            _BackupLocationTile(connectionId: profile.connectionId),
            AdaptiveListTile(
              title: Text(syncText(context, '重新连接格间', 'Reconnect Velock')),
              subtitle: Text(
                syncText(
                  context,
                  '重装或授权失效后使用，不删除云端数据',
                  'Use after a reinstall or expired access. Cloud data stays.',
                ),
              ),
              showChevron: true,
              onTap: _saving ? null : _reconnect,
            ),
          ],
        ),
      if (profile.kind == SyncDatasetKind.selectedFolder)
        AdaptiveListSection(
          header: syncText(context, '恢复与安全', "Recovery & Security"),
          footer: Text(
            syncText(
              context,
              '恢复包用于在另一台设备重新加入这个同步空间。恢复包和口令应通过不同渠道保存。',
              "A recovery package lets another device rejoin this sync space. Keep the package and passphrase in separate secure locations.",
            ),
          ),
          children: [
            Semantics(
              button: true,
              label: syncText(context, '生成恢复包', "Create recovery package"),
              onTap: () => exportSelectedFolderRecovery(context, ref, profile),
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
                title: Text(
                  syncText(context, '生成恢复包', "Create recovery package"),
                ),
                subtitle: Text(
                  syncText(
                    context,
                    '创建带恢复口令的一次性凭据。',
                    "Create a one-time credential protected by a recovery passphrase.",
                  ),
                ),
                showChevron: true,
                onTap: () =>
                    exportSelectedFolderRecovery(context, ref, profile),
              ),
            ),
          ],
        ),
      AdaptiveListSection(
        header: syncText(context, '后台策略', "Background policy"),
        children: [
          AdaptiveSwitchListTile(
            title: Text(syncText(context, '后台同步', "Background sync")),
            subtitle: Text(
              syncText(
                context,
                '仅在系统允许且配置处于活动状态时运行。',
                "Runs only when the system allows it and the profile is active.",
              ),
            ),
            value: profile.backgroundPolicy.enabled,
            onChanged: (value) =>
                _save(ref, profile.backgroundPolicy.copyWith(enabled: value)),
          ),
          AdaptiveSwitchListTile(
            title: Text(syncText(context, '允许蜂窝网络', "Allow cellular data")),
            value: profile.backgroundPolicy.allowCellular,
            onChanged: profile.backgroundPolicy.enabled
                ? (value) => _save(
                    ref,
                    profile.backgroundPolicy.copyWith(allowCellular: value),
                  )
                : null,
          ),
          AdaptiveSwitchListTile(
            title: Text(syncText(context, '仅充电时运行', "Only while charging")),
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
        header: syncText(context, '危险操作', "Danger zone"),
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
              syncText(context, '断开此连接', "Disconnect"),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: Text(
              syncText(
                context,
                '不会删除远端数据或安全存储中的凭据。',
                "Remote data and credentials in secure storage will not be deleted.",
              ),
            ),
            onTap: () async {
              final confirmed = await showAdaptiveConfirmation(
                context,
                title: syncText(
                  context,
                  '断开此连接？',
                  'Disconnect this connection?',
                ),
                message: syncText(
                  context,
                  '停止这台设备通过此连接传输。不会删除本机内容或云端备份。',
                  'Stop transfers on this device through this connection. Local content and cloud backups will not be deleted.',
                ),
                confirmLabel: syncText(context, '断开', 'Disconnect'),
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
                context.go(
                  profile.kind == SyncDatasetKind.velockManaged
                      ? '/dashboard'
                      : '/files',
                );
              } on SyncProfileRemovalWhileRunningException {
                if (context.mounted) {
                  showMessage(
                    context,
                    syncText(
                      context,
                      '同步正在运行，暂时无法移除。',
                      "Sync is running. The profile cannot be removed yet.",
                    ),
                  );
                }
              } on Object {
                if (context.mounted) {
                  showMessage(
                    context,
                    syncText(
                      context,
                      '移除失败，请稍后重试。',
                      "Could not remove the profile. Try again later.",
                    ),
                  );
                }
              }
            },
          ),
        ],
      ),
    ],
  );

  Future<void> _save(WidgetRef ref, SyncProfileBackgroundPolicy policy) async {
    if (_saving) return;
    setState(() => _saving = true);
    final updated = profile.copyWith(backgroundPolicy: policy);
    try {
      await ref.read(syncProfileRepositoryProvider).save(updated);
      if (mounted) {
        setState(() => profile = updated);
        onChanged();
      }
    } on Object {
      if (mounted) {
        showMessage(
          context,
          syncText(
            context,
            '未能保存设置，请重试。',
            'Could not save settings. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
