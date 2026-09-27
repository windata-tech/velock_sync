import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/widgets/velock_brand_mark.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/app_format.dart';

/// Spacious native surfaces with one next action, not a technical dashboard.
class BackupCard extends StatelessWidget {
  const BackupCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: context.appGroupedSurface,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: context.appSeparator.withValues(alpha: .15)),
    ),
    child: DefaultTextStyle(
      style: Theme.of(context).textTheme.bodyLarge!.copyWith(
        color: Theme.of(context).colorScheme.onSurface,
        fontSize: 16,
        height: 1.4,
      ),
      child: child,
    ),
  );
}

class BackupActionButton extends StatelessWidget {
  const BackupActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.secondary = false,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool secondary;

  /// Shows an inline spinner and blocks re-entry while the action runs, so a
  /// long transfer never needs a modal progress dialog.
  final bool busy;
  @override
  Widget build(BuildContext context) {
    final color = secondary
        ? context.appPrimary.withValues(alpha: .09)
        : context.appPrimary;
    return SizedBox(
      width: double.infinity,
      child: CupertinoButton(
        color: color,
        borderRadius: BorderRadius.circular(14),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        onPressed: busy ? null : onPressed,
        // The idle button keeps its original single-Text layout: wrapping it in
        // a Row unconditionally shifted the surrounding lists by a hair and
        // broke hit tests on sibling rows.
        child: busy
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        secondary ? context.appPrimary : Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: secondary ? context.appPrimary : Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              )
            : Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: secondary ? context.appPrimary : Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}

class BackupWelcomeCard extends StatelessWidget {
  const BackupWelcomeCard({super.key, required this.onStart});
  final VoidCallback onStart;
  @override
  Widget build(BuildContext context) => BackupCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CloudMark(
          icon: CupertinoIcons.cloud_upload,
          color: context.appPrimary,
        ),
        const SizedBox(height: 22),
        Text(
          syncText(
            context,
            '给格间的数据\n留一份云端备份',
            'A cloud copy of\nyour Velock data',
          ),
          style: TextStyle(
            fontSize: 28,
            height: 1.22,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          syncText(
            context,
            '手机丢了、换了，也能找回来。\n格间负责加密，Sync 负责上传。',
            'Keep a copy for a lost or new phone.\nVelock encrypts your data. Sync transfers it to your cloud.',
          ),
          style: TextStyle(
            fontSize: 16,
            height: 1.5,
            color: context.appSecondaryLabel,
          ),
        ),
        const SizedBox(height: 24),
        BackupActionButton(
          key: const Key('velock-backup-enable'),
          label: syncText(context, '开始备份', 'Start backup'),
          onPressed: onStart,
        ),
        const SizedBox(height: 14),
        Text(
          syncText(
            context,
            '文件、照片、账号、卡片、笔记和文档',
            'Files, photos, passwords, cards, notes and documents',
          ),
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: context.appSecondaryLabel,
          ),
        ),
      ],
    ),
  );
}

class BackupStatusCard extends StatelessWidget {
  const BackupStatusCard({
    super.key,
    required this.presentation,
    required this.name,
    required this.onAction,
    this.isVelock = true,
    this.actionLabel,
    this.secondaryLabel,
    this.onSecondary,
    this.secondaryKey,
  });
  final BackupPresentation presentation;
  final String name;
  final VoidCallback? onAction;
  final bool isVelock;
  final String? actionLabel;

  /// Optional second action shown beside the primary one, inside the card.
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final Key? secondaryKey;

  @override
  Widget build(BuildContext context) {
    final stage = presentation.stage;
    final good = stage == BackupStage.lastTransferCompleted;
    final attention =
        stage == BackupStage.needsAttention || stage == BackupStage.needsVelock;
    final color = attention
        ? AppColors.warning
        : good
        ? AppColors.success
        : context.appPrimary;
    final title = switch (stage) {
      BackupStage.notStarted => syncText(
        context,
        isVelock ? '还没有完成首次备份' : '还没有开始同步',
        isVelock ? 'Your first backup is next' : 'Ready for your first sync',
      ),
      BackupStage.transferring => syncText(
        context,
        '正在传输，请稍候',
        'Transferring your data',
      ),
      BackupStage.needsAttention => syncText(
        context,
        presentation.action == BackupAction.reviewHistory
            ? '云端备份不完整'
            : presentation.action == BackupAction.checkStorage
            ? '云端位置需要检查'
            : '有一件事需要你处理',
        presentation.action == BackupAction.reviewHistory
            ? 'Cloud backup is incomplete'
            : presentation.action == BackupAction.checkStorage
            ? 'Cloud location needs checking'
            : 'Your attention is needed',
      ),
      BackupStage.needsVelock => syncText(
        context,
        '需要连接格间',
        'Connect to Velock',
      ),
      BackupStage.paused => syncText(
        context,
        isVelock ? '备份已暂停' : '同步已暂停',
        isVelock ? 'Backup is paused' : 'Sync is paused',
      ),
      BackupStage.pending => syncText(
        context,
        '有内容等待传输',
        'Changes are waiting',
      ),
      BackupStage.waitingForRestore => syncText(
        context,
        '已下载，等待格间恢复',
        'Downloaded. Open Velock to restore',
      ),
      // The stage is shared, but each domain names its own task.
      BackupStage.lastTransferCompleted => syncText(
        context,
        isVelock ? '上次备份已完成' : '上次同步已完成',
        isVelock ? 'Last backup completed' : 'Last sync completed',
      ),
    };
    final description = switch (stage) {
      BackupStage.notStarted => syncText(
        context,
        '保存位置已选好。现在开始，让数据真正传到云端。',
        'Your cloud location is ready. Start now to transfer your data.',
      ),
      BackupStage.transferring => syncText(
        context,
        '完成前请保持 Sync 打开。离开后，系统可能暂停传输。',
        'Keep Sync open until it finishes. The system may pause transfers in the background.',
      ),
      BackupStage.needsAttention =>
        presentation.action == BackupAction.reviewHistory
            ? syncText(
                context,
                '当前保存位置缺少以前的备份记录，这次备份未完成。先了解原因，再核对保存位置。',
                'Earlier backup records are missing from this location. This backup did not finish. Review the next steps and check the location.',
              )
            : presentation.action == BackupAction.resolve
            ? syncText(
                context,
                '两台设备修改了同一份内容，请选择要保留的版本。',
                'The same item was changed on two devices. Choose which version to keep.',
              )
            : backupFailureMessage(context, presentation.errorCode),
      BackupStage.needsVelock => switch (presentation.availability) {
        VelockWizardAvailability.appNotInstalled => syncText(
          context,
          '这台设备上还没有找到格间。请先安装格间，再回来连接。',
          'Velock was not found on this device. Install it, then return to connect.',
        ),
        VelockWizardAvailability.unsupportedVersion => syncText(
          context,
          '当前格间版本不支持连接，请更新格间和 Sync 后重试。',
          'This Velock version cannot connect. Update Velock and Sync, then try again.',
        ),
        VelockWizardAvailability.signatureMismatch => syncText(
          context,
          '无法验证格间的身份，已停止传输以保护数据。请使用可信的格间和 Sync 版本。',
          'Velock’s identity could not be verified. Transfers stopped to protect your data. Use trusted versions of both apps.',
        ),
        VelockWizardAvailability.unsupportedPlatform => syncText(
          context,
          '当前平台暂不支持格间备份，请在受支持的设备上使用。普通文件同步不受影响。',
          'Velock backup is not supported on this platform yet. Use a supported device. Ordinary file sync is separate.',
        ),
        VelockWizardAvailability.accessRevoked => syncText(
          context,
          '格间已撤销此前的授权。请在管理中重新连接，已有云端数据不会因此删除。',
          'Velock revoked the previous authorization. Reconnect in Manage. Existing cloud data will not be deleted.',
        ),
        _ => syncText(
          context,
          '请打开格间，解锁后允许 Sync 备份，再回来继续。已有云端数据不会因此删除。',
          'Open and unlock Velock, allow Sync to back up, then return. This does not delete cloud data.',
        ),
      },
      BackupStage.paused => syncText(
        context,
        '已有数据不会因暂停而删除。你可以随时继续。',
        'Pausing does not delete existing data. Continue whenever you are ready.',
      ),
      BackupStage.pending => syncText(
        context,
        '这些内容还没有全部传完，点下方按钮继续。',
        'These changes have not all been transferred. Continue below.',
      ),
      BackupStage.waitingForRestore => syncText(
        context,
        '云端数据已到达这台设备，还需要在格间中解锁并完成恢复。',
        'Cloud data has reached this device. Unlock Velock to finish restoring it.',
      ),
      BackupStage.lastTransferCompleted => syncText(
        context,
        isVelock ? '有新内容时，先打开格间，再回来备份。' : '随时再同步，检查两端有没有新内容。',
        isVelock
            ? 'After making changes, open Velock, then come back to back up.'
            : 'Sync again whenever you want to check for changes.',
      ),
    };
    final action =
        actionLabel ??
        switch (presentation.action) {
          BackupAction.openVelock => syncText(context, '打开格间', 'Open Velock'),
          BackupAction.resume => syncText(context, '继续', 'Resume'),
          BackupAction.reviewHistory => syncText(
            context,
            '查看原因和下一步',
            'See why and what to do',
          ),
          BackupAction.checkStorage => syncText(
            context,
            '检查保存位置',
            'Check cloud location',
          ),
          BackupAction.manage => syncText(context, '查看并处理', 'Review and fix'),
          BackupAction.resolve => syncText(
            context,
            '选择保留的内容',
            'Review changes',
          ),
          BackupAction.transfer =>
            stage == BackupStage.transferring
                ? syncText(context, '正在传输…', 'Transferring…')
                : syncText(
                    context,
                    isVelock ? '立即备份' : '立即同步',
                    isVelock ? 'Back up now' : 'Sync now',
                  ),
        };
    return BackupCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _CloudMark(
                icon: attention
                    ? CupertinoIcons.exclamationmark_shield
                    : good
                    ? CupertinoIcons.checkmark_shield
                    : CupertinoIcons.cloud_upload,
                color: color,
                branded: isVelock,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: context.appSecondaryLabel,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Semantics(
            liveRegion: true,
            child: Text(
              title,
              key: const Key('backup-status-title'),
              style: TextStyle(
                fontSize: 25,
                height: 1.25,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            description,
            style: TextStyle(
              fontSize: 16,
              height: 1.45,
              color: context.appSecondaryLabel,
            ),
          ),
          if (presentation.failedAt != null) ...[
            const SizedBox(height: 12),
            Text(
              syncText(
                context,
                '上次失败：${AppFormat.stamp(presentation.failedAt)}',
                'Last failure: ${AppFormat.stamp(presentation.failedAt)}',
              ),
              style: TextStyle(fontSize: 14, color: color),
            ),
          ],
          if (presentation.completedAt != null) ...[
            const SizedBox(height: 12),
            Text(
              AppFormat.stamp(presentation.completedAt),
              style: TextStyle(fontSize: 14, color: color),
            ),
          ],
          const SizedBox(height: 24),
          if (secondaryLabel == null)
            BackupActionButton(
              key: const Key('backup-primary-action'),
              label: action,
              busy: stage == BackupStage.transferring,
              onPressed: stage == BackupStage.transferring ? null : onAction,
            )
          else
            Row(
              children: [
                Expanded(
                  child: BackupActionButton(
                    key: const Key('backup-primary-action'),
                    label: action,
                    busy: stage == BackupStage.transferring,
                    onPressed: stage == BackupStage.transferring
                        ? null
                        : onAction,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: BackupActionButton(
                    key: secondaryKey,
                    label: secondaryLabel!,
                    secondary: true,
                    onPressed: onSecondary,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

String backupFailureMessage(BuildContext context, String? code) {
  if (code == 'provider.webdav.collection_not_writable') {
    return uncreatableFolderMessage(context);
  }
  if (code == null || code.isEmpty) {
    return syncText(
      context,
      '传输还未完成。请查看连接和详细记录，处理后再试。',
      'The transfer has not finished. Review the connection and details, then try again.',
    );
  }
  return AppFormat.errorSummary(code, context: context);
}

class _CloudMark extends StatelessWidget {
  const _CloudMark({
    required this.icon,
    required this.color,
    this.branded = false,
  });
  final IconData icon;
  final Color color;

  /// Velock shows its real brand mark here instead of a generic shield; the
  /// state colour stays on the badge and the text around it.
  final bool branded;

  @override
  Widget build(BuildContext context) => Container(
    width: 56,
    height: 56,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: branded
          ? context.appGroupedSurface
          : color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(18),
      border: branded
          ? Border.all(color: context.appSeparator.withValues(alpha: .25))
          : null,
    ),
    child: branded
        ? const VelockBrandMark(size: 32)
        : Icon(icon, color: color, size: 28),
  );
}
