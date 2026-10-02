import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/application/backup_destination_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace_shared.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'backup_connection_fix.dart';
import 'backup_folder_picker.dart';
import 'velock_backup_location.dart';
import 'backup_widgets.dart';

Future<void> showBackupStorageHelp(
  BuildContext context,
  SyncProfileEnvelope profile,
) => Navigator.of(context).push<void>(
  isApplePlatform(context)
      ? CupertinoPageRoute(builder: (_) => BackupStorageHelp(profile: profile))
      : MaterialPageRoute(builder: (_) => BackupStorageHelp(profile: profile)),
);

/// Opening is read-only. Checking is an explicit, bounded non-content probe;
/// successful checking neither clears the failed run nor starts a transfer.
/// Choosing another folder only saves this task's own location.
class BackupStorageHelp extends ConsumerStatefulWidget {
  const BackupStorageHelp({super.key, required this.profile});
  final SyncProfileEnvelope profile;
  @override
  ConsumerState<BackupStorageHelp> createState() => _BackupStorageHelpState();
}

class _BackupStorageHelpState extends ConsumerState<BackupStorageHelp> {
  late Future<ConnectionModel?> connection = ref
      .read(connectionRepositoryProvider)
      .getConnectionById(widget.profile.connectionId);
  late final bool fileSync =
      widget.profile.kind == SyncDatasetKind.selectedFolder;
  SelectedFolderSyncProfile? fileSyncProfile;
  bool fileSyncProfileLoaded = false;
  bool busy = false;
  bool checked = false;
  bool checkFailed = false;

  /// Error code of the last failed check; decides which fix is offered first.
  String? failureCode;

  /// The Velock profile as last saved here, so a new folder takes effect at
  /// once without leaving the page.
  late SyncProfileEnvelope velockProfile = widget.profile;
  String? feedback;

  bool get canRelocate =>
      fileSyncProfile != null && fileSyncProfile!.remoteRootSegments.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (fileSync) _loadFileSyncProfile();
    _showLastFailure();
  }

  /// Says up front why the page was opened, from the last recorded run only:
  /// nothing is sent to the server until the user asks for a check.
  Future<void> _showLastFailure() async {
    try {
      final run = await ref
          .read(syncStateDatabaseProvider)
          .latestSyncRun(widget.profile.profileId);
      final code = run?.state == 'failed' ? run?.errorCode : null;
      if (code == null || !mounted || feedback != null || busy) return;
      setState(() => _showFailure(code));
    } on Object {
      // Without a record the page simply starts at the location.
    }
  }

  void _showFailure(String code) {
    checkFailed = true;
    failureCode = code;
    feedback = _unwritable(code)
        ? syncText(
            context,
            '这个文件夹不能写入。请换一个这个账号有写入权限的文件夹。',
            'This folder cannot be written. Choose a folder this account can write to.',
          )
        : backupFailureMessage(context, code);
  }

  Future<void> _loadFileSyncProfile() async {
    try {
      final profile = await ref
          .read(selectedFolderProfilesProvider)
          .read(widget.profile.profileId);
      if (mounted) {
        setState(() {
          fileSyncProfile = profile;
          fileSyncProfileLoaded = true;
        });
      }
    } on Object {
      // The page stays usable for checking; it just cannot offer relocation.
      if (mounted) {
        setState(() {
          fileSyncProfile = null;
          fileSyncProfileLoaded = true;
        });
      }
    }
  }

  List<String> get segments => fileSync
      ? (fileSyncProfile?.remoteRootSegments ?? const [])
      : VelockSyncProfile.fromEnvelope(velockProfile).remoteRootSegments;

  String location(ConnectionModel value) {
    final protocol = RemoteObjectStoreFactory.scopeProtocol(
      value.protocol,
      segments,
    );
    return switch (protocol) {
      WebDavProtocolModel() =>
        '/${RemoteObjectStoreFactory.webDavUri(protocol).pathSegments.where((s) => s.isNotEmpty).join('/')}',
      OAuthProtocolModel() => syncText(
        context,
        '此连接中已选择的云端文件夹',
        'The cloud folder selected for this connection',
      ),
    };
  }

  Future<void> check() async {
    if (busy) return;
    setState(() {
      busy = true;
      checked = false;
      checkFailed = false;
      failureCode = null;
      feedback = null;
    });
    try {
      await ref
          .read(backupDestinationServiceProvider)
          .check(
            connectionId: widget.profile.connectionId,
            vaultId: widget.profile.vaultId,
            trustedProducerIds: const [],
            restoring: false,
            remoteRootSegments: segments,
          );
      if (mounted) {
        setState(() {
          checked = true;
          feedback = syncText(
            context,
            fileSync ? '位置检查通过，尚未同步' : '可以写入，还没有开始备份',
            fileSync
                ? 'Location check passed. No sync has started.'
                : 'This folder can be written. No backup has started.',
          );
        });
      }
    } on Object catch (error) {
      if (!mounted) return;
      final code = error is BackupDestinationException
          ? error.code
          : SyncFailureClassifier.classify(error).errorCode;
      setState(() => _showFailure(code));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Explicit relocation of this task's cloud folder. Saving is not syncing:
  /// no transfer starts and no previous run is presented as complete.
  Future<void> relocate(ConnectionModel connection) async {
    final profile = fileSyncProfile;
    final protocol = connection.protocol;
    if (busy || profile == null || protocol is! WebDavProtocolModel) return;
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      final loader = ref.read(backupFolderLoaderProvider);
      final picked = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(
          builder: (_) => BackupFolderPicker(
            connectionName: connection.name,
            basePath: pathFor(connection, const []),
            initialSegments: profile.remoteRootSegments,
            loadFolders: (relative) =>
                loader(protocol: protocol, relativeSegments: relative),
            createFolder: (parent, name) => ref.read(
              backupFolderCreatorProvider,
            )(protocol: protocol, relativeSegments: parent, name: name),
          ),
        ),
      );
      if (picked == null || !mounted) return;
      if (picked.isEmpty) {
        setState(
          () => feedback = syncText(
            context,
            '请选择连接里的一个具体文件夹；连接根位置可能只是只读入口。',
            'Choose a specific folder inside the connection. The connection root may be a read-only entry point.',
          ),
        );
        return;
      }
      final confirmed = await showAdaptiveConfirmation(
        context,
        title: syncText(
          context,
          '更改这个任务的保存位置？',
          'Change this task’s location?',
        ),
        message:
            '${connection.name}\n${pathFor(connection, picked)}\n\n${syncText(context, '只把这个文件同步任务的云端保存位置改为上面的文件夹，不改动连接本身，也不会删除或迁移旧文件夹里的数据。保存后仍需另行开始同步。', 'This only points this file-sync task at the folder above. The connection is not changed and nothing in the old folder is deleted or migrated. Sync still has to be started separately.')}',
        confirmLabel: syncText(context, '保存位置', 'Save location'),
        confirmKey: const Key('storage-confirm-folder'),
      );
      if (!confirmed || !mounted) return;
      final updated = await ref
          .read(selectedFolderProfilesProvider)
          .selectSyncFolder(expected: profile, segments: picked);
      if (!mounted) return;
      setState(() {
        fileSyncProfile = updated;
        checked = false;
        checkFailed = false;
        failureCode = null;
        feedback = syncText(
          context,
          '保存位置已更新，请重新检查；本次只保存目录，尚未同步。',
          'Location updated. Check it again; only the folder was saved and no sync has started.',
        );
      });
    } on Object {
      if (mounted) {
        setState(
          () => feedback = syncText(
            context,
            '位置未保存。请确认这个任务没有正在运行，再重新进入本页试一次。',
            'Location not saved. Make sure this task is not running, reopen this page and try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Points this Velock backup at another folder of the same connection,
  /// through the same picker and confirmation as the manage tab. Saving is not
  /// backing up: the new folder still has to pass a check first.
  Future<void> relocateBackup(ConnectionModel connection) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await changeVelockBackupLocation(
        context,
        ref,
        profile: velockProfile,
        connection: connection,
      );
      if (!mounted) return;
      final updated = result.profile;
      if (updated != null) {
        setState(() {
          velockProfile = updated;
          checked = false;
          checkFailed = false;
          failureCode = null;
          feedback = syncText(
            context,
            '已改用新文件夹。先检查一下，再开始备份。',
            'Now using the new folder. Check it, then start the backup.',
          );
        });
      } else if (result.saveFailed) {
        setState(
          () => feedback = syncText(
            context,
            '位置未保存。请确认备份没有正在运行，再试一次。',
            'The location was not saved. Make sure no backup is running, then try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// The server refused the saved sign-in: the fix is the connection itself.
  Future<void> fixConnection() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final retry = await editBackupConnection(
        context,
        ref,
        widget.profile.connectionId,
      );
      if (!mounted) return;
      setState(() {
        connection = ref
            .read(connectionRepositoryProvider)
            .getConnectionById(widget.profile.connectionId);
        checked = false;
        checkFailed = false;
        failureCode = null;
        feedback = null;
      });
      if (retry) {
        setState(() => busy = false);
        await check();
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> sync() async {
    if (busy || !checked) return;
    setState(() => busy = true);
    try {
      final result = await runSyncWithProgress(
        context,
        ref,
        widget.profile.profileId,
      );
      if (!mounted) return;
      // Always require a new explicit check after an attempted run. The runner,
      // not the probe, remains the authority for completion and safety.
      setState(() {
        checked = false;
        feedback = firstSyncResultMessage(result, context: context);
      });
      await presentFirstSyncResult(context, result);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        checked = false;
        feedback = backupFailureMessage(
          context,
          SyncFailureClassifier.classify(error).errorCode,
        );
      });
      await presentSyncFailureAlert(context: context, error: error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String pathFor(ConnectionModel connection, List<String> segments) {
    final scoped = RemoteObjectStoreFactory.scopeProtocol(
      connection.protocol,
      segments,
    );
    return switch (scoped) {
      WebDavProtocolModel() =>
        '/${RemoteObjectStoreFactory.webDavUri(scoped).pathSegments.where((s) => s.isNotEmpty).join('/')}',
      OAuthProtocolModel() => syncText(
        context,
        '此连接中已选择的云端文件夹',
        'The cloud folder selected for this connection',
      ),
    };
  }

  static bool _unwritable(String code) =>
      code == 'provider.webdav.atomic_create_unsupported' ||
      code == 'provider.webdav.collection_not_writable';

  /// Same rule the home card uses to offer "edit connection".
  static bool _signInRejected(String? code) =>
      code != null && (code.contains('unauthor') || code.contains('401'));

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AdaptiveScaffold(
      title: syncText(context, '云端保存位置', 'Cloud location'),
      body: FutureBuilder<ConnectionModel?>(
        future: connection,
        builder: (context, snapshot) {
          final value = snapshot.data;
          String? path;
          if (value != null) {
            try {
              path = location(value);
            } on Object {
              path = null;
            }
          }
          final webDav = value?.protocol is WebDavProtocolModel;
          // Velock backups move through the shared manage-tab flow; the retired
          // file-sync task keeps its own picker.
          final canMove =
              value != null &&
              webDav &&
              (fileSync ? fileSyncProfile != null : true);
          final signIn = _signInRejected(failureCode);
          final fixLabel = signIn
              ? syncText(context, '修改连接', 'Edit connection')
              : syncText(context, '更换保存位置', 'Change location');
          final VoidCallback? fix = value == null || busy
              ? null
              : signIn
              ? fixConnection
              : canMove
              ? () => fileSync ? relocate(value) : relocateBackup(value)
              : null;
          final checkLabel = syncText(
            context,
            checked || checkFailed ? '重新检查' : '检查此位置',
            checked || checkFailed ? 'Check again' : 'Check this location',
          );

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (value != null) ...[
                      Row(
                        children: [
                          Icon(
                            CupertinoIcons.cloud,
                            size: 22,
                            color: context.appPrimary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              value.name,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        path ??
                            syncText(
                              context,
                              '保存位置配置不完整，暂时无法显示。',
                              'The saved location is incomplete and cannot be displayed.',
                            ),
                        key: const Key('storage-location'),
                        style: TextStyle(
                          fontSize: 15,
                          color: context.appSecondaryLabel,
                        ),
                      ),
                      if (fileSync && fileSyncProfile == null) ...[
                        const SizedBox(height: 8),
                        Text(
                          fileSyncProfileLoaded
                              ? syncText(
                                  context,
                                  '无法读取这个任务的文件夹配置，因此这里不能更改位置。请返回任务页重新进入。',
                                  'This task’s folder configuration could not be read, so the location cannot be changed here. Go back and reopen this page from the task.',
                                )
                              : syncText(
                                  context,
                                  '正在读取这个任务保存的文件夹…',
                                  'Loading the folder saved for this task…',
                                ),
                          key: const Key('storage-folder-unavailable'),
                        ),
                      ],
                    ] else
                      Text(
                        syncText(
                          context,
                          snapshot.connectionState == ConnectionState.waiting
                              ? '正在读取保存位置…'
                              : '无法读取连接，请返回后重试；未改动任何配置。',
                          snapshot.connectionState == ConnectionState.waiting
                              ? 'Loading the location…'
                              : 'Could not read the connection. Go back and retry. No settings were changed.',
                        ),
                      ),
                    if (feedback != null) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Icon(
                                checkFailed
                                    ? CupertinoIcons.exclamationmark_circle_fill
                                    : checked
                                    ? CupertinoIcons.checkmark_circle_fill
                                    : CupertinoIcons.info_circle_fill,
                                size: 20,
                                color: checkFailed
                                    ? context.appDanger
                                    : checked
                                    ? AppColors.success
                                    : context.appPrimary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                feedback!,
                                key: const Key('storage-feedback'),
                                style: TextStyle(
                                  fontSize: 15,
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                  color: checkFailed ? context.appDanger : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (checked) ...[
                      BackupActionButton(
                        key: const Key('storage-sync'),
                        label: syncText(
                          context,
                          fileSync ? '开始同步' : '开始备份',
                          fileSync ? 'Start sync' : 'Start backup',
                        ),
                        busy: busy,
                        onPressed: busy ? null : sync,
                      ),
                      const SizedBox(height: 10),
                    ] else if (fix != null || (value != null && signIn)) ...[
                      BackupActionButton(
                        key: Key(
                          signIn
                              ? 'storage-fix-connection'
                              : 'storage-change-folder',
                        ),
                        label: fixLabel,
                        onPressed: fix,
                      ),
                      const SizedBox(height: 10),
                    ],
                    BackupActionButton(
                      key: const Key('storage-check'),
                      secondary:
                          checked || fix != null || (value != null && signIn),
                      label: busy && !checked
                          ? syncText(context, '请稍候…', 'Please wait…')
                          : checkLabel,
                      onPressed: busy || value == null ? null : check,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      syncText(
                        context,
                        '检查只写入并删除一个临时测试文件，不会上传你的数据；更换位置不会移动或删除旧文件夹里的内容。',
                        'Checking writes and deletes one temporary test file and uploads none of your data. Changing the location does not move or delete anything in the old folder.',
                      ),
                      key: const Key('storage-footnote'),
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: context.appSecondaryLabel,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
