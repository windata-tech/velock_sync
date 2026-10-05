/// Shared presentation helpers, common widgets, and sync actions used
/// by the sync-profiles pages (home, wizard, detail, settings).
library;

import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/features/cloud_backup/ui/velock_companion_gate.dart';
import 'dart:async';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
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
import 'package:velock_sync/features/sync_profiles/model/sync_run_outcome.dart';
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
      VelockWizardAvailability.appNotInstalled => _optionalSyncText(
        context,
        'Velock 本体未安装，连接已断开',
        "Velock is not installed; disconnected",
      ),
      VelockWizardAvailability.authorizationRequired => _optionalSyncText(
        context,
        'Velock 连接未授权',
        "Velock connection not authorized",
      ),
      VelockWizardAvailability.accessRevoked => _optionalSyncText(
        context,
        'Velock 已撤销同步授权',
        "Velock revoked sync access",
      ),
      VelockWizardAvailability.unsupportedVersion => _optionalSyncText(
        context,
        'Velock 版本不受支持',
        "Unsupported Velock version",
      ),
      VelockWizardAvailability.velockUpdateRequired =>
        velockUpdateRequiredTitle(context),
      VelockWizardAvailability.signatureMismatch => _optionalSyncText(
        context,
        'Velock 身份验证失败',
        "Velock identity verification failed",
      ),
      VelockWizardAvailability.configurationMissing => _optionalSyncText(
        context,
        'Velock 连接已断开',
        "Velock disconnected",
      ),
      VelockWizardAvailability.temporarilyUnavailable => _optionalSyncText(
        context,
        'Velock 连接暂不可用',
        "Velock connection temporarily unavailable",
      ),
      VelockWizardAvailability.unsupportedPlatform => _optionalSyncText(
        context,
        '当前平台不支持 Velock 连接',
        "Velock connection is not supported on this platform",
      ),
      VelockWizardAvailability.ready => _optionalSyncText(
        context,
        'Velock 连接正常',
        "Velock connected",
      ),
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
                  velockAvailabilitySubtitle(availability, context: context),
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
            child: Text(_optionalSyncText(context, '重新检测', "Check again")),
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
    return ProfileStatusPresentation(
      label: _optionalSyncText(context, '需要处理', "Needs attention"),
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
      detail: _optionalSyncText(
        context,
        '此配置无法安全读取，请重新创建同步配置。',
        "This profile cannot be read safely. Create a new sync profile.",
      ),
    );
  }
  if (velockUnavailable) {
    return ProfileStatusPresentation(
      label: velockAvailabilityLabel(velockAvailability, context: context),
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
      detail: velockAvailabilitySubtitle(velockAvailability, context: context),
    );
  }
  if (lastRunFailed) {
    return ProfileStatusPresentation(
      label: _optionalSyncText(context, '上次失败', "Last run failed"),
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
    );
  }
  return switch (state) {
    SyncProfileState.active => ProfileStatusPresentation(
      label: kind == SyncDatasetKind.velockManaged
          ? _optionalSyncText(context, '已保护', "Protected")
          : _optionalSyncText(context, '已同步', "Synced"),
      tone: AppTone.ok,
      icon: CupertinoIcons.check_mark_circled,
    ),
    SyncProfileState.paused => ProfileStatusPresentation(
      label: _optionalSyncText(context, '已暂停', "Paused"),
      tone: AppTone.neutral,
      icon: CupertinoIcons.pause_circle,
    ),
    SyncProfileState.accessRequired => ProfileStatusPresentation(
      label: _optionalSyncText(context, '需要授权', "Authorization required"),
      tone: AppTone.attention,
      icon: CupertinoIcons.exclamationmark_triangle,
    ),
    SyncProfileState.reauthorizationRequired => ProfileStatusPresentation(
      label: _optionalSyncText(context, '凭据失效', "Credentials expired"),
      tone: AppTone.attention,
      icon: CupertinoIcons.exclamationmark_triangle,
    ),
    SyncProfileState.blockedByConfiguration => ProfileStatusPresentation(
      label: _optionalSyncText(context, '配置不完整', "Incomplete setup"),
      tone: AppTone.attention,
      icon: CupertinoIcons.exclamationmark_triangle,
    ),
    SyncProfileState.error => ProfileStatusPresentation(
      label: _optionalSyncText(context, '需要处理', "Needs attention"),
      tone: AppTone.danger,
      icon: CupertinoIcons.exclamationmark_circle,
    ),
  };
}

String _latestRunFailureMessage(SyncRunRecord? run, {BuildContext? context}) {
  if (run?.errorCode == 'provider.http.401') {
    return _optionalSyncText(
      context,
      '上次同步失败：WebDAV 认证失败，请重新输入用户名和密码；地址和目录会保留。',
      "Last sync failed: WebDAV authentication failed. Enter your username and password again; the address and folder will be kept.",
    );
  }
  if (run?.errorCode == 'provider.http.403') {
    return _optionalSyncText(
      context,
      '上次同步失败：当前账号没有远端同步目录的访问权限。',
      "Last sync failed: this account cannot access the remote sync folder.",
    );
  }
  if (run?.errorCode == 'provider.http.404') {
    return _optionalSyncText(
      context,
      '上次同步失败：远端同步目录不存在，请检查 WebDAV 路径。',
      "Last sync failed: the remote sync folder does not exist. Check the WebDAV path.",
    );
  }
  if (run?.errorCode == 'provider.http.409') {
    return _optionalSyncText(
      context,
      '上次同步失败：远端同步目录存在冲突，请确认没有其他设备同时同步。',
      "Last sync failed: the remote sync folder has a conflict. Check that no other device is syncing at the same time.",
    );
  }
  return _optionalSyncText(
    context,
    '上次同步失败：${AppFormat.errorSummary(run?.errorCode, context: context)}',
    "Last sync failed: ${AppFormat.errorSummary(run?.errorCode, context: context)}",
  );
}

String latestRunFailureSubtitle(SyncRunRecord? run, {BuildContext? context}) {
  final message = _latestRunFailureMessage(run, context: context);
  return message.startsWith(
        _optionalSyncText(context, '上次同步失败：', "Last sync failed: "),
      )
      ? message.substring(
          _optionalSyncText(context, '上次同步失败：', "Last sync failed: ").length,
        )
      : message;
}

String firstSyncResultMessage(
  SyncProfileDispatchResult? result, {
  BuildContext? context,
}) {
  if (result == null) {
    return _optionalSyncText(
      context,
      '本次传输尚未开始，请重试。',
      'The transfer has not started. Please try again.',
    );
  }
  return _syncResultMessage(result, context: context);
}

/// Runs one profile now and returns its dispatch result.
///
/// There is deliberately no modal progress dialog: the transfer state belongs
/// to the action button and the status card that started it (`BackupStage.
/// transferring` drives the button's inline spinner), and a blocking scrim hid
/// the very state the user was watching. Failures still get the persistent
/// acknowledged alert through [presentSyncFailureAlert].
Future<SyncProfileDispatchResult?> runSyncWithProgress(
  BuildContext context,
  WidgetRef ref,
  String profileId,
) async {
  try {
    return await ref.read(syncProfileRunServiceProvider).runNow(profileId);
  } finally {
    // Setup and rebuild can run while the home tab remains mounted beneath
    // another page. Refresh its cached summary after the durable run result.
    if (context.mounted) ref.read(profilesRevisionProvider.notifier).bump();
  }
}

Future<bool> confirmSyncProfileRemoval(
  BuildContext context,
  String displayName,
) => showAdaptiveConfirmation(
  context,
  title: _optionalSyncText(context, '删除同步配置？', "Delete sync profile?"),
  message: _optionalSyncText(
    context,
    '“$displayName”将从本机删除。远端同步空间和文件不会被删除。',
    "“$displayName” will be deleted from this device. The remote sync space and files will not be deleted.",
  ),
  confirmLabel: _optionalSyncText(context, '删除', "Delete"),
  isDestructive: true,
);

Future<void> presentSyncResult(
  BuildContext context,
  SyncProfileDispatchResult result, {
  Future<void> Function(BackupAction action)? onFix,
}) async {
  final pending = result.run?.download.pendingBatchCount ?? 0;
  if (result.didRun && pending > 0) {
    await _offerOpenVelock(context, pending);
    return;
  }
  if (result.didFail) {
    if (!context.mounted) return;
    await presentSyncFailureAlert(
      context: context,
      error: result.error ?? const Object(),
      onFix: onFix,
    );
    return;
  }
  showMessage(context, _syncResultMessage(result, context: context));
}

Future<void> presentFirstSyncResult(
  BuildContext context,
  SyncProfileDispatchResult? result, {
  Future<void> Function(BackupAction action)? onFix,
}) async {
  final pending = result?.run?.download.pendingBatchCount ?? 0;
  if (result?.didRun == true && pending > 0) {
    await _offerOpenVelock(context, pending);
    return;
  }
  if (result?.didFail == true) {
    if (!context.mounted) return;
    await presentSyncFailureAlert(
      context: context,
      error: result!.error ?? const Object(),
      onFix: onFix,
    );
    return;
  }
  showMessage(context, firstSyncResultMessage(result, context: context));
}

/// Persistent, acknowledged failure presentation shared by
/// [presentSyncResult] and [presentFirstSyncResult].
///
/// Failures use the platform-adaptive alert instead of the transient
/// [showMessage] toast: there is no timer and no retry side effect, so the
/// readable localized failure text stays on screen until the user
/// acknowledges it with the explicit OK action; barrier taps are ignored.
///
/// Callers catching a thrown exception (for example around
/// [runSyncWithProgress]) can present it directly:
///
/// ```dart
/// on Object catch (error) {
///   await presentSyncFailureAlert(context: context, error: error);
/// }
/// ```
///
/// The exception is only classified by [SyncFailureClassifier]; its
/// diagnostic text never reaches the user.
Future<void> presentSyncFailureAlert({
  required BuildContext context,
  required Object error,
  Key? okKey,
  Future<void> Function(BackupAction action)? onFix,
}) async {
  final failure = SyncFailureClassifier.classify(error);
  if (failure.errorCode == 'local.velock_snapshot_application_required') {
    // Not a failure: the backup is downloaded and Velock applies it next.
    // Offer the way there instead of a dead-end "OK".
    final open = await showAdaptiveConfirmation(
      context,
      title: _optionalSyncText(
        context,
        '请到格间完成恢复',
        'Finish restoring in Velock',
      ),
      message: _syncFailureAlertMessage(failure, context: context),
      confirmLabel: _optionalSyncText(context, '打开格间', 'Open Velock'),
      cancelLabel: _optionalSyncText(context, '稍后', 'Later'),
    );
    if (open && context.mounted) {
      await launchUrl(
        Uri.parse('velock://sync-settings'),
        mode: LaunchMode.externalApplication,
      );
    }
    return;
  }
  final historyMissing =
      failure.errorCode == 'remote.velock_history_incomplete';
  // Every failure offers the step that fixes it, not just an "OK".
  final fixes = onFix == null
      ? const <(BackupAction, String)>[]
      : backupFixChoices(context, failure.errorCode);
  final chosen = await showAdaptiveAlert<BackupAction>(
    context: context,
    // Every caller is the Velock domain, whose task is a backup.
    title: historyMissing
        ? _optionalSyncText(
            context,
            '这个文件夹里没有完整的备份',
            'This folder has no complete backup',
          )
        : _optionalSyncText(context, '备份失败', 'Backup failed'),
    message: historyMissing
        ? _optionalSyncText(
            context,
            '之前备份过的内容不在这个文件夹里，所以没法接着备份。可以让格间把现在的全部内容完整备份到一个新文件夹，或者改回原来存放备份的文件夹。',
            'Content backed up earlier is not in this folder, so the backup cannot continue. Let Velock back up everything it has now to a new folder, or switch back to the folder that holds the backup.',
          )
        : _syncFailureAlertMessage(failure, context: context),
    barrierDismissible: false,
    actions: [
      for (final (index, (action, label)) in fixes.indexed)
        AdaptiveAlertAction<BackupAction>(
          label: label,
          value: action,
          key: Key('sync-failure-fix-${action.name}'),
          isDefault: index == 0,
          emphasized: index == 0,
        ),
      AdaptiveAlertAction<BackupAction>(
        label: fixes.isEmpty
            ? _optionalSyncText(context, '知道了', 'OK')
            : _optionalSyncText(context, '稍后', 'Later'),
        key: okKey ?? const Key('sync-failure-alert-ok'),
        isDefault: fixes.isEmpty,
        emphasized: fixes.isEmpty,
      ),
    ],
  );
  if (chosen != null && onFix != null && context.mounted) {
    await onFix(chosen);
  }
}

/// The buttons a failure alert offers, most useful first. Each one leads
/// straight to the fix; the card behind the alert offers the same action.
List<(BackupAction, String)> backupFixChoices(
  BuildContext context,
  String? errorCode,
) {
  String t(String zh, String en) => _optionalSyncText(context, zh, en);
  return switch (backupActionForFailure(errorCode)) {
    BackupAction.rebuildBackup || BackupAction.reviewHistory => [
      (
        BackupAction.rebuildBackup,
        t('完整备份到新文件夹', 'Back up everything to a new folder'),
      ),
      (BackupAction.reviewHistory, t('改回原来的文件夹', 'Use the original folder')),
    ],
    BackupAction.checkStorage => [
      (BackupAction.checkStorage, t('更换保存位置', 'Change backup folder')),
    ],
    BackupAction.fixConnection => [
      (BackupAction.fixConnection, t('修改连接', 'Edit connection')),
    ],
    BackupAction.openVelock => [
      (BackupAction.openVelock, t('打开格间', 'Open Velock')),
    ],
    BackupAction.manage => [
      (BackupAction.manage, t('查看并处理', 'Review and fix')),
    ],
    _ => [(BackupAction.transfer, t('重试', 'Try again'))],
  };
}

/// Readable localized body of the failure alert: the human summary for the
/// classified [SyncFailure], with a dedicated sentence for HTTP 409
/// conflicts.
String _syncFailureAlertMessage(SyncFailure failure, {BuildContext? context}) {
  if (failure.providerStatusCode == 409) {
    return _optionalSyncText(
      context,
      '远端同步目录存在冲突（HTTP 409）。请确认没有其他设备同时同步，或检查远端目录后重试。',
      "Remote sync folder conflict (HTTP 409). Check that no other device is syncing, or check the remote folder and retry.",
    );
  }
  return AppFormat.errorSummary(failure.errorCode, context: context);
}

Future<void> _offerOpenVelock(BuildContext context, int pending) async {
  final shouldOpen = await showAdaptiveConfirmation(
    context,
    title: _optionalSyncText(
      context,
      '已下载，等待格间恢复',
      'Downloaded. Restore in Velock',
    ),
    message: _optionalSyncText(
      context,
      '数据已下载到这台设备，还需要在格间中解锁并恢复。现在打开格间？',
      'Data has reached this device. Unlock Velock to finish restoring. Open Velock now?',
    ),
    confirmLabel: _optionalSyncText(context, '打开格间', "Open Velock"),
    cancelLabel: _optionalSyncText(context, '稍后', "Later"),
  );
  if (!shouldOpen || !context.mounted) return;
  // velock://sync-settings opens Velock's cloud backup page, where the
  // restore is confirmed; velock://open only woke whatever page was last open.
  final launched = await launchUrl(
    Uri.parse('velock://sync-settings'),
    mode: LaunchMode.externalApplication,
  );
  if (!launched && context.mounted) {
    showMessage(
      context,
      _optionalSyncText(
        context,
        '无法打开格间，请手动打开。',
        "Could not open Velock. Please open it manually.",
      ),
    );
  }
}

String _syncResultMessage(
  SyncProfileDispatchResult result, {
  BuildContext? context,
}) {
  if (result.isAlreadyRunning) {
    return _optionalSyncText(
      context,
      '同步已在进行中，无需重复启动。',
      'Sync is already in progress. No need to start it again.',
    );
  }
  if (result.didFail) {
    final failure = SyncFailureClassifier.classify(result.error!);
    if (failure.providerStatusCode == 409) {
      return _optionalSyncText(
        context,
        '同步失败：远端同步目录存在冲突（HTTP 409）。请确认没有其他设备同时同步，或检查远端目录后重试。',
        "Sync failed: remote sync folder conflict (HTTP 409). Check that no other device is syncing, or check the remote folder and retry.",
      );
    }
    return _optionalSyncText(
      context,
      '同步失败：${AppFormat.errorSummary(failure.errorCode, context: context)}',
      "Sync failed: ${AppFormat.errorSummary(failure.errorCode, context: context)}",
    );
  }
  if (!result.didRun) {
    return _optionalSyncText(
      context,
      '同步未启动：${dispatchLabel(result.status, context: context)}',
      "Sync did not start: ${dispatchLabel(result.status, context: context)}",
    );
  }
  final upload = result.run?.upload.publishedBatchCount ?? 0;
  final imported = result.run?.download.importedBatchCount ?? 0;
  final pending = result.run?.download.pendingBatchCount ?? 0;
  if (pending > 0) {
    return _optionalSyncText(
      context,
      '数据已下载，请打开格间并解锁以完成恢复。',
      'Data downloaded. Open and unlock Velock to finish restoring.',
    );
  }
  if (upload > 0 && imported > 0) {
    return _optionalSyncText(
      context,
      '本次传输已完成，上传和接收的数据已处理。',
      "This transfer is complete. Uploaded and received changes were processed.",
    );
  }
  if (upload > 0) {
    return _optionalSyncText(
      context,
      '本次准备好的内容已上传。',
      "The prepared changes have been uploaded.",
    );
  }
  if (imported > 0) {
    return _optionalSyncText(
      context,
      '本次收到的数据已处理。',
      "The received data has been processed.",
    );
  }
  return _optionalSyncText(
    context,
    '本次检查没有发现需要传输的新内容。',
    "No new changes to transfer were found in this check.",
  );
}

/// Full itemised list of everything this device has moved.
Future<void> showSyncedObjectsSheet(
  BuildContext context,
  List<TransferJobRecord> history,
) => showAppDetailSheet(
  context,
  title: _optionalSyncText(context, '已同步对象明细', "Synced object details"),
  rows: [
    for (final transfer in history)
      AppDetailSheetRow(
        label: _optionalSyncText(
          context,
          '${_syncedKindLabel(remoteInventoryKind(transfer.logicalKey), context: context)} · '
              '${transfer.direction == TransferJobDirection.upload ? '上传' : '恢复'}',
          "${_syncedKindLabel(remoteInventoryKind(transfer.logicalKey), context: context)} · ${transfer.direction == TransferJobDirection.upload ? 'Upload' : 'Restore'}",
        ),
        value: AppFormat.stamp(transfer.completedAt),
        trailing: AppFormat.bytes(transfer.completedBytes),
      ),
  ],
  footnote: _optionalSyncText(
    context,
    '格间备份以加密对象为单位（批次 / 数据块 / 提交）；原始文件名只在格间 App 内可见。',
    "Velock backup counts encrypted objects (batches / blobs / commits). Original filenames are only visible in Velock.",
  ),
);

/// Read-only run record. Human conclusion first; raw protocol fields stay in
/// the collapsed technical footnote instead of the primary copy.
Future<void> showRunDetails(
  BuildContext context,
  SyncRunRecord run, {
  List<TransferJobRecord> history = const [],
}) {
  final rebuild = run.rebuild;
  final transferred = runWindowTransfers(run, history);
  // "上传对象 0 个" must never sit under a status that claims a transfer.
  final conclusion = syncRunConclusionLabel(
    run,
    transfers: transferred,
    context: context,
  );
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
      _optionalSyncText(
        context,
        '${_syncedKindLabel(remoteInventoryKind(transfer.logicalKey), context: context)} · '
            '${transfer.direction == TransferJobDirection.upload ? '上传' : '恢复'} · '
            '${AppFormat.bytes(transfer.completedBytes)} · '
            '${AppFormat.stamp(transfer.completedAt)}',
        "${_syncedKindLabel(remoteInventoryKind(transfer.logicalKey), context: context)} · ${transfer.direction == TransferJobDirection.upload ? 'Upload' : 'Restore'} · ${AppFormat.bytes(transfer.completedBytes)} · ${AppFormat.stamp(transfer.completedAt)}",
      ),
  ];

  final failed = run.state == 'failed';
  final technical = <String>[
    if (run.errorCode != null)
      _optionalSyncText(
        context,
        '错误代码：${run.errorCode}',
        "Error code: ${run.errorCode}",
      ),
    if (run.errorCategory != null)
      _optionalSyncText(
        context,
        '错误分类：${run.errorCategory}',
        "Error category: ${run.errorCategory}",
      ),
    if (run.providerStatusCode != null)
      _optionalSyncText(
        context,
        '服务状态码：${run.providerStatusCode}',
        "Provider status code: ${run.providerStatusCode}",
      ),
    if (run.retryable != null)
      _optionalSyncText(
        context,
        '可重试：${run.retryable! ? '是' : '否'}',
        "Retryable: ${run.retryable! ? 'Yes' : 'No'}",
      ),
    if (run.retryAfter != null)
      _optionalSyncText(
        context,
        '建议等待：${run.retryAfter!.inSeconds} 秒',
        "Suggested wait: ${run.retryAfter!.inSeconds} seconds",
      ),
  ].join('\n');
  return showAppDetailSheet(
    context,
    title: _optionalSyncText(
      context,
      '同步记录 · $conclusion',
      "Sync run · $conclusion",
    ),
    rows: [
      AppDetailSheetRow(
        label: _optionalSyncText(context, '开始时间', "Started"),
        value: AppFormat.stamp(run.startedAt),
      ),
      AppDetailSheetRow(
        label: _optionalSyncText(context, '结束时间', "Finished"),
        value: AppFormat.stamp(run.completedAt),
      ),
      AppDetailSheetRow(
        label: _optionalSyncText(context, '结果', "Result"),
        value: conclusion,
        tone: failed ? AppTone.danger : AppTone.ok,
      ),
      if (failed)
        AppDetailSheetRow(
          label: _optionalSyncText(context, '可能原因', "Possible cause"),
          value: AppFormat.errorSummary(run.errorCode, context: context),
        ),
      if (run.suggestedAction != null)
        AppDetailSheetRow(
          label: _optionalSyncText(context, '建议操作', "Suggested action"),
          value: _optionalSyncText(
            context,
            run.suggestedAction!,
            AppFormat.errorSummary(run.errorCode, context: context),
          ),
        ),
      if (rebuild != null) ...[
        AppDetailSheetRow(
          label: _optionalSyncText(context, '保存位置', 'Backup location'),
          value: rebuild.destination,
        ),
        AppDetailSheetRow(
          label: _optionalSyncText(
            context,
            '已校验的备份内容',
            'Verified backup content',
          ),
          value: _optionalSyncText(
            context,
            '${rebuild.objectCount} 个加密对象 · ${AppFormat.bytes(rebuild.totalBytes)}',
            '${rebuild.objectCount} encrypted objects · ${AppFormat.bytes(rebuild.totalBytes)}',
          ),
        ),
        AppDetailSheetRow(
          label: _optionalSyncText(context, '说明', 'About this result'),
          value: _optionalSyncText(
            context,
            rebuild.recovered
                ? '根据本机保存的位置切换结果及已验签的快照信息补回记录；时间为原完成时间。'
                : '完整快照已上传并回读校验，保存位置已切换。',
            rebuild.recovered
                ? 'Recovered from the saved location change and signed snapshot evidence, using the original completion time.'
                : 'The full snapshot was uploaded and verified by reading it back, then the saved location was changed.',
          ),
        ),
      ] else ...[
        AppDetailSheetRow(
          label: _optionalSyncText(context, '上传对象', "Uploaded objects"),
          value: _optionalSyncText(
            context,
            '${uploaded.length} 个 · ${AppFormat.bytes(bytesOf(uploaded))}',
            "${uploaded.length} objects · ${AppFormat.bytes(bytesOf(uploaded))}",
          ),
        ),
        AppDetailSheetRow(
          label: _optionalSyncText(context, '恢复对象', "Restored objects"),
          value: _optionalSyncText(
            context,
            '${downloaded.length} 个 · ${AppFormat.bytes(bytesOf(downloaded))}',
            "${downloaded.length} objects · ${AppFormat.bytes(bytesOf(downloaded))}",
          ),
        ),
        AppDetailSheetRow(
          label: _optionalSyncText(context, '传输明细', "Transfer details"),
          value: detailLines.isEmpty
              ? _optionalSyncText(
                  context,
                  '本次没有传输任何对象',
                  "No objects were transferred in this run",
                )
              : detailLines.join('\n'),
        ),
      ],
    ],
    footnote: technical.isEmpty
        ? null
        : _optionalSyncText(
            context,
            '技术详情\n$technical',
            "Technical details\n$technical",
          ),
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
    title: Text(_syncedKindLabel(kind.kind, context: context)),
    subtitle: Text(
      kind.remoteCount != null
          ? _optionalSyncText(
              context,
              '远端 ${kind.remoteCount} 个对象',
              "${kind.remoteCount} remote objects",
            )
          : _optionalSyncText(
              context,
              '上传 ${kind.uploadedCount} 项 · 下载 ${kind.downloadedCount} 项',
              "Uploaded ${kind.uploadedCount} · Downloaded ${kind.downloadedCount}",
            ),
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

String _syncedKindLabel(String kind, {BuildContext? context}) => switch (kind) {
  'batches' => _optionalSyncText(context, '增量批次', "Incremental batches"),
  'blobs' => _optionalSyncText(context, '数据块', "Blobs"),
  'commits' => _optionalSyncText(context, '提交校验', "Commit verification"),
  'checkpoints' => _optionalSyncText(context, '检查点', "Checkpoints"),
  'acknowledgements' => _optionalSyncText(context, '同步回执', "Sync receipts"),
  'protocol' => _optionalSyncText(context, '协议与设备', "Protocol & devices"),
  'maintenance' => _optionalSyncText(context, '保留与清理', "Retention & cleanup"),
  _ => _optionalSyncText(context, '其他对象', "Other objects"),
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
            remoteRootSegments:
                widget.profile.kind == SyncDatasetKind.velockManaged
                ? VelockSyncProfile.fromEnvelope(
                    widget.profile,
                  ).remoteRootSegments
                : const [],
          );
      if (!mounted) return;
      setState(() => _remote = snapshot);
    } on Object {
      if (!mounted) return;
      setState(
        () => _error = _optionalSyncText(
          context,
          '无法读取远端清单，请检查连接后重试。',
          "Could not read the remote inventory. Check the connection and retry.",
        ),
      );
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
      header: _optionalSyncText(context, '已同步的数据', "Synced data"),
      footer: Text(
        remote != null && remote.totalCount == 0
            ? _optionalSyncText(
                context,
                '远端目前没有这个空间的加密对象。',
                "No encrypted objects for this space are stored remotely yet.",
              )
            : widget.profile.kind == SyncDatasetKind.velockManaged
            ? _optionalSyncText(
                context,
                '格间备份按加密对象统计（批次 / 数据块 / 提交）；原始文件名只在格间 App 内可见。',
                "Velock backup counts encrypted objects (batches / blobs / commits). Original filenames are only visible in Velock.",
              )
            : _optionalSyncText(
                context,
                '按加密对象统计；文件路径不会离开本机。',
                "Counts encrypted objects. File paths never leave this device.",
              ),
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
              AppMetric(
                value: '${snapshot.uploadedCount}',
                label: _optionalSyncText(
                  context,
                  '本机已上传',
                  "Uploaded on this device",
                ),
              ),
              AppMetric(
                value: '${snapshot.downloadedCount}',
                label: _optionalSyncText(
                  context,
                  '本机已恢复',
                  "Restored on this device",
                ),
              ),
              AppMetric(
                value: AppFormat.bytes(snapshot.totalBytes),
                label: _optionalSyncText(
                  context,
                  '本机累计流量',
                  "Total transferred",
                ),
              ),
            ],
          ),
        ),
        if (lastActivity != null)
          SyncedDataRow(
            icon: Icons.schedule_outlined,
            label: _optionalSyncText(context, '最近同步', "Last sync"),
            value: AppFormat.relativeTime(lastActivity, context: context),
          ),
        SyncedDataRow(
          icon: Icons.layers_outlined,
          label: _optionalSyncText(context, '增量批次', "Incremental batches"),
          value: _optionalSyncText(
            context,
            '已发布 ${snapshot.publishedOutgoingCount} · '
                '已应用 ${snapshot.appliedIncomingCount}',
            "Published ${snapshot.publishedOutgoingCount} · Applied ${snapshot.appliedIncomingCount}",
          ),
        ),
        if (pendingTransfers > 0)
          SyncedDataRow(
            icon: Icons.sync_outlined,
            label: _optionalSyncText(context, '待传输对象', "Pending objects"),
            value: _optionalSyncText(
              context,
              '上传 ${snapshot.pendingUploadCount} · '
                  '下载 ${snapshot.pendingDownloadCount}',
              "Upload ${snapshot.pendingUploadCount} · Download ${snapshot.pendingDownloadCount}",
            ),
          ),
        for (final kind in kinds) SyncedKindRow(kind: kind),
        for (final device in snapshot.devices)
          SyncedDataRow(
            icon: Icons.devices_outlined,
            label: _optionalSyncText(
              context,
              '远端设备 ${shortId(device.deviceId)}',
              "Remote device ${shortId(device.deviceId)}",
            ),
            value: _optionalSyncText(
              context,
              '已应用 ${device.appliedSequence} 个增量',
              "Applied ${device.appliedSequence} changes",
            ),
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
            title: Text(
              _optionalSyncText(context, '已同步对象明细', "Synced object details"),
            ),
            subtitle: Text(
              _optionalSyncText(
                context,
                '共 ${widget.history.length} 个对象，最近 ${AppFormat.relativeTime(widget.history.first.completedAt, context: context)}',
                "${widget.history.length} objects; latest ${AppFormat.relativeTime(widget.history.first.completedAt, context: context)}",
              ),
            ),
            showChevron: true,
            onTap: () => showSyncedObjectsSheet(context, widget.history),
          ),
        ],
        if (_queue != null) ...[
          SyncedDataRow(
            icon: Icons.outbox_outlined,
            label: _optionalSyncText(
              context,
              '格间待上传批次',
              "Velock batches awaiting upload",
            ),
            value: _optionalSyncText(
              context,
              '${_queue!.outboxReadyCount} 个',
              "${_queue!.outboxReadyCount}",
            ),
          ),
          SyncedDataRow(
            icon: Icons.move_to_inbox_outlined,
            label: _optionalSyncText(
              context,
              '待格间导入',
              "Awaiting Velock import",
            ),
            value: _optionalSyncText(
              context,
              '${_queue!.inboxReadyCount} 个',
              "${_queue!.inboxReadyCount}",
            ),
          ),
          if (_queue!.velockStatus case final status?
              when status.vaultId == widget.profile.vaultId &&
                  status.needsVelock)
            Padding(
              key: const Key('velock-unpackaged-hint'),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.rowHorizontal,
                vertical: AppSpacing.xs,
              ),
              child: Text(
                status.pendingConflicts > 0
                    ? _optionalSyncText(
                        context,
                        '格间里有 ${status.pendingConflicts} 项内容在两台设备上都被改过，需要你在格间选择保留哪一份：设置 → 云备份。',
                        "${status.pendingConflicts} items were changed on two devices. Choose which version to keep in Velock: Settings → Cloud backup.",
                      )
                    : status.lastFailureAt != null
                    ? _optionalSyncText(
                        context,
                        '格间上次没能把改动交给 Sync。请打开格间，改动交接后再立即备份。',
                        "Velock could not hand its changes to Sync last time. Open Velock, then back up again.",
                      )
                    : _optionalSyncText(
                        context,
                        '格间还有 ${status.unpackagedChanges} 项改动没交给 Sync，所以这里暂时没有要上传的内容。打开格间后会自动交接。',
                        "Velock still holds ${status.unpackagedChanges} changes it has not handed to Sync, so nothing is waiting here yet. Opening Velock hands them over.",
                      ),
                style: AppType.rowSubtitle.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
            ),
          if (_queue!.lastOutboxReceiptAt != null)
            SyncedDataRow(
              icon: Icons.handshake_outlined,
              label: _optionalSyncText(context, '上次数据交接', "Last data handoff"),
              value: AppFormat.relativeTime(
                _queue!.lastOutboxReceiptAt,
                context: context,
              ),
            ),
          if (_queue!.isEmpty &&
              snapshot.uploadedCount == 0 &&
              _queue!.velockStatus?.needsVelock != true)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.rowHorizontal,
                vertical: AppSpacing.xs,
              ),
              child: Text(
                _optionalSyncText(
                  context,
                  '格间目前没有新的待同步内容；在格间里新增或修改数据后会自动排队。',
                  "No new Velock data is waiting to sync. Changes made in Velock are queued automatically.",
                ),
                style: AppType.rowSubtitle.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
            ),
        ],
        SyncedDataRow(
          icon: Icons.cloud_outlined,
          label: _optionalSyncText(context, '远端已保存', "Stored remotely"),
          value: remote == null
              ? _optionalSyncText(context, '未扫描', "Not scanned")
              : _optionalSyncText(
                  context,
                  '${remote.totalCount} 个对象 · ${AppFormat.bytes(remote.totalBytes)}',
                  "${remote.totalCount} objects · ${AppFormat.bytes(remote.totalBytes)}",
                ),
        ),
        if (remote != null && remote.lastUpdatedAt != null)
          SyncedDataRow(
            icon: Icons.update_outlined,
            label: _optionalSyncText(context, '远端最近更新', "Last remote update"),
            value: AppFormat.relativeTime(
              remote.lastUpdatedAt,
              context: context,
            ),
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
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: AppSpacing.rowHorizontal,
              vertical: AppSpacing.xs,
            ),
            child: Text(
              _optionalSyncText(
                context,
                '清单较大，仅统计了前 600 个对象。',
                "Large inventory: only the first 600 objects were counted.",
              ),
            ),
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
                  _optionalSyncText(
                    context,
                    '从远端存储读取实际已保存的加密对象。',
                    "Read the encrypted objects actually stored remotely.",
                  ),
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
                  child: Text(
                    remote == null
                        ? _optionalSyncText(
                            context,
                            '扫描远端',
                            "Scan remote storage",
                          )
                        : _optionalSyncText(context, '重新扫描', "Scan again"),
                  ),
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
          OutlinedButton(
            onPressed: onRetry,
            child: Text(_optionalSyncText(context, '重试', "Retry")),
          ),
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
    showMessage(
      context,
      _optionalSyncText(
        context,
        '无法读取此配置的恢复密钥引用。',
        "Could not read the recovery key reference for this profile.",
      ),
    );
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
      showMessage(
        context,
        _optionalSyncText(
          context,
          '无法生成恢复包；请检查本机密钥状态。',
          "Could not create a recovery package. Check this device’s keys.",
        ),
      );
    }
  }
}

Future<String?> requestProfileRecoveryPassphrase(BuildContext context) async {
  final values = await showAdaptiveTextInputs(
    context: context,
    title: _optionalSyncText(context, '生成恢复包', "Create recovery package"),
    message: _optionalSyncText(
      context,
      '恢复包和口令需通过不同的受保护渠道保存。',
      "Keep the recovery package and passphrase in separate secure locations.",
    ),
    inputs: [
      AdaptiveTextInput(
        label: _optionalSyncText(context, '恢复口令', "Recovery passphrase"),
        placeholder: _optionalSyncText(context, '恢复口令', "Recovery passphrase"),
        obscureText: true,
        autocorrect: false,
      ),
      AdaptiveTextInput(
        label: _optionalSyncText(
          context,
          '再次输入恢复口令',
          "Repeat recovery passphrase",
        ),
        placeholder: _optionalSyncText(
          context,
          '再次输入恢复口令',
          "Repeat recovery passphrase",
        ),
        obscureText: true,
        autocorrect: false,
      ),
    ],
    confirmLabel: _optionalSyncText(context, '生成', "Create"),
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
  title: _optionalSyncText(context, '一次性恢复包', "One-time recovery package"),
  message: _optionalSyncText(
    context,
    '请安全保存。此窗口关闭后应用不会保留或自动复制该恢复包。',
    "Store this securely. After this window closes, the app will not retain or automatically copy the package.",
  ),
  details: SelectableText(recoveryPackage),
  confirmLabel: _optionalSyncText(
    context,
    '我已安全保存',
    "I have saved it securely",
  ),
);

String kindLabel(SyncDatasetKind? kind, {BuildContext? context}) =>
    switch (kind) {
      SyncDatasetKind.selectedFolder => _optionalSyncText(
        context,
        '文件夹同步',
        "Folder sync",
      ),
      SyncDatasetKind.velockManaged => _optionalSyncText(
        context,
        '格间备份',
        "Velock backup",
      ),
      SyncDatasetKind.plainFolder => _optionalSyncText(
        context,
        '文件夹同步',
        "Folder sync",
      ),
      null => _optionalSyncText(context, '不可用', "Unavailable"),
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
      SyncDatasetKind.plainFolder => adaptiveIcon(
        context,
        material: Icons.folder_copy_outlined,
        cupertino: CupertinoIcons.folder,
      ),
      null => adaptiveIcon(
        context,
        material: Icons.error_outline,
        cupertino: CupertinoIcons.exclamationmark_triangle,
      ),
    };

String velockAvailabilityLabel(
  VelockWizardAvailability availability, {
  BuildContext? context,
}) => switch (availability) {
  VelockWizardAvailability.appNotInstalled => _optionalSyncText(
    context,
    '本体未安装',
    "Velock not installed",
  ),
  VelockWizardAvailability.authorizationRequired => _optionalSyncText(
    context,
    '本体未授权',
    "Velock not authorized",
  ),
  VelockWizardAvailability.accessRevoked => _optionalSyncText(
    context,
    '授权已撤销',
    "Access revoked",
  ),
  VelockWizardAvailability.unsupportedVersion => _optionalSyncText(
    context,
    '版本不支持',
    "Unsupported version",
  ),
  VelockWizardAvailability.velockUpdateRequired => _optionalSyncText(
    context,
    '需要更新格间',
    'Update Velock',
  ),
  VelockWizardAvailability.signatureMismatch => _optionalSyncText(
    context,
    '身份验证失败',
    "Verification failed",
  ),
  VelockWizardAvailability.configurationMissing => _optionalSyncText(
    context,
    '本体不可用',
    "Velock unavailable",
  ),
  VelockWizardAvailability.temporarilyUnavailable => _optionalSyncText(
    context,
    '本体暂不可用',
    "Velock temporarily unavailable",
  ),
  VelockWizardAvailability.unsupportedPlatform => _optionalSyncText(
    context,
    '平台不支持',
    "Unsupported platform",
  ),
  VelockWizardAvailability.ready => _optionalSyncText(
    context,
    '已启用',
    "Enabled",
  ),
};

String velockAvailabilitySubtitle(
  VelockWizardAvailability availability, {
  BuildContext? context,
}) => switch (availability) {
  VelockWizardAvailability.appNotInstalled => _optionalSyncText(
    context,
    '请先安装 Velock 本体。',
    "Install Velock first.",
  ),
  VelockWizardAvailability.authorizationRequired => _optionalSyncText(
    context,
    '请在 Velock 本体中重新授权。',
    "Authorize access again in Velock.",
  ),
  VelockWizardAvailability.accessRevoked => _optionalSyncText(
    context,
    '格间已重置或授权被撤销，请移除本配置后重新配对。',
    "Velock was reset or access revoked. Remove this profile and pair again.",
  ),
  VelockWizardAvailability.unsupportedVersion => _optionalSyncText(
    context,
    '请升级 Velock 本体后重试。',
    "Update Velock and retry.",
  ),
  VelockWizardAvailability.velockUpdateRequired => _optionalSyncText(
    context,
    '请把格间更新到 2.0.7 或更高版本，并打开一次。',
    'Update Velock to 2.0.7 or later and open it once.',
  ),
  VelockWizardAvailability.signatureMismatch => _optionalSyncText(
    context,
    '已安装的 Velock 本体无法验证。',
    "The installed Velock app could not be verified.",
  ),
  VelockWizardAvailability.configurationMissing => _optionalSyncText(
    context,
    'Velock 本体的同步通道不可用。',
    "The Velock sync channel is unavailable.",
  ),
  VelockWizardAvailability.temporarilyUnavailable => _optionalSyncText(
    context,
    'Velock 本体暂时无法访问。',
    "Velock is temporarily inaccessible.",
  ),
  VelockWizardAvailability.unsupportedPlatform => _optionalSyncText(
    context,
    '当前平台不支持 Velock 本体。',
    "Velock is not supported on this platform.",
  ),
  VelockWizardAvailability.ready => _optionalSyncText(
    context,
    'Velock 安全空间',
    "Velock secure space",
  ),
};

String transferStateLabel(
  TransferJobState state, {
  BuildContext? context,
}) => switch (state) {
  TransferJobState.queued => _optionalSyncText(context, '等待中', "Queued"),
  TransferJobState.running => _optionalSyncText(context, '进行中', "In progress"),
  TransferJobState.paused => _optionalSyncText(context, '已暂停', "Paused"),
  TransferJobState.retryWaiting => _optionalSyncText(
    context,
    '等待重试',
    "Waiting to retry",
  ),
  TransferJobState.completed => _optionalSyncText(context, '已完成', "Completed"),
  TransferJobState.failed => _optionalSyncText(context, '失败', "Failed"),
  TransferJobState.cancelled => _optionalSyncText(context, '已取消', "Cancelled"),
};

/// One short line under a profile name.
///
/// The section header already names the domain, and the state badge already
/// names the state, so the row only answers "when did it last run" — the long
/// "格间备份 · 后台同步已开启 · 最近成功备份：…" line repeated everything the
/// rest of the row said.
String profileSecondaryText(
  SyncProfileSummary summary, {
  BuildContext? context,
}) {
  final activity = summary.activity;
  if (activity != null && activity.unresolvedConflictCount > 0) {
    return _optionalSyncText(
      context,
      '${activity.unresolvedConflictCount} 个冲突待处理',
      "${activity.unresolvedConflictCount} conflicts to resolve",
    );
  }
  if (activity != null &&
      activity.pendingUploadCount + activity.pendingDownloadCount > 0) {
    return _optionalSyncText(context, '有待传输项目', "Transfers pending");
  }
  final run = activity?.latestRun;
  if (run == null) {
    return summary.kind == SyncDatasetKind.selectedFolder
        ? _optionalSyncText(context, '尚未同步', "Not synced yet")
        : _optionalSyncText(context, '尚未备份', "Not backed up yet");
  }
  if (run.state == 'running') {
    return _optionalSyncText(context, '正在同步…', "Syncing…");
  }
  return AppFormat.relativeTime(
    run.completedAt ?? run.startedAt,
    context: context,
  );
}

String dispatchLabel(
  SyncProfileDispatchStatus status, {
  BuildContext? context,
}) => switch (status) {
  SyncProfileDispatchStatus.completed => _optionalSyncText(
    context,
    '已完成',
    "Completed",
  ),
  SyncProfileDispatchStatus.skippedNotRunnable => _optionalSyncText(
    context,
    '当前状态不允许同步',
    "Sync is not allowed in the current state",
  ),
  SyncProfileDispatchStatus.skippedUnsupported => _optionalSyncText(
    context,
    '此配置不受支持',
    "This profile is not supported",
  ),
  SyncProfileDispatchStatus.failed => _optionalSyncText(
    context,
    '发生错误',
    "An error occurred",
  ),
};

String velockReadinessTitle(
  VelockWizardAvailability availability, {
  BuildContext? context,
}) => switch (availability) {
  VelockWizardAvailability.ready => _optionalSyncText(
    context,
    '可以开始 Velock 安全配对',
    "Ready for secure Velock pairing",
  ),
  VelockWizardAvailability.appNotInstalled => _optionalSyncText(
    context,
    '未找到 Velock App',
    "Velock app not found",
  ),
  VelockWizardAvailability.authorizationRequired => _optionalSyncText(
    context,
    '需要在 Velock 中授权',
    "Authorization required in Velock",
  ),
  VelockWizardAvailability.accessRevoked => _optionalSyncText(
    context,
    'Velock 已撤销授权',
    "Velock revoked access",
  ),
  VelockWizardAvailability.unsupportedVersion => _optionalSyncText(
    context,
    'Velock 版本不受支持',
    "Unsupported Velock version",
  ),
  VelockWizardAvailability.velockUpdateRequired => velockUpdateRequiredTitle(
    context,
  ),
  VelockWizardAvailability.signatureMismatch => _optionalSyncText(
    context,
    'Velock 身份验证失败',
    "Velock identity verification failed",
  ),
  VelockWizardAvailability.configurationMissing => _optionalSyncText(
    context,
    '配对通道尚未配置',
    "Pairing channel not configured",
  ),
  VelockWizardAvailability.temporarilyUnavailable => _optionalSyncText(
    context,
    'Velock 暂时不可用',
    "Velock temporarily unavailable",
  ),
  VelockWizardAvailability.unsupportedPlatform =>
    velockUnsupportedPlatformTitle(context),
};

String velockReadinessMessage(
  VelockWizardAvailability availability, {
  BuildContext? context,
}) => switch (availability) {
  VelockWizardAvailability.ready => _optionalSyncText(
    context,
    '下一步会打开格间。请解锁格间，并确认允许 Sync 为它备份；确认前不会保存任何设置。',
    'Next, Velock opens. Unlock it and confirm that Sync may back it up. Nothing is saved before you confirm.',
  ),
  VelockWizardAvailability.appNotInstalled => _optionalSyncText(
    context,
    '这台设备上还没有格间。请先安装并打开格间，再回来继续。',
    'Velock is not on this device yet. Install and open it, then come back.',
  ),
  VelockWizardAvailability.authorizationRequired => _optionalSyncText(
    context,
    '请打开格间 → 设置 → 云备份，打开「允许 Sync 连接」，再回来继续。',
    'Open Velock → Settings → Cloud backup, turn on “Allow Sync to connect”, then come back.',
  ),
  VelockWizardAvailability.accessRevoked => _optionalSyncText(
    context,
    '格间已取消对这台设备上 Sync 的授权。请重新连接格间，并在格间里再次允许。',
    'Velock withdrew this Sync’s permission. Connect to Velock again and allow it there.',
  ),
  VelockWizardAvailability.unsupportedVersion => _optionalSyncText(
    context,
    '当前的格间版本太旧，无法连接。请更新格间后再试。',
    'This Velock version is too old to connect. Update Velock and try again.',
  ),
  VelockWizardAvailability.velockUpdateRequired => velockUpdateRequiredMessage(
    context,
  ),
  VelockWizardAvailability.signatureMismatch => _optionalSyncText(
    context,
    '无法确认这是正版格间，为保护你的数据，已停止连接。请从官方渠道安装格间。',
    'This could not be verified as a genuine Velock, so Sync stopped to protect your data. Install Velock from the official source.',
  ),
  VelockWizardAvailability.configurationMissing => _optionalSyncText(
    context,
    '格间还没有准备好连接。请打开格间 → 设置 → 云备份，打开「允许 Sync 连接」，再回来继续。',
    'Velock is not ready to connect yet. Open Velock → Settings → Cloud backup, turn on “Allow Sync to connect”, then come back.',
  ),
  VelockWizardAvailability.temporarilyUnavailable => _optionalSyncText(
    context,
    '暂时连不上格间。请打开并解锁格间，再回来重试；没有保存任何设置。',
    'Velock cannot be reached right now. Open and unlock it, then try again. Nothing was saved.',
  ),
  VelockWizardAvailability.unsupportedPlatform =>
    velockUnsupportedPlatformMessage(context),
};

String conflictLabel(String type, {BuildContext? context}) => switch (type
    .split(':')
    .first) {
  'modify-modify' => _optionalSyncText(
    context,
    '两个设备都修改了内容',
    "Both devices edited this content",
  ),
  'delete-modify' => _optionalSyncText(
    context,
    '删除与修改发生冲突',
    "Deletion conflicts with an edit",
  ),
  _ => _optionalSyncText(context, '需要处理的同步冲突', "Sync conflict needs attention"),
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

// Omitted context preserves the legacy Chinese-only formatter API.
String _optionalSyncText(BuildContext? context, String zh, String en) =>
    context == null ? zh : syncText(context, zh, en);
