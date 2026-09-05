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
            showTitle: false,
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
              AdaptiveListTile(
                leading: AdaptiveIconBadge(
                  icon: adaptiveIcon(
                    context,
                    material: run.state == 'completed'
                        ? Icons.check_rounded
                        : Icons.error_outline_rounded,
                    cupertino: run.state == 'completed'
                        ? CupertinoIcons.check_mark
                        : CupertinoIcons.exclamationmark,
                  ),
                  color: run.state == 'completed'
                      ? AppColors.success
                      : Theme.of(context).colorScheme.error,
                ),
                title: Text(run.state == 'completed' ? '同步完成' : '同步失败'),
                subtitle: Text(
                  '配置 ${_shortId(run.profileId)} · ${_formatTime(run.completedAt ?? run.startedAt)}${_runErrorDetails(run)}',
                ),
                isThreeLine: _runErrorDetails(run).isNotEmpty,
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
                  icon: adaptiveIcon(
                    context,
                    material: transfer.direction == TransferJobDirection.upload
                        ? Icons.upload_rounded
                        : Icons.download_rounded,
                    cupertino: transfer.direction == TransferJobDirection.upload
                        ? CupertinoIcons.arrow_up
                        : CupertinoIcons.arrow_down,
                  ),
                  color: context.appPrimary,
                ),
                title: Text(_transferTitle(transfer)),
                subtitle: Text(
                  '配置 ${_shortId(transfer.profileId)} · ${_transferProgress(transfer)}${transfer.errorCode == null ? '' : '\n${transfer.errorCode}'}',
                ),
                isThreeLine: transfer.errorCode != null,
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
                      '对象 ${_shortId(conflict.entityId)} · 设备 ${_shortId(conflict.sourceDeviceId ?? '未知')}\n${_formatTime(conflict.createdAt)}',
                    ),
                    isThreeLine: true,
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
  Widget build(BuildContext context) => AdaptiveSummaryCard(
    icon: adaptiveIcon(
      context,
      material: Icons.insights_outlined,
      cupertino: CupertinoIcons.chart_bar,
    ),
    color: context.appPrimary,
    eyebrow: '活动概览',
    title: '同步记录与待处理项',
    metrics: [
      AdaptiveSummaryMetric(value: '${values.runs.length}', label: '最近运行'),
      AdaptiveSummaryMetric(value: '${values.transfers.length}', label: '待恢复'),
      AdaptiveSummaryMetric(value: '${values.conflicts.length}', label: '冲突'),
    ],
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
  for (final profileId
      in conflicts.map((conflict) => conflict.profileId).toSet()) {
    try {
      kindsByProfileId[profileId] = (await profiles.read(profileId))?.kind;
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
  );
}

class _ActivityData {
  const _ActivityData({
    required this.runs,
    required this.transfers,
    required this.conflicts,
    required this.kindsByProfileId,
  });

  final List<SyncRunRecord> runs;
  final List<TransferJobRecord> transfers;
  final List<SyncConflictRecord> conflicts;
  final Map<String, SyncDatasetKind?> kindsByProfileId;

  SyncDatasetKind? kindFor(String profileId) => kindsByProfileId[profileId];
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
  if (expected == null) return '${transfer.completedBytes} B 已传输';
  return '${transfer.completedBytes} / $expected B';
}

String _runErrorDetails(SyncRunRecord run) {
  if (run.errorCode == null) return '';
  final retry = run.retryAfter;
  final retryText = retry == null ? '' : ' · 可在 ${retry.inSeconds} 秒后重试';
  final action = run.suggestedAction;
  return '\n${run.errorCode}$retryText${action == null ? '' : '\n$action'}';
}

String _shortId(String value) =>
    value.length <= 12 ? value : '${value.substring(0, 12)}…';

String _formatTime(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
