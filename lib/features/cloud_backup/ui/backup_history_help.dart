import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

import 'backup_widgets.dart';
import 'velock_backup_location.dart';
import 'velock_backup_rebuild.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace_shared.dart';

Future<void> showBackupHistoryHelp(
  BuildContext context,
  SyncProfileEnvelope profile,
) => Navigator.of(context).push<void>(
  isApplePlatform(context)
      ? CupertinoPageRoute(builder: (_) => BackupHistoryHelp(profile: profile))
      : MaterialPageRoute(builder: (_) => BackupHistoryHelp(profile: profile)),
);

/// Viewing and browsing are read-only; relocation requires explicit confirmation.
class BackupHistoryHelp extends ConsumerStatefulWidget {
  const BackupHistoryHelp({super.key, required this.profile});
  final SyncProfileEnvelope profile;
  @override
  ConsumerState<BackupHistoryHelp> createState() => _BackupHistoryHelpState();
}

class _BackupHistoryHelpState extends ConsumerState<BackupHistoryHelp> {
  late SyncProfileEnvelope profile = widget.profile;
  bool busy = false;
  bool locationSaved = false;
  bool backupRequested = false;
  String? feedback;

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

  Future<void> selectFolder(ConnectionModel connection) async {
    if (busy) return;
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      final result = await changeVelockBackupLocation(
        context,
        ref,
        profile: profile,
        connection: connection,
        requireExistingBackup: true,
      );
      if (!mounted) return;
      final updated = result.profile;
      if (updated == null) {
        if (result.saveFailed) {
          setState(() {
            feedback = syncText(
              context,
              '目录未保存。请确认备份没有正在运行，再试一次。',
              'Folder not saved. Make sure no backup is running, then try again.',
            );
          });
        }
        return;
      }
      setState(() {
        profile = updated;
        locationSaved = true;
        backupRequested = false;
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> startBackup() async {
    if (busy) return;
    setState(() {
      busy = true;
      backupRequested = true;
      feedback = null;
    });
    try {
      final result = await runSyncWithProgress(context, ref, profile.profileId);
      if (mounted && result != null) await presentSyncResult(context, result);
    } on Object {
      if (mounted) {
        setState(() {
          feedback = syncText(
            context,
            '本次备份未完成，请返回查看备份状态。',
            'Backup did not complete. Go back to view its status.',
          );
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(
      connectionDetailProvider(profile.connectionId),
    );
    return PopScope(
      canPop: !busy,
      child: AdaptiveScaffold(
        title: syncText(context, '找回备份位置', 'Find your backup'),
        body: Material(
          type: MaterialType.transparency,
          child: ListView(
            key: const Key('backup-history-help'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      syncText(
                        context,
                        locationSaved ? '备份位置已更新' : '请选择原来的备份文件夹',
                        locationSaved
                            ? 'Backup location updated'
                            : 'Select your original backup folder',
                      ),
                      style: const TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      syncText(
                        context,
                        locationSaved
                            ? (backupRequested
                                  ? '位置已保存。备份结果请返回备份页查看。'
                                  : '本次只保存目录，尚未开始备份。')
                            : '请选以前备份成功时使用的文件夹；已有文件夹不一定包含原备份。保存前会检查是否有当前账号的备份记录，完整性仍需备份时验证。',
                        locationSaved
                            ? (backupRequested
                                  ? 'Location saved. Go back to view the backup result.'
                                  : 'Only the folder was saved. Backup has not started.')
                            : 'Choose the folder used for a previous successful backup. An existing folder may not contain it. We will look for this account’s backup records before saving; completeness is checked when backup runs.',
                      ),
                    ),
                  ],
                ),
              ),
              BackupCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      syncText(context, '当前备份位置', 'Current backup location'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    connection.when(
                      loading: () => Text(
                        syncText(
                          context,
                          '正在读取保存位置…',
                          'Loading saved location…',
                        ),
                      ),
                      error: (_, _) => Text(
                        syncText(
                          context,
                          '暂时无法读取保存位置。返回后刷新再试。',
                          'Could not load the location. Go back and refresh.',
                        ),
                      ),
                      data: (value) => value == null
                          ? Text(
                              syncText(
                                context,
                                '当前连接已不存在，无法核对保存位置。',
                                'This connection no longer exists, so its location cannot be checked.',
                              ),
                            )
                          : location(value),
                    ),
                    if (feedback != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        feedback!,
                        key: const Key('backup-history-feedback'),
                      ),
                    ],
                  ],
                ),
              ),
              if (locationSaved)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.page,
                  ),
                  child: Column(
                    children: [
                      BackupActionButton(
                        key: const Key('backup-history-done'),
                        label: syncText(context, '完成', 'Done'),
                        onPressed: busy
                            ? null
                            : () {
                                if (Navigator.of(context).canPop()) {
                                  Navigator.of(context).pop();
                                } else {
                                  context.go('/');
                                }
                              },
                      ),
                      const SizedBox(height: 12),
                      BackupActionButton(
                        key: const Key('backup-history-start-backup'),
                        label: syncText(context, '开始备份', 'Start backup'),
                        secondary: true,
                        busy: busy,
                        onPressed: busy ? null : startBackup,
                      ),
                    ],
                  ),
                ),
              if (!locationSaved)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.page,
                  ),
                  child: BackupActionButton(
                    key: const Key('backup-history-missing-original'),
                    label: syncText(
                      context,
                      '原来的备份找不到了？',
                      'Can’t find the original backup?',
                    ),
                    secondary: true,
                    onPressed: busy || connection.asData?.value == null
                        ? null
                        : () => Navigator.of(context).push<void>(
                            isApplePlatform(context)
                                ? CupertinoPageRoute(
                                    builder: (_) => VelockBackupRebuildPage(
                                      profile: profile,
                                      connection: connection.asData!.value!,
                                    ),
                                  )
                                : MaterialPageRoute(
                                    builder: (_) => VelockBackupRebuildPage(
                                      profile: profile,
                                      connection: connection.asData!.value!,
                                    ),
                                  ),
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget location(ConnectionModel connection) {
    String folder;
    try {
      folder = pathFor(
        connection,
        VelockSyncProfile.fromEnvelope(profile).remoteRootSegments,
      );
    } on Object {
      return Text(
        syncText(
          context,
          '保存位置配置不完整，暂时无法显示。',
          'The saved location is incomplete and cannot be displayed.',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(connection.name),
        const SizedBox(height: 6),
        SelectableText(folder, key: const Key('backup-history-location-path')),
        const SizedBox(height: 20),
        if (connection.protocol is WebDavProtocolModel)
          BackupActionButton(
            key: const Key('backup-history-browse-location'),
            secondary: locationSaved,
            label: syncText(
              context,
              locationSaved ? '重新选择目录' : '选择原备份文件夹',
              locationSaved
                  ? 'Choose another folder'
                  : 'Select original backup folder',
            ),
            onPressed: busy ? null : () => selectFolder(connection),
          )
        else ...[
          Text(
            syncText(
              context,
              '此云盘暂不支持在这里更换目录。可以先核对文件。',
              'Changing folders here is not supported for this cloud. You can inspect its files.',
            ),
          ),
          BackupActionButton(
            label: syncText(context, '查看云端文件', 'View cloud files'),
            onPressed: busy
                ? null
                : () => context.push(
                    '/connections/connection/${profile.connectionId}',
                  ),
          ),
        ],
      ],
    );
  }
}
