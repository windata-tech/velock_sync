import 'package:material_ui/material_ui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/cloud_backup/application/backup_destination_service.dart';
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
  final segments = await Navigator.of(context).push<List<String>>(
    MaterialPageRoute(
      builder: (_) => BackupFolderPicker(
        connectionName: connection.name,
        basePath: backupPathFor(connection, const []) ?? connection.target,
        initialSegments: VelockSyncProfile.fromEnvelope(
          profile,
        ).remoteRootSegments,
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
  if (segments == null || !context.mounted) {
    return (profile: null, saveFailed: false);
  }

  if (requireExistingBackup) {
    final paired = VelockSyncProfile.fromEnvelope(profile);
    try {
      // Discovery only: no probe, profile mutation, or sync. The runner still
      // verifies complete history and contents after the explicit backup action.
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
      if (!context.mounted) return (profile: null, saveFailed: false);
      final absent =
          error is BackupDestinationException &&
          error.code == 'backup_not_found';
      await showAdaptiveNotice(
        context: context,
        title: syncText(
          context,
          absent ? '这里没有找到原备份' : '暂时无法检查这个文件夹',
          absent
              ? 'Original backup not found here'
              : 'Could not check this folder',
        ),
        message: syncText(
          context,
          absent
              ? '这个文件夹里没有找到当前格间账号的备份记录。已有文件夹不一定是原备份位置，请选择以前备份成功时使用的目录。保存位置未更改。'
              : '无法读取备份记录，请检查连接和访问权限后再试。保存位置未更改。',
          absent
              ? 'No backup records for this Velock account were found here. An existing folder is not necessarily the original backup folder. Choose the location of a previous successful backup. The saved location has not changed.'
              : 'Backup records could not be read. Check the connection and access permissions, then try again. The saved location has not changed.',
        ),
        confirmLabel: syncText(context, '知道了', 'OK'),
      );
      return (profile: null, saveFailed: false);
    }
    if (!context.mounted) return (profile: null, saveFailed: false);
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
