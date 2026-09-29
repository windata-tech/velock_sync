import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
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
import 'backup_folder_picker.dart';
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
  late final Future<ConnectionModel?> connection = ref
      .read(connectionRepositoryProvider)
      .getConnectionById(widget.profile.connectionId);
  late final bool fileSync =
      widget.profile.kind == SyncDatasetKind.selectedFolder;
  SelectedFolderSyncProfile? fileSyncProfile;
  bool fileSyncProfileLoaded = false;
  bool busy = false;
  bool checked = false;
  bool checkFailed = false;
  bool locationSaved = false;

  /// The long "what the check does" text stays collapsed until asked for.
  bool showDetails = false;
  String? feedback;

  bool get canRelocate =>
      fileSyncProfile != null && fileSyncProfile!.remoteRootSegments.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (fileSync) _loadFileSyncProfile();
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
      : VelockSyncProfile.fromEnvelope(widget.profile).remoteRootSegments;

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
            '位置检查通过，尚未同步',
            'Location check passed. No sync has started.',
          );
        });
      }
    } on Object catch (error) {
      if (!mounted) return;
      final code = error is BackupDestinationException
          ? error.code
          : SyncFailureClassifier.classify(error).errorCode;
      checkFailed = true;
      setState(
        () => feedback = code == 'provider.webdav.atomic_create_unsupported'
            ? syncText(
                context,
                '此位置仍未通过安全写入检查。Sync 无法自动修复服务器权限或兼容性；已停止，未开始同步。',
                'This location still fails the safe-write check. Sync cannot automatically repair server permissions or compatibility. No sync has started.',
              )
            : backupFailureMessage(context, code),
      );
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
        locationSaved = true;
        checked = false;
        checkFailed = false;
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

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AdaptiveScaffold(
      title: syncText(context, '检查云端位置', 'Check cloud location'),
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
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      syncText(context, '保存位置', 'Save location'),
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (value != null) ...[
                      Text(
                        value.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        path ??
                            syncText(
                              context,
                              '保存位置配置不完整，暂时无法显示。',
                              'The saved location is incomplete and cannot be displayed.',
                            ),
                        key: const Key('storage-location'),
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
                    // Result first: the reason only matters after a real check.
                    if (feedback != null) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          feedback!,
                          key: const Key('storage-feedback'),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: checkFailed ? context.appDanger : null,
                          ),
                        ),
                      ),
                    ],
                    if (checkFailed && fileSync && !locationSaved) ...[
                      const SizedBox(height: 8),
                      Text(
                        syncText(
                          context,
                          fileSyncProfile != null
                              ? '用下面的“选择可写入文件夹”换一个这个账号能写入的文件夹。'
                              : '请返回任务页重新进入，再换一个这个账号能写入的文件夹。',
                          fileSyncProfile != null
                              ? 'Use “Choose a writable folder” below to pick a folder this account can write to.'
                              : 'Go back, reopen this page from the task, and choose a folder this account can write to.',
                        ),
                        key: const Key('storage-fix-hint'),
                      ),
                    ],
                    const SizedBox(height: 20),
                    BackupActionButton(
                      key: const Key('storage-check'),
                      secondary: checked,
                      label: syncText(
                        context,
                        busy
                            ? '请稍候…'
                            : (checked
                                  ? '重新检查此位置'
                                  : (checkFailed ? '重新检查此位置' : '检查此位置')),
                        busy
                            ? 'Please wait…'
                            : (checked || checkFailed
                                  ? 'Check this location again'
                                  : 'Check this location'),
                      ),
                      onPressed: busy || value == null ? null : check,
                    ),
                    if (checked) ...[
                      const SizedBox(height: 12),
                      BackupActionButton(
                        key: const Key('storage-sync'),
                        label: syncText(context, '开始同步', 'Start sync'),
                        busy: busy,
                        onPressed: busy ? null : sync,
                      ),
                    ],
                  ],
                ),
              ),
              if (value != null)
                AdaptiveListSection(
                  children: [
                    if (fileSync &&
                        value.protocol is WebDavProtocolModel &&
                        fileSyncProfile != null)
                      AdaptiveListTile(
                        widgetKey: const Key('storage-change-folder'),
                        title: Text(
                          syncText(
                            context,
                            canRelocate ? '更改可写入文件夹' : '选择可写入文件夹',
                            canRelocate
                                ? 'Change the writable folder'
                                : 'Choose a writable folder',
                          ),
                        ),
                        subtitle: Text(
                          syncText(
                            context,
                            '只改这个任务的云端文件夹；不改连接，不删除旧数据，不自动同步',
                            'Changes only this task’s cloud folder. Keeps the connection and old data, and does not start syncing.',
                          ),
                        ),
                        showChevron: true,
                        enabled: !busy,
                        onTap: () => relocate(value),
                      ),
                    AdaptiveListTile(
                      widgetKey: const Key('storage-browse'),
                      title: Text(
                        syncText(
                          context,
                          '浏览此连接的文件夹',
                          'Browse folders in this connection',
                        ),
                      ),
                      subtitle: Text(
                        syncText(
                          context,
                          '仅查看；不会自动选择目录或开始同步',
                          'Viewing only; does not select a location or start syncing',
                        ),
                      ),
                      showChevron: true,
                      enabled: !busy,
                      onTap: () async {
                        setState(() {
                          checked = false;
                          feedback = null;
                        });
                        await context.push(
                          '/connections/connection/${widget.profile.connectionId}',
                        );
                      },
                    ),
                  ],
                ),
              if (value != null)
                BackupCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        syncText(context, '关于这次检查', 'About this check'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        showDetails
                            ? syncText(
                                context,
                                '检查只写入、读回并清理一个临时测试文件，不上传你的文件，也不改变保存位置。\n\n它只测试这个任务当前的保存位置能否安全写入，不会改动后台同步、蜂窝网络或恢复包，也不会修改格间共用的连接。\n\n结果不代表文件已经备份成功。检查通过后仍需另行开始同步，最终结果由同步本身决定。',
                                'The check only writes, reads back and cleans up one temporary test file. It does not upload your files or change the location.\n\nIt tests only whether this task’s current location can be written safely. It does not change background sync, cellular data or recovery packages, and it does not modify a connection shared with Velock.\n\nA pass does not mean your files are backed up. Sync still has to be started separately, and the sync itself decides the final result.',
                              )
                            : syncText(
                                context,
                                '只写入并清理一个临时测试文件。',
                                'Writes and cleans up one temporary test file.',
                              ),
                        key: const Key('storage-detail-text'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        key: const Key('storage-detail-toggle'),
                        onPressed: busy
                            ? null
                            : () => setState(() => showDetails = !showDetails),
                        child: Text(
                          showDetails
                              ? syncText(context, '收起', 'Show less')
                              : syncText(
                                  context,
                                  '它具体做什么？',
                                  'What exactly does it do?',
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (checkFailed && (!fileSync || locationSaved))
                BackupCard(
                  child: Text(
                    syncText(
                      context,
                      fileSync
                          ? '已保存新的位置。若这里仍不可写，请再换一个文件夹；不要修改格间共用的连接，也不需要删除旧数据。'
                          : '请确认这是服务里一个真实存在、且这个账号有权限写入的文件夹，而不只是只读入口或共享入口。检查失败不会删除旧数据或更换目录。',
                      fileSync
                          ? 'The new location is saved. If it still cannot be written, choose another folder. Do not change a connection shared with Velock or delete old data.'
                          : 'Confirm that this is a real folder in the service that this account may write to, not just a read-only or share entry. A failed check does not delete old data or change the location.',
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
