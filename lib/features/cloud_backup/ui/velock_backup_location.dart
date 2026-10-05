import 'package:material_ui/material_ui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/cloud_backup/application/backup_destination_service.dart';
import 'package:velock_sync/features/cloud_backup/ui/velock_backup_rebuild.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';

/// Lets the user point one Velock backup at another folder of the same
/// connection, and saves only that.
///
/// Shared by the recovery-history help and the manage tab. History discovery
/// stays read-only; management also allows explicitly creating an empty folder.
/// Both require confirmation before saving the profile's `remoteRootSegments`.
/// It never edits the shared connection, starts a sync, or migrates/deletes data.
///
/// The result of one relocation attempt. A refused save is reported instead of
/// announced, so each caller can present it in its own idiom (inline feedback
/// on the help page, a message on the manage tab).
typedef BackupLocationChange = ({
  SyncProfileEnvelope? profile,
  bool saveFailed,
});

Future<BackupLocationChange> changeVelockBackupLocation(
  BuildContext context,
  WidgetRef ref, {
  required SyncProfileEnvelope profile,
  required ConnectionModel connection,
  bool requireExistingBackup = false,
}) async {
  final protocol = connection.protocol;
  if (protocol is! WebDavProtocolModel) {
    await showAdaptiveNotice(
      context: context,
      title: syncText(context, '这个连接不能更改目录', 'This connection cannot move'),
      message: syncText(
        context,
        '只有 WebDAV 连接可以更换备份目录。请先添加一个 WebDAV 连接，再重新建立备份。',
        'Only WebDAV connections can change their backup folder. Add a WebDAV connection and set the backup up again.',
      ),
      confirmLabel: syncText(context, '知道了', 'OK'),
    );
    return (profile: null, saveFailed: false);
  }

  final loader = ref.read(backupFolderLoaderProvider);
  final paired = VelockSyncProfile.fromEnvelope(profile);
  // A backup that already has history in its folder cannot just be pointed
  // at an empty one: every later run would stop with "history missing".
  // Moving there means building a complete new backup instead.
  final hasHistory =
      !requireExistingBackup &&
      await ref
          .read(syncStateDatabaseProvider)
          .hasExchangedHistory(profile.profileId);
  if (!context.mounted) return (profile: null, saveFailed: false);
  List<String> segments;
  while (true) {
    final picked = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => BackupFolderPicker(
          connectionName: connection.name,
          basePath: backupPathFor(connection, const []) ?? connection.target,
          initialSegments: paired.remoteRootSegments,
          restoring: requireExistingBackup,
          loadFolders: (segments) =>
              loader(protocol: protocol, relativeSegments: segments),
          createFolder: requireExistingBackup
              ? null
              : (segments, name) => ref.read(backupFolderCreatorProvider)(
                  protocol: protocol,
                  relativeSegments: segments,
                  name: name,
                ),
        ),
      ),
    );
    if (picked == null || !context.mounted) {
      return (profile: null, saveFailed: false);
    }
    segments = picked;
    if (!requireExistingBackup && !hasHistory) break;
    if (!requireExistingBackup &&
        VelockSyncProfile.canonicalRemoteRootSegments(segments).join('/') ==
            paired.remoteRootSegments.join('/')) {
      // Same folder: nothing to change.
      return (profile: null, saveFailed: false);
    }

    // Discovery only: no probe, profile mutation, or sync. The runner still
    // verifies complete history and contents after the explicit backup action.
    String? problem;
    try {
      await ref
          .read(backupDestinationServiceProvider)
          .check(
            connectionId: profile.connectionId,
            vaultId: profile.vaultId,
            trustedProducerIds: paired.trustedProducerIds,
            restoring: true,
            remoteRootSegments: segments,
          );
    } on Object catch (error) {
      problem =
          error is BackupDestinationException &&
              error.code == 'backup_not_found'
          ? 'absent'
          : 'unreadable';
    }
    if (!context.mounted) return (profile: null, saveFailed: false);
    if (problem == null) break;

    final path = backupPathFor(connection, segments) ?? connection.target;
    if (problem == 'absent' && !requireExistingBackup) {
      // The folder the user wants simply has no copy of this backup yet:
      // offer to make one there, which is what moving the backup means.
      final rebuild = await showAdaptiveConfirmation(
        context,
        title: syncText(
          context,
          '在这里建立完整备份？',
          'Create a complete backup here?',
        ),
        message:
            '${connection.name}\n$path\n\n'
            '${syncText(context, '这个文件夹里还没有这份备份。格间会把现在的全部内容重新打包，上传到这里，校验完成后才改用这个文件夹。原来的备份不会被删除。', 'This folder has no copy of this backup yet. Velock packs everything it has now and uploads it here; the backup switches to this folder only after it is verified. The original backup is not deleted.')}',
        confirmLabel: syncText(context, '建立完整备份', 'Create backup'),
        confirmKey: const Key('backup-location-rebuild'),
        cancelLabel: syncText(context, '换一个文件夹', 'Choose another'),
      );
      if (!context.mounted) return (profile: null, saveFailed: false);
      if (rebuild) {
        await showVelockBackupRebuild(
          context,
          ref,
          profile,
          destination: segments,
        );
        return (profile: null, saveFailed: false);
      }
      continue;
    }
    final again = await showAdaptiveConfirmation(
      context,
      title: problem == 'absent'
          ? syncText(context, '这里没有找到原备份', 'Original backup not found here')
          : syncText(context, '暂时读不到这个文件夹', 'Could not read this folder'),
      message: problem == 'absent'
          ? syncText(
              context,
              '$path 里没有这个格间账号的备份。请选以前备份成功时用的文件夹。',
              'There is no backup of this Velock account in $path. Choose the folder a previous backup succeeded in.',
            )
          : syncText(
              context,
              '读取 $path 失败。请检查网络和连接后重新选择。',
              'Reading $path failed. Check the network and connection, then choose again.',
            ),
      confirmLabel: syncText(context, '重新选择', 'Choose again'),
      confirmKey: const Key('backup-location-choose-again'),
      cancelLabel: syncText(context, '取消', 'Cancel'),
    );
    if (!again || !context.mounted) {
      return (profile: null, saveFailed: false);
    }
  }

  final confirmed = await showAdaptiveConfirmation(
    context,
    title: syncText(context, '改用这个文件夹？', 'Use this folder?'),
    message:
        '${connection.name}\n${backupPathFor(connection, segments) ?? connection.target}\n\n'
        '${syncText(context, '只保存这份备份的位置，不启动同步、不上传或下载数据，也不删除原目录。旧目录里的数据不会自动迁移。', 'Only save this backup’s location. No sync, upload, download or deletion is started. Data in the old folder is not migrated.')}',
    confirmLabel: syncText(context, '保存位置', 'Save location'),
    confirmKey: const Key('backup-location-confirm'),
  );
  if (!confirmed || !context.mounted) {
    return (profile: null, saveFailed: false);
  }

  try {
    final updated = await ref
        .read(syncProfileRepositoryProvider)
        .selectOriginalVelockFolder(expected: profile, segments: segments);
    return (profile: updated, saveFailed: false);
  } on Object {
    return (profile: null, saveFailed: true);
  }
}

/// Absolute path of a folder inside [connection], used in the confirmations.
///
/// WebDAV connections resolve to a real path; other providers have no path to
/// show, so the caller falls back to its own wording.
String? backupPathFor(ConnectionModel connection, List<String> segments) {
  final scoped = RemoteObjectStoreFactory.scopeProtocol(
    connection.protocol,
    segments,
  );
  if (scoped is! WebDavProtocolModel) return null;
  final parts = RemoteObjectStoreFactory.webDavUri(
    scoped,
  ).pathSegments.where((segment) => segment.isNotEmpty);
  return '/${parts.join('/')}';
}
