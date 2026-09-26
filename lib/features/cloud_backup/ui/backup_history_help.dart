import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';

import 'backup_widgets.dart';

Future<void> showBackupHistoryHelp(
  BuildContext context,
  SyncProfileEnvelope profile,
) => Navigator.of(context).push<void>(
  isApplePlatform(context)
      ? CupertinoPageRoute(builder: (_) => BackupHistoryHelp(profile: profile))
      : MaterialPageRoute(builder: (_) => BackupHistoryHelp(profile: profile)),
);

/// Explanation and read-only inspection, NOT a repair or migration operation.
/// Never clears failure state, changes a destination, reconnects or starts a run.
class BackupHistoryHelp extends ConsumerWidget {
  const BackupHistoryHelp({super.key, required this.profile});
  final SyncProfileEnvelope profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(
      connectionDetailProvider(profile.connectionId),
    );
    return AdaptiveScaffold(
      title: syncText(context, '备份为什么停止', 'Why backup stopped'),
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
                      '需要以前的备份才能继续',
                      'Earlier backup records are needed',
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
                      '当前云端位置缺少这份备份以前的记录。Sync 已停止本次备份，不能把它当作成功。',
                      'Earlier records for this backup are missing from the cloud location. Sync stopped this backup rather than reporting success.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    syncText(
                      context,
                      '这不是让你重新授权，也与后台同步开关无关。',
                      'This is not an authorization issue or a background-sync setting.',
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
                    syncText(context, '先核对保存位置', 'Check the saved location'),
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  connection.when(
                    loading: () => Text(
                      syncText(context, '正在读取保存位置…', 'Loading saved location…'),
                    ),
                    error: (_, _) => Text(
                      syncText(
                        context,
                        '暂时无法读取保存位置。返回后刷新再试。',
                        'The saved location could not be loaded. Go back and refresh.',
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
                        : _location(context, value),
                  ),
                ],
              ),
            ),
            BackupCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    syncText(
                      context,
                      '如果你刚换了文件夹',
                      'If you recently changed folders',
                    ),
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    syncText(
                      context,
                      '新文件夹不会自动带上旧备份。需要找回原来完整的备份；新建空文件夹、重新连接格间，都不能补齐这些记录。',
                      'A new folder does not automatically contain earlier backups. The original complete backup is needed; creating an empty folder or reconnecting Velock cannot replace the missing records.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  BackupActionButton(
                    key: const Key('backup-history-missing-original'),
                    label: syncText(
                      context,
                      '原来的备份找不到了？',
                      'Can’t find the original backup?',
                    ),
                    secondary: true,
                    onPressed: () => showAdaptiveAlert<void>(
                      context: context,
                      title: syncText(
                        context,
                        '先保留本机数据和旧备份',
                        'Keep local data and any old backup',
                      ),
                      message: syncText(
                        context,
                        '当前版本还不能把本机全部数据重新整理成一份完整备份，自动补到新文件夹。\n\n如果找不到完整旧备份，这份备份暂时无法继续；反复重试或重新授权也不能解决。\n\n请保留格间中的本机数据和可能存在的旧备份，不要卸载格间、重置同步或删除旧目录。',
                        'This version cannot yet rebuild a complete backup from all local data into a new folder.\n\nWithout the original complete backup, this backup cannot continue. Repeated retries or authorization will not fix it.\n\nKeep local data in Velock and any old backups. Do not uninstall Velock, reset sync, or delete old folders.',
                      ),
                      actions: [
                        AdaptiveAlertAction<void>(
                          label: syncText(context, '知道了', 'OK'),
                          isDefault: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _location(BuildContext context, ConnectionModel connection) {
    String folder;
    try {
      final scoped = RemoteObjectStoreFactory.scopeProtocol(
        connection.protocol,
        VelockSyncProfile.fromEnvelope(profile).remoteRootSegments,
      );
      folder = switch (scoped) {
        WebDavProtocolModel() =>
          '/${RemoteObjectStoreFactory.webDavUri(scoped).pathSegments.where((s) => s.isNotEmpty).join('/')}',
        OAuthProtocolModel() => syncText(
          context,
          '此连接中已选择的云端文件夹',
          'The cloud folder selected for this connection',
        ),
      };
    } on Object {
      // Bad configuration must not be presented as a valid root folder.
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
        Text(
          syncText(
            context,
            '连接：${connection.name}',
            'Connection: ${connection.name}',
          ),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        SelectableText(folder, key: const Key('backup-history-location-path')),
        const SizedBox(height: 12),
        Text(
          syncText(
            context,
            '确认这是不是以前备份使用的位置。浏览只用于核对，不会更换保存位置或修复备份。',
            'Check whether this is the location used for earlier backups. Browsing only inspects files; it does not change the location or repair the backup.',
          ),
        ),
        const SizedBox(height: 16),
        BackupActionButton(
          key: const Key('backup-history-browse-location'),
          label: syncText(context, '浏览云端文件', 'Browse cloud files'),
          onPressed: () =>
              context.push('/connections/connection/${profile.connectionId}'),
        ),
        const SizedBox(height: 8),
        Text(
          syncText(
            context,
            '浏览从此云端连接的起始目录打开，请按上面的路径核对。',
            'Browsing starts at this connection’s root. Follow the path shown above.',
          ),
        ),
      ],
    );
  }
}
