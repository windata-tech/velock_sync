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
