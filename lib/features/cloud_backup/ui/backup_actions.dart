import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/application/velock_snapshot_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';

/// Backup entry opens Cloud backup, including after unlocking Velock. Merely
/// waking the app with velock://open would leave users on its previous page.
/// Launch is injectable; a failed launch never counts as authorization.
final velockAppLauncherProvider = Provider<Future<bool> Function()>(
  (ref) => ref.watch(velockBackupSettingsLauncherProvider),
);

/// Velock's App Store page. Velock Sync only backs up Velock, so when Velock
/// is missing the useful next step is getting it. Injectable for tests.
const velockAppStoreUrl = 'https://apps.apple.com/app/id6748689303';

final velockAppStoreLauncherProvider = Provider<Future<bool> Function()>(
  (ref) =>
      () => launchUrl(
        Uri.parse(velockAppStoreUrl),
        mode: LaunchMode.externalApplication,
      ),
);

/// Opens Velock's App Store page; says where to find it when that fails.
Future<void> openVelockAppStore(BuildContext context, WidgetRef ref) async {
  var opened = false;
  try {
    opened = await ref.read(velockAppStoreLauncherProvider)();
  } on Object {
    /* UI below */
  }
  if (!opened && context.mounted) {
    await showAdaptiveNotice(
      context: context,
      title: syncText(
        context,
        '无法打开 App Store',
        'Could not open the App Store',
      ),
      message: syncText(
        context,
        '请在 App Store 搜索「格间」安装。',
        'Search for "Velock" in the App Store to install it.',
      ),
    );
  }
}

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

Future<void> openVelockForBackup(
  BuildContext context,
  WidgetRef ref, {
  String? profileId,
}) async {
  var opened = false;
  try {
    final envelope = profileId == null
        ? null
        : await ref.read(syncProfileRepositoryProvider).read(profileId);
    if (envelope?.dataset['snapshotRestoreRequestId'] != null) {
      await ref.read(velockSnapshotRecoveryServiceProvider).open(profileId!);
      opened = true;
    } else {
      opened = await ref.read(velockAppLauncherProvider)();
    }
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
