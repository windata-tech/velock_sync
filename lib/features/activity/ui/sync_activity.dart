import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_service.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_strategy.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'package:velock_sync/widgets/app_format.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

/// Privacy-safe activity and conflict centre. Object IDs are opaque protocol
/// identifiers; names and file paths remain outside the activity database.
class SyncActivity extends HookConsumerWidget {
  const SyncActivity({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final revision = useState(0);
    final database = ref.read(syncStateDatabaseProvider);
    final profiles = ref.read(syncProfileRepositoryProvider);
    final resolutionService = ref.read(conflictResolutionServiceProvider);
    final activity = useMemoized(() => _loadActivity(database, profiles), [
      revision.value,
    ]);

    Future<void> resolve(
      BuildContext messageContext,
      SyncConflictRecord conflict,
      ConflictResolutionStrategy strategy,
    ) async {
      // Built lazily so the locale is only read while the page is still
      // mounted, exactly like the message itself.
      var message = () => syncText(
        messageContext,
        '无法完成冲突解决。',
        'Could not resolve the conflict.',
      );
      try {
        final result = await resolutionService.resolve(
          conflictId: conflict.conflictId,
          strategy: strategy,
        );
        if (result.status == ConflictResolutionStatus.completed ||
            result.status == ConflictResolutionStatus.alreadyCompleted) {
          revision.value++;
          return;
        }
        if (result.errorCode == 'velock-resolution-pending') {
          message = () => syncText(
            messageContext,
            '已打开 Velock；处理完成后回到这里再次选择“在 Velock 中处理”。',
            'Velock is open. When it finishes, come back here and choose “Open in Velock” again.',
          );
        } else if (result.errorCode == 'untrusted-velock-receipt') {
          message = () => syncText(
            messageContext,
            'Velock 返回结果未通过验证，冲突仍保持未解决。',
            'The result from Velock failed validation, so the conflict is still unresolved.',
          );
        }
      } on Object {
        // Resolution service failures are deliberately reduced to the same
        // generic UI state as non-completion results below.
      }
      if (messageContext.mounted) {
        showPlatformMessage(messageContext, message());
      }
    }

    Future<void> refresh() async {
      revision.value++;
      await _loadActivity(database, profiles);
    }

    return Material(
      type: MaterialType.transparency,
      child: ScaffoldMessenger(
        child: FutureBuilder<_ActivityData>(
          future: activity,
          builder: (context, snapshot) => AdaptiveSliverScaffold(
            title: syncText(context, '活动', 'Activity'),
            actions: [
              AdaptiveIconButton(
                tooltip: syncText(context, '刷新活动记录', 'Refresh activity'),
                onPressed: refresh,
                icon: Icon(
                  adaptiveIcon(
                    context,
                    material: Icons.refresh_rounded,
                    cupertino: CupertinoIcons.refresh,
                  ),
                ),
              ),
            ],
            slivers: _activitySlivers(
              context,
              snapshot,
              onRetry: refresh,
              onResolve: resolve,
            ),
          ),
        ),
      ),
    );
  }
}

List<Widget> _activitySlivers(
  BuildContext context,
  AsyncSnapshot<_ActivityData> snapshot, {
  required VoidCallback onRetry,
  required Future<void> Function(
    BuildContext context,
    SyncConflictRecord conflict,
    ConflictResolutionStrategy strategy,
  )
  onResolve,
}) {
  if (snapshot.connectionState != ConnectionState.done) {
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: AdaptiveLoadingState(
          label: syncText(context, '正在加载活动记录', 'Loading activity'),
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
            '无法读取活动记录。',
            'Could not read the activity record.',
          ),
          onRetry: onRetry,
        ),
      ),
    ];
  }
  final values = snapshot.requireData;
  if (values.runs.isEmpty &&
      values.transfers.isEmpty &&
      values.conflicts.isEmpty) {
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: AdaptiveEmptyState(
          icon: adaptiveIcon(
            context,
            material: Icons.history_rounded,
            cupertino: CupertinoIcons.clock,
          ),
          title: syncText(context, '还没有同步活动', 'No sync activity yet'),
          message: syncText(
            context,
            '同步运行、待恢复传输和需要处理的冲突会集中显示在这里。',
            'Sync runs, transfers waiting to resume and conflicts that need attention all appear here.',
          ),
        ),
      ),
    ];
  }

  return [
    SliverToBoxAdapter(child: _ActivityOverview(values: values)),
    if (values.runs.isNotEmpty)
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '最近同步', 'Recent syncs'),
          children: [
            for (final run in values.runs)
              Builder(
                builder: (context) {
                  final failed = run.state == 'failed';
                  return AdaptiveListTile(
                    leading: AdaptiveIconBadge(
                      icon: failed
                          ? CupertinoIcons.exclamationmark_circle
                          : CupertinoIcons.check_mark,
                      color: failed
                          ? AppTone.danger.color(context)
                          : AppTone.ok.color(context),
                    ),
                    title: Text(
                      failed
                          ? syncText(context, '同步失败', 'Sync failed')
                          : syncText(context, '同步完成', 'Sync completed'),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${values.nameFor(context, run.profileId)} · '
                          '${AppFormat.relativeTime(run.completedAt ?? run.startedAt, context: context)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.rowSubtitle.copyWith(
                            color: context.appSecondaryLabel,
                          ),
                        ),
                        if (failed)
                          // The reason must stay readable at both lengths, so
                          // it wraps instead of being shortened with an
                          // ellipsis.
                          Text(
                            AppFormat.errorSummary(
                              run.errorCode,
                              context: context,
                            ),
                            maxLines: 2,
                            style: AppType.rowSubtitle.copyWith(
                              color: AppTone.danger.color(context),
                            ),
                          ),
                      ],
                    ),
                    showChevron: true,
                    onTap: () => _showActivityRunDetails(context, run, values),
                  );
                },
              ),
          ],
        ),
      ),
    if (values.transfers.isNotEmpty)
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: syncText(context, '待恢复传输', 'Transfers to resume'),
          children: [
            for (final transfer in values.transfers)
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: transfer.direction == TransferJobDirection.upload
                      ? CupertinoIcons.arrow_up
                      : CupertinoIcons.arrow_down,
                  color: AppTone.brand.color(context),
                ),
                title: Text(_transferTitle(context, transfer)),
                subtitle: Text(
                  '${values.nameFor(context, transfer.profileId)} · ${_transferProgress(context, transfer)}'
                  '${transfer.errorCode == null ? '' : ' · ${AppFormat.errorSummary(transfer.errorCode, context: context)}'}',
                  maxLines: 2,
                ),
              ),
          ],
        ),
      ),
    SliverToBoxAdapter(
      child: AdaptiveListSection(
        header: syncText(context, '待处理冲突', 'Conflicts to review'),
        children: values.conflicts.isEmpty
            ? [
                AdaptiveListTile(
                  leading: AdaptiveIconBadge(
                    icon: adaptiveIcon(
                      context,
                      material: Icons.check_rounded,
                      cupertino: CupertinoIcons.check_mark,
                    ),
                    color: AppColors.success,
                  ),
                  title: Text(
                    syncText(
                      context,
                      '没有待处理冲突。',
                      'No conflicts need attention.',
                    ),
                  ),
                ),
              ]
            : [
                for (final conflict in values.conflicts)
                  AdaptiveListTile(
                    leading: AdaptiveIconBadge(
                      icon: adaptiveIcon(
                        context,
                        material: Icons.warning_amber_rounded,
                        cupertino: CupertinoIcons.exclamationmark_triangle,
                      ),
                      color: AppColors.warning,
                    ),
                    title: Text(_conflictType(context, conflict.type)),
                    subtitle: Text(
                      '${values.nameFor(context, conflict.profileId)} · '
                      '${AppFormat.relativeTime(conflict.createdAt, context: context)}',
                      maxLines: 2,
                    ),
                    trailing: _ConflictResolutionActions(
                      kind: values.kindFor(conflict.profileId),
                      onSelected: (strategy) =>
                          onResolve(context, conflict, strategy),
                    ),
                  ),
              ],
      ),
    ),
  ];
}

class _ActivityOverview extends StatelessWidget {
  const _ActivityOverview({required this.values});

  final _ActivityData values;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.page,
      AppSpacing.sm,
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
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AdaptiveIconBadge(
                  icon: CupertinoIcons.chart_bar,
                  color: AppTone.brand.color(context),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    syncText(
                      context,
                      '同步记录与待处理项',
                      'Sync history and open items',
                    ),
                    style: AppType.rowTitleStrong,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppMetricGrid(
              metrics: [
                AppMetric(
                  value: '${values.runs.length}',
                  label: syncText(context, '最近运行', 'Recent runs'),
                ),
                AppMetric(
                  value: '${values.transfers.length}',
                  label: syncText(context, '待恢复', 'To resume'),
                  tone: values.transfers.isEmpty
                      ? AppTone.neutral
                      : AppTone.attention,
                ),
                AppMetric(
                  value: '${values.conflicts.length}',
                  label: syncText(context, '冲突', 'Conflicts'),
                  tone: values.conflicts.isEmpty
                      ? AppTone.neutral
                      : AppTone.danger,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Future<_ActivityData> _loadActivity(
  SyncStateDatabase database,
  SyncProfileRepository profiles,
) async {
  final result = await Future.wait<Object>([
    database.listRecentSyncRuns(),
    database.listTransferJobs(),
    database.listUnresolvedConflicts(),
  ]);
  final conflicts = result[2] as List<SyncConflictRecord>;
  final kindsByProfileId = <String, SyncDatasetKind?>{};
  final namesByProfileId = <String, String>{};
  final involvedProfileIds = <String>{
    ...conflicts.map((conflict) => conflict.profileId),
    ...(result[0] as List<SyncRunRecord>).map((run) => run.profileId),
    ...(result[1] as List<TransferJobRecord>).map(
      (transfer) => transfer.profileId,
    ),
  };
  for (final profileId in involvedProfileIds) {
    try {
      final profile = await profiles.read(profileId);
      kindsByProfileId[profileId] = profile?.kind;
      final name = profile?.displayName.trim();
      if (name != null && name.isNotEmpty) {
        namesByProfileId[profileId] = name;
      }
    } on Object {
      // A missing, malformed, or unsupported profile has no safe generic
      // resolution action. In particular, do not inspect protected details.
      kindsByProfileId[profileId] = null;
    }
  }
  return _ActivityData(
    runs: result[0] as List<SyncRunRecord>,
    transfers: result[1] as List<TransferJobRecord>,
    conflicts: conflicts,
    kindsByProfileId: kindsByProfileId,
    namesByProfileId: namesByProfileId,
  );
}

class _ActivityData {
  const _ActivityData({
    required this.runs,
    required this.transfers,
    required this.conflicts,
    required this.kindsByProfileId,
    required this.namesByProfileId,
  });

  final List<SyncRunRecord> runs;
  final List<TransferJobRecord> transfers;
  final List<SyncConflictRecord> conflicts;
  final Map<String, SyncDatasetKind?> kindsByProfileId;
  final Map<String, String> namesByProfileId;

  SyncDatasetKind? kindFor(String profileId) => kindsByProfileId[profileId];

  /// Human name for a profile. Never falls back to a raw identifier: users
  /// should not have to read `70fa13b9-238…` to follow an activity entry.
  String nameFor(BuildContext context, String profileId) =>
      namesByProfileId[profileId] ?? syncText(context, '同步配置', 'Sync profile');
}

class _ConflictResolutionActions extends StatelessWidget {
  const _ConflictResolutionActions({
    required this.kind,
    required this.onSelected,
  });

  final SyncDatasetKind? kind;
  final ValueChanged<ConflictResolutionStrategy> onSelected;

  @override
  Widget build(BuildContext context) {
    final strategies = _strategiesFor(kind);
    if (strategies.isEmpty) {
      return Text(syncText(context, '不可用', 'Unavailable'));
    }
    return AdaptiveActionMenu<ConflictResolutionStrategy>(
      tooltip: syncText(context, '解决冲突', 'Resolve conflict'),
      onSelected: onSelected,
      items: [
        for (final strategy in strategies)
          AdaptiveActionItem(
            value: strategy,
            label: _strategyLabel(context, strategy),
          ),
      ],
    );
  }
}

List<ConflictResolutionStrategy> _strategiesFor(SyncDatasetKind? kind) =>
    switch (kind) {
      SyncDatasetKind.selectedFolder => const [
        ConflictResolutionStrategy.keepLocal,
        ConflictResolutionStrategy.keepRemote,
        ConflictResolutionStrategy.keepBoth,
      ],
      SyncDatasetKind.velockManaged => const [
        ConflictResolutionStrategy.openInVelock,
      ],
      // Plain folder locations resolve conflicts themselves (keep both by
      // default) and never enter this durable queue.
      SyncDatasetKind.plainFolder => const [],
      null => const [],
    };

String _strategyLabel(
  BuildContext context,
  ConflictResolutionStrategy strategy,
) => switch (strategy) {
  ConflictResolutionStrategy.keepLocal => syncText(
    context,
    '保留本地版本',
    'Keep this device version',
  ),
  ConflictResolutionStrategy.keepRemote => syncText(
    context,
    '保留远端版本',
    'Keep remote version',
  ),
  ConflictResolutionStrategy.keepBoth => syncText(
    context,
    '保留两个版本',
    'Keep both versions',
  ),
  ConflictResolutionStrategy.openInVelock => syncText(
    context,
    '在 Velock 中处理',
    'Open in Velock',
  ),
};

String _conflictType(BuildContext context, String value) =>
    switch (value.split(':').first) {
      'modify-modify' => syncText(
        context,
        '两个设备都修改了内容',
        'Both devices changed this item',
      ),
      'delete-modify' => syncText(
        context,
        '删除与修改发生冲突',
        'A delete and an edit conflict',
      ),
      _ => syncText(context, '需要处理的同步冲突', 'Sync conflict to review'),
    };

String _transferTitle(BuildContext context, TransferJobRecord transfer) {
  final state = _transferState(context, transfer.state);
  return transfer.direction == TransferJobDirection.upload
      ? syncText(context, '上传$state', 'Upload $state')
      : syncText(context, '下载$state', 'Download $state');
}

String _transferState(BuildContext context, TransferJobState state) =>
    switch (state) {
      TransferJobState.queued => syncText(context, '排队中', 'queued'),
      TransferJobState.running => syncText(context, '进行中', 'in progress'),
      TransferJobState.paused => syncText(context, '已暂停', 'paused'),
      TransferJobState.retryWaiting => syncText(
        context,
        '等待重试',
        'waiting to retry',
      ),
      TransferJobState.failed => syncText(context, '失败', 'failed'),
      TransferJobState.cancelled => syncText(context, '已取消', 'cancelled'),
      TransferJobState.completed => syncText(context, '完成', 'done'),
    };

String _transferProgress(BuildContext context, TransferJobRecord transfer) {
  final expected = transfer.expectedSize;
  if (expected == null) {
    return syncText(
      context,
      '${AppFormat.bytes(transfer.completedBytes)} 已传输',
      '${AppFormat.bytes(transfer.completedBytes)} transferred',
    );
  }
  return '${AppFormat.bytes(transfer.completedBytes)} / ${AppFormat.bytes(expected)}';
}

/// Read-only activity record. The list shows the conclusion, the sheet keeps
/// the protocol detail one level deeper.
Future<void> _showActivityRunDetails(
  BuildContext context,
  SyncRunRecord run,
  _ActivityData values,
) {
  final failed = run.state == 'failed';
  final technical = AppFormat.technicalDetail(
    code: run.errorCode,
    profileId: run.profileId,
    at: run.completedAt ?? run.startedAt,
    context: context,
    extra: [
      if (run.errorCategory != null)
        syncText(
          context,
          '错误分类：${run.errorCategory}',
          'Error category: ${run.errorCategory}',
        ),
      if (run.providerStatusCode != null)
        syncText(
          context,
          '服务状态码：${run.providerStatusCode}',
          'Provider status code: ${run.providerStatusCode}',
        ),
      if (run.retryable != null)
        syncText(
          context,
          '可重试：${run.retryable! ? '是' : '否'}',
          'Retryable: ${run.retryable! ? 'yes' : 'no'}',
        ),
    ].join('\n'),
  );
  return showAppDetailSheet(
    context,
    title: failed
        ? syncText(context, '同步失败', 'Sync failed')
        : syncText(context, '同步完成', 'Sync completed'),
    rows: [
      AppDetailSheetRow(
        label: syncText(context, '同步配置', 'Sync profile'),
        value: values.nameFor(context, run.profileId),
      ),
      AppDetailSheetRow(
        label: syncText(context, '开始时间', 'Started'),
        value: AppFormat.stamp(run.startedAt),
      ),
      AppDetailSheetRow(
        label: syncText(context, '结束时间', 'Finished'),
        value: AppFormat.stamp(run.completedAt),
      ),
      AppDetailSheetRow(
        label: syncText(context, '结果', 'Result'),
        value: failed
            ? syncText(context, '未完成', 'Not completed')
            : syncText(context, '已完成', 'Completed'),
        tone: failed ? AppTone.danger : AppTone.ok,
      ),
      if (failed)
        AppDetailSheetRow(
          label: syncText(context, '可能原因', 'Likely cause'),
          value: AppFormat.errorSummary(run.errorCode, context: context),
        ),
      if (run.suggestedAction != null)
        AppDetailSheetRow(
          label: syncText(context, '建议操作', 'Suggested action'),
          value: run.suggestedAction!,
        ),
    ],
    footnote: technical.isEmpty
        ? null
        : syncText(
            context,
            '技术详情\n$technical',
            'Technical details\n$technical',
          ),
  );
}
