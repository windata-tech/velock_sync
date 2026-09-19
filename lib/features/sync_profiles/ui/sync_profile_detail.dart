/// Sync-profile detail page: overview, pending, history, conflicts, and
/// per-profile settings tabs.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
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
  int _selectedTab = 0;

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

  @override
  Widget build(BuildContext context) => FutureBuilder<DetailData>(
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
          body: RetryState(onRetry: _refresh, message: '无法读取同步配置详情。'),
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
      await presentSyncResult(context, result);
    } on Object catch (error, stackTrace) {
      final code = error is SyncFailureException
          ? error.syncFailure.errorCode
          : error.runtimeType.toString();
      logw('Sync profile action failed: $code', stackTrace: stackTrace);
      if (!mounted) return;
      showMessage(context, '同步失败：${AppFormat.errorSummary(code)}');
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
    final presentation = profileStatusPresentation(
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
        : '${runStateLabel(latestRun.state)} · '
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
          VelockConnectionBanner(
            availability: widget.velockAvailability!,
            onRetry: widget.onChanged,
          ),
        _ProfileSummaryCard(
          title: widget.profile.displayName,
          subtitle: widget.profile.kind == SyncDatasetKind.velockManaged
              ? '格间已加密数据的零知识远程备份'
              : '用户选择文件夹的加密双向同步',
          icon: adaptiveKindIcon(context, widget.profile.kind),
          presentation: presentation,
          datasetLabel: kindLabel(widget.profile.kind),
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
              message: latestRunFailureSubtitle(latestRun),
            ),
          ),
        SyncedDataSection(
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
  final ProfileStatusPresentation presentation;
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
                      '${transfer.direction == TransferJobDirection.upload ? '上传' : '下载'} · ${transferStateLabel(transfer.state)}',
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
                        title: Text(runStateLabel(run.state)),
                        subtitle: Text(
                          AppFormat.relativeTime(
                            run.completedAt ?? run.startedAt,
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
                    title: Text(conflictLabel(conflict.type)),
                    subtitle: Text(
                      '对象 ${shortId(conflict.entityId)} · ${formatTime(conflict.createdAt)}',
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
                title: const Text('生成恢复包'),
                subtitle: const Text('创建带恢复口令的一次性凭据。'),
                showChevron: true,
                onTap: () =>
                    exportSelectedFolderRecovery(context, ref, profile),
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
                if (context.mounted) showMessage(context, '同步正在运行，暂时无法移除。');
              } on Object {
                if (context.mounted) showMessage(context, '移除失败，请稍后重试。');
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
