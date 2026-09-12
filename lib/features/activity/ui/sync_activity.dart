import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
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
      var message = '无法完成冲突解决。';
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
          message = '已打开 Velock；处理完成后回到这里再次选择“在 Velock 中处理”。';
        } else if (result.errorCode == 'untrusted-velock-receipt') {
          message = 'Velock 返回结果未通过验证，冲突仍保持未解决。';
        }
      } on Object {
        // Resolution service failures are deliberately reduced to the same
        // generic UI state as non-completion results below.
      }
      if (messageContext.mounted) {
        showPlatformMessage(messageContext, message);
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
            title: '活动',
            actions: [
              AdaptiveIconButton(
                tooltip: '刷新活动记录',
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
    return const [
      SliverFillRemaining(
        hasScrollBody: false,
        child: AdaptiveLoadingState(label: '正在加载活动记录'),
      ),
    ];
  }
  if (snapshot.hasError) {
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: AdaptiveErrorState(message: '无法读取活动记录。', onRetry: onRetry),
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
          title: '还没有同步活动',
          message: '同步运行、待恢复传输和需要处理的冲突会集中显示在这里。',
        ),
      ),
    ];
  }

  return [
    SliverToBoxAdapter(child: _ActivityOverview(values: values)),
    if (values.runs.isNotEmpty)
      SliverToBoxAdapter(
        child: AdaptiveListSection(
          header: '最近同步',
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
                    title: Text(failed ? '同步失败' : '同步完成'),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${values.nameFor(run.profileId)} · '
                          '${AppFormat.relativeTime(run.completedAt ?? run.startedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.rowSubtitle.copyWith(
                            color: context.appSecondaryLabel,
                          ),
                        ),
                        if (failed)
                          Text(
                            AppFormat.errorSummary(run.errorCode),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
          header: '待恢复传输',
          children: [
            for (final transfer in values.transfers)
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: transfer.direction == TransferJobDirection.upload
                      ? CupertinoIcons.arrow_up
                      : CupertinoIcons.arrow_down,
                  color: AppTone.brand.color(context),
                ),
                title: Text(_transferTitle(transfer)),
                subtitle: Text(
                  '${values.nameFor(transfer.profileId)} · ${_transferProgress(transfer)}'
                  '${transfer.errorCode == null ? '' : ' · ${AppFormat.errorSummary(transfer.errorCode)}'}',
                  maxLines: 2,
                ),
              ),
          ],
        ),
      ),
    SliverToBoxAdapter(
      child: AdaptiveListSection(
        header: '待处理冲突',
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
                  title: const Text('没有待处理冲突。'),
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
                    title: Text(_conflictType(conflict.type)),
                    subtitle: Text(
                      '${values.nameFor(conflict.profileId)} · '
                      '${AppFormat.relativeTime(conflict.createdAt)}',
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
                  child: Text('同步记录与待处理项', style: AppType.rowTitleStrong),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppMetricGrid(
              metrics: [
                AppMetric(value: '${values.runs.length}', label: '最近运行'),
                AppMetric(
                  value: '${values.transfers.length}',
                  label: '待恢复',
                  tone: values.transfers.isEmpty
                      ? AppTone.neutral
                      : AppTone.attention,
                ),
                AppMetric(
                  value: '${values.conflicts.length}',
                  label: '冲突',
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
  String nameFor(String profileId) => namesByProfileId[profileId] ?? '同步配置';
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
      return const Text('不可用');
    }
    return AdaptiveActionMenu<ConflictResolutionStrategy>(
      tooltip: '解决冲突',
      onSelected: onSelected,
      items: [
        for (final strategy in strategies)
          AdaptiveActionItem(value: strategy, label: _strategyLabel(strategy)),
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
      null => const [],
    };

String _strategyLabel(ConflictResolutionStrategy strategy) =>
    switch (strategy) {
      ConflictResolutionStrategy.keepLocal => '保留本地版本',
      ConflictResolutionStrategy.keepRemote => '保留远端版本',
      ConflictResolutionStrategy.keepBoth => '保留两个版本',
      ConflictResolutionStrategy.openInVelock => '在 Velock 中处理',
    };

String _conflictType(String value) => switch (value.split(':').first) {
  'modify-modify' => '两个设备都修改了内容',
  'delete-modify' => '删除与修改发生冲突',
  _ => '需要处理的同步冲突',
};

String _transferTitle(TransferJobRecord transfer) {
  final direction = transfer.direction == TransferJobDirection.upload
      ? '上传'
      : '下载';
  return '$direction${_transferState(transfer.state)}';
}

String _transferState(TransferJobState state) => switch (state) {
  TransferJobState.queued => '排队中',
  TransferJobState.running => '进行中',
  TransferJobState.paused => '已暂停',
  TransferJobState.retryWaiting => '等待重试',
  TransferJobState.failed => '失败',
  TransferJobState.cancelled => '已取消',
  TransferJobState.completed => '完成',
};

String _transferProgress(TransferJobRecord transfer) {
  final expected = transfer.expectedSize;
  if (expected == null) {
    return '${AppFormat.bytes(transfer.completedBytes)} 已传输';
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
    extra: [
      if (run.errorCategory != null) '错误分类：${run.errorCategory}',
      if (run.providerStatusCode != null) '服务状态码：${run.providerStatusCode}',
      if (run.retryable != null) '可重试：${run.retryable! ? '是' : '否'}',
    ].join('\n'),
  );
  return showAppDetailSheet(
    context,
    title: failed ? '同步失败' : '同步完成',
    rows: [
      AppDetailSheetRow(label: '同步配置', value: values.nameFor(run.profileId)),
      AppDetailSheetRow(label: '开始时间', value: AppFormat.stamp(run.startedAt)),
      AppDetailSheetRow(label: '结束时间', value: AppFormat.stamp(run.completedAt)),
      AppDetailSheetRow(
        label: '结果',
        value: failed ? '未完成' : '已完成',
        tone: failed ? AppTone.danger : AppTone.ok,
      ),
      if (failed)
        AppDetailSheetRow(
          label: '可能原因',
          value: AppFormat.errorSummary(run.errorCode),
        ),
      if (run.suggestedAction != null)
        AppDetailSheetRow(label: '建议操作', value: run.suggestedAction!),
    ],
    footnote: technical.isEmpty ? null : '技术详情\n$technical',
  );
}
