import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/model/backup_presentation.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_actions.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_connection_fix.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_history_help.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_storage_help.dart';
import 'package:velock_sync/features/cloud_backup/ui/velock_backup_rebuild.dart';

/// Carries out a fix picked in a failure alert, for pages that have no
/// status card of their own (the setup wizard). [retry] runs the backup again.
Future<void> runBackupFix(
  BuildContext context,
  WidgetRef ref, {
  required String profileId,
  required BackupAction action,
  Future<void> Function()? retry,
}) async {
  final profile = await ref.read(syncProfileRepositoryProvider).read(profileId);
  if (profile == null || !context.mounted) return;
  switch (action) {
    case BackupAction.rebuildBackup:
      await showVelockBackupRebuild(context, ref, profile);
    case BackupAction.reviewHistory:
      await showBackupHistoryHelp(context, profile);
    case BackupAction.checkStorage:
      await showBackupStorageHelp(context, profile);
    case BackupAction.fixConnection:
      if (await editBackupConnection(context, ref, profile.connectionId)) {
        await retry?.call();
      }
    case BackupAction.openVelock:
      await openVelockForBackup(context, ref, profileId: profileId);
    case BackupAction.getVelock:
      await openVelockAppStore(context, ref);
    case BackupAction.transfer:
      await retry?.call();
    case BackupAction.manage:
    case BackupAction.resolve:
    case BackupAction.resume:
      await context.push('/sync-profiles/$profileId');
  }
}
