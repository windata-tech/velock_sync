import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';

/// App launch is injectable; a failed launch never counts as authorization.
final velockAppLauncherProvider = Provider<Future<bool> Function()>(
  (ref) =>
      () => launchUrl(
        Uri.parse('velock://open'),
        mode: LaunchMode.externalApplication,
      ),
);

/// Backup-settings deep link launcher for the recovery card and authorized
/// devices entry. Injectable for tests; the fixed URI carries no query and no
/// requestId, so this management entry never creates or reads pairing
/// requests. A failed launch never counts as authorization or success.
final velockBackupSettingsLauncherProvider = Provider<Future<bool> Function()>(
  (ref) =>
      () => launchUrl(
        Uri.parse('velock://sync-settings'),
        mode: LaunchMode.externalApplication,
      ),
);

Future<void> openVelockForBackup(BuildContext context, WidgetRef ref) async {
  var opened = false;
  try {
    opened = await ref.read(velockAppLauncherProvider)();
  } on Object {
    /* UI below */
  }
  if (!opened && context.mounted) {
    await showAdaptiveAlert<void>(
      context: context,
      title: syncText(context, '请打开格间', 'Open Velock'),
      message: syncText(
        context,
        '请先安装并打开格间，解锁后进入「云备份」。完成后回到 Sync 继续。',
        'Install and open Velock, unlock it, then open Cloud backup. Return to Sync to continue.',
      ),
      actions: [
        AdaptiveAlertAction<void>(
          label: syncText(context, '知道了', 'OK'),
          isDefault: true,
        ),
      ],
    );
  }
}

/// Opens Velock's cloud-backup settings directly for the recovery card and
/// authorized devices. Falls back to a manual instruction when the deep link
/// is unavailable; the fallback only informs the user and never counts as
/// authorization or success.
Future<void> openVelockBackupSettings(
  BuildContext context,
  WidgetRef ref,
) async {
  var opened = false;
  try {
    opened = await ref.read(velockBackupSettingsLauncherProvider)();
  } on Object {
    /* fall through to the manual fallback below */
  }
  if (!opened && context.mounted) {
    await showAdaptiveAlert<void>(
      context: context,
      title: syncText(context, '无法打开格间', 'Could not open Velock'),
      message: syncText(
        context,
        '请打开格间，解锁后进入设置中的云备份，查看恢复卡与已授权设备',
        'Open Velock, unlock it, then open Cloud backup in Settings to view the recovery card and authorized devices.',
      ),
      actions: [
        AdaptiveAlertAction<void>(
          label: syncText(context, '知道了', 'OK'),
          isDefault: true,
        ),
      ],
    );
  }
}
