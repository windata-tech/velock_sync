/// Shared presentation helpers, common widgets, and sync actions used
/// by the sync-profiles pages (home, wizard, detail, settings).
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_queue_probe.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/execution/sync_profile_dispatcher.dart';
import 'package:velock_sync/sync_core/crypto/vault_recovery_package.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/diagnostics/remote_inventory_service.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'package:velock_sync/widgets/app_format.dart';
import 'sync_profile_providers.dart';

class VelockConnectionBanner extends StatelessWidget {
  const VelockConnectionBanner({
    super.key,
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
                  velockAvailabilitySubtitle(availability),
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

class ProfileStatusPresentation {
  const ProfileStatusPresentation({
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

ProfileStatusPresentation profileStatusPresentation(
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
    return const ProfileStatusPresentation(
      label: '需要处理',
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
      detail: '此配置无法安全读取，请重新创建同步配置。',
    );
  }
  if (velockUnavailable) {
    return ProfileStatusPresentation(
      label: velockAvailabilityLabel(velockAvailability),
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
      detail: velockAvailabilitySubtitle(velockAvailability),
    );
  }
  if (lastRunFailed) {
    return const ProfileStatusPresentation(
      label: '上次失败',
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
    );
  }
  return switch (state) {
    SyncProfileState.active => ProfileStatusPresentation(
      label: kind == SyncDatasetKind.velockManaged ? '已保护' : '已同步',
      tone: AppTone.ok,
      icon: CupertinoIcons.check_mark_circled,
    ),
    SyncProfileState.paused => const ProfileStatusPresentation(
      label: '已暂停',
      tone: AppTone.neutral,
      icon: CupertinoIcons.pause_circle,
    ),
    SyncProfileState.accessRequired => const ProfileStatusPresentation(
      label: '需要授权',
      tone: AppTone.attention,
      icon: CupertinoIcons.exclamationmark_triangle,
    ),
    SyncProfileState.reauthorizationRequired => const ProfileStatusPresentation(
      label: '凭据失效',
      tone: AppTone.attention,
      icon: CupertinoIcons.exclamationmark_triangle,
    ),
    SyncProfileState.blockedByConfiguration => const ProfileStatusPresentation(
      label: '配置不完整',
      tone: AppTone.attention,
      icon: CupertinoIcons.exclamationmark_triangle,
    ),
    SyncProfileState.error => const ProfileStatusPresentation(
      label: '需要处理',
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
    ),
  };
}

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

String latestRunFailureSubtitle(SyncRunRecord? run) {
  final message = _latestRunFailureMessage(run);
  return message.startsWith('上次同步失败：')
      ? message.substring('上次同步失败：'.length)
      : message;
}

String firstSyncResultMessage(SyncProfileDispatchResult? result) {
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

Future<SyncProfileDispatchResult?> runSyncWithProgress(
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

Future<bool> confirmSyncProfileRemoval(
  BuildContext context,
  String displayName,
) => showAdaptiveConfirmation(
  context,
  title: '删除同步配置？',
  message: '“$displayName”将从本机删除。远端同步空间和文件不会被删除。',
  confirmLabel: '删除',
  isDestructive: true,
);

Future<void> presentSyncResult(
  BuildContext context,
  SyncProfileDispatchResult result,
) async {
  final pending = result.run?.download.pendingBatchCount ?? 0;
  if (result.didRun && pending > 0) {
    await _offerOpenVelock(context, pending);
    return;
  }
  showMessage(context, _syncResultMessage(result));
}

Future<void> presentFirstSyncResult(
  BuildContext context,
  SyncProfileDispatchResult? result,
) async {
  final pending = result?.run?.download.pendingBatchCount ?? 0;
  if (result?.didRun == true && pending > 0) {
    await _offerOpenVelock(context, pending);
    return;
  }
  showMessage(context, firstSyncResultMessage(result));
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
    showMessage(context, '无法打开格间，请手动打开。');
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
    return '同步未启动：${dispatchLabel(result.status)}';
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

/// Full itemised list of everything this device has moved.
Future<void> showSyncedObjectsSheet(
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

/// Read-only run record. Human conclusion first; raw protocol fields stay in
/// the collapsed technical footnote instead of the primary copy.
Future<void> showRunDetails(
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
    title: '同步记录 · ${runStateLabel(run.state)}',
    rows: [
      AppDetailSheetRow(label: '开始时间', value: AppFormat.stamp(run.startedAt)),
      AppDetailSheetRow(label: '结束时间', value: AppFormat.stamp(run.completedAt)),
      AppDetailSheetRow(
        label: '结果',
        value: runStateLabel(run.state),
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

class SyncedKindRow extends StatelessWidget {
  const SyncedKindRow({super.key, required this.kind});

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

class SyncedDataRow extends StatelessWidget {
  const SyncedDataRow({
    super.key,
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

/// "What has actually been synced" — the reassurance view.
///
/// Two sources are shown side by side: durable local counters (what this
/// device moved) and an on-demand scan of the remote vault prefix (what is
/// actually stored). Everything is aggregated — no keys, paths or file names.
class SyncedDataSection extends ConsumerStatefulWidget {
  const SyncedDataSection({
    super.key,
    required this.snapshot,
    required this.profile,
    required this.history,
  });

  final SyncedDataSnapshot snapshot;
  final SyncProfileEnvelope profile;
  final List<TransferJobRecord> history;

  @override
  ConsumerState<SyncedDataSection> createState() => _SyncedDataSectionState();
}

class _SyncedDataSectionState extends ConsumerState<SyncedDataSection> {
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
          SyncedDataRow(
            icon: Icons.schedule_outlined,
            label: '最近同步',
            value: AppFormat.relativeTime(lastActivity),
          ),
        SyncedDataRow(
          icon: Icons.layers_outlined,
          label: '增量批次',
          value:
              '已发布 ${snapshot.publishedOutgoingCount} · '
              '已应用 ${snapshot.appliedIncomingCount}',
        ),
        if (pendingTransfers > 0)
          SyncedDataRow(
            icon: Icons.sync_outlined,
            label: '待传输对象',
            value:
                '上传 ${snapshot.pendingUploadCount} · '
                '下载 ${snapshot.pendingDownloadCount}',
          ),
        for (final kind in kinds) SyncedKindRow(kind: kind),
        for (final device in snapshot.devices)
          SyncedDataRow(
            icon: Icons.devices_outlined,
            label: '远端设备 ${shortId(device.deviceId)}',
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
            onTap: () => showSyncedObjectsSheet(context, widget.history),
          ),
        ],
        if (_queue != null) ...[
          SyncedDataRow(
            icon: Icons.outbox_outlined,
            label: '格间待上传批次',
            value: '${_queue!.outboxReadyCount} 个',
          ),
          SyncedDataRow(
            icon: Icons.move_to_inbox_outlined,
            label: '待格间导入',
            value: '${_queue!.inboxReadyCount} 个',
          ),
          if (_queue!.lastOutboxReceiptAt != null)
            SyncedDataRow(
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
        SyncedDataRow(
          icon: Icons.cloud_outlined,
          label: '远端已保存',
          value: remote == null
              ? '未扫描'
              : '${remote.totalCount} 个对象 · ${AppFormat.bytes(remote.totalBytes)}',
        ),
        if (remote != null && remote.lastUpdatedAt != null)
          SyncedDataRow(
            icon: Icons.update_outlined,
            label: '远端最近更新',
            value: AppFormat.relativeTime(remote.lastUpdatedAt),
          ),
        if (remote != null)
          for (final entry in remote.entries)
            SyncedKindRow(
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

class DetailData {
  const DetailData({
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

class RetryState extends StatelessWidget {
  const RetryState({super.key, required this.onRetry, required this.message});
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

Future<void> exportSelectedFolderRecovery(
  BuildContext context,
  WidgetRef ref,
  SyncProfileEnvelope profile,
) async {
  final rootKeyRef = profile.dataset['rootKeyRef'];
  if (rootKeyRef is! String || rootKeyRef.isEmpty) {
    showMessage(context, '无法读取此配置的恢复密钥引用。');
    return;
  }
  final passphrase = await requestProfileRecoveryPassphrase(context);
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
      await showProfileRecoveryPackage(context, recoveryPackage);
    }
  } on Object catch (error, stackTrace) {
    logw(
      'Selected Folder recovery export failed: ${error.runtimeType}',
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      showMessage(context, '无法生成恢复包；请检查本机密钥状态。');
    }
  }
}

Future<String?> requestProfileRecoveryPassphrase(BuildContext context) async {
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

Future<void> showProfileRecoveryPackage(
  BuildContext context,
  String recoveryPackage,
) => showAdaptiveNotice(
  context: context,
  title: '一次性恢复包',
  message: '请安全保存。此窗口关闭后应用不会保留或自动复制该恢复包。',
  details: SelectableText(recoveryPackage),
  confirmLabel: '我已安全保存',
);

String kindLabel(SyncDatasetKind? kind) => switch (kind) {
  SyncDatasetKind.selectedFolder => '文件夹同步',
  SyncDatasetKind.velockManaged => '格间备份',
  null => '不可用',
};

IconData adaptiveKindIcon(BuildContext context, SyncDatasetKind? kind) =>
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

String velockAvailabilityLabel(VelockWizardAvailability availability) =>
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

String velockAvailabilitySubtitle(VelockWizardAvailability availability) =>
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

String transferStateLabel(TransferJobState state) => switch (state) {
  TransferJobState.queued => '等待中',
  TransferJobState.running => '进行中',
  TransferJobState.paused => '已暂停',
  TransferJobState.retryWaiting => '等待重试',
  TransferJobState.completed => '已完成',
  TransferJobState.failed => '失败',
  TransferJobState.cancelled => '已取消',
};

String runStateLabel(String state) => switch (state) {
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
String profileSecondaryText(SyncProfileSummary summary) {
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

String dispatchLabel(SyncProfileDispatchStatus status) => switch (status) {
  SyncProfileDispatchStatus.completed => '已完成',
  SyncProfileDispatchStatus.skippedNotRunnable => '当前状态不允许同步',
  SyncProfileDispatchStatus.skippedUnsupported => '此配置不受支持',
  SyncProfileDispatchStatus.failed => '发生错误',
};

String velockReadinessTitle(VelockWizardAvailability availability) =>
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

String velockReadinessMessage(VelockWizardAvailability availability) =>
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

String conflictLabel(String type) => switch (type.split(':').first) {
  'modify-modify' => '两个设备都修改了内容',
  'delete-modify' => '删除与修改发生冲突',
  _ => '需要处理的同步冲突',
};

String shortId(String value) =>
    value.length <= 12 ? value : '${value.substring(0, 12)}…';
String formatTime(DateTime value) =>
    '${value.toLocal().year}-${value.toLocal().month.toString().padLeft(2, '0')}-${value.toLocal().day.toString().padLeft(2, '0')} ${value.toLocal().hour.toString().padLeft(2, '0')}:${value.toLocal().minute.toString().padLeft(2, '0')}';
int supportedCellularLimit(int value) {
  const tenMiB = 10 * 1024 * 1024;
  const hundredMiB = 100 * 1024 * 1024;
  if (value == tenMiB || value == hundredMiB) return value;
  return 50 * 1024 * 1024;
}

void showMessage(BuildContext context, String message) =>
    showPlatformMessage(context, message);
