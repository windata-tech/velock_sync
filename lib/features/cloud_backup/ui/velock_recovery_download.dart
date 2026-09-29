import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_recovery_transport.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_dialogs.dart';
import 'backup_folder_picker.dart';

/// Bootstrap does not require a paired vault. Only bounded encrypted files are
/// read from the user's explicitly selected existing cloud folder.
Future<bool> downloadVelockRecovery(BuildContext context, WidgetRef ref) async {
  final repository = ref.read(connectionRepositoryProvider);
  final connections = await repository.loadConnections();
  if (!context.mounted) return false;
  if (connections.isEmpty) {
    await showAdaptiveNotice(
      context: context,
      title: syncText(
        context,
        '先添加原来的云端连接',
        'Add your original cloud connection',
      ),
      message: syncText(
        context,
        '请使用备份时的云端账号。添加连接后，再回来选择原备份目录。',
        'Use the cloud account that holds your backup, then return here to select its folder.',
      ),
      confirmLabel: syncText(context, '继续', 'Continue'),
    );
    if (context.mounted) {
      await context.push(
        Uri(
          path: AppRoutes.protocols.path,
          queryParameters: {'returnTo': AppRoutes.velockRecovery.path},
        ).toString(),
      );
    }
    return false;
  }
  final connection = await showAdaptiveActionSheet<ConnectionModel>(
    context: context,
    title: syncText(
      context,
      '选择原来的云端连接',
      'Select your original cloud connection',
    ),
    actions: [
      for (final item in connections)
        AdaptiveAction(label: item.name, value: item),
    ],
  );
  if (connection == null || !context.mounted) return false;
  List<String> segments = [];
  final protocol = connection.protocol;
  if (protocol is WebDavProtocolModel) {
    final loader = ref.read(backupFolderLoaderProvider);
    final selected = await Navigator.of(context).push<List<String>>(
      CupertinoPageRoute(
        builder: (_) => BackupFolderPicker(
          connectionName: connection.name,
          basePath: protocol.path ?? '/',
          restoring: true,
          loadFolders: (segments) =>
              loader(protocol: protocol, relativeSegments: segments),
        ),
      ),
    );
    if (selected == null || !context.mounted) return false;
    segments = selected;
  }
  final root = await AppleExchangeRootLocator().locate();
  final remote = await RemoteObjectStoreFactory.create(
    connections: repository,
    protocol: protocol,
    remoteRootSegments: segments,
  );
  await VelockRecoveryTransport.download(
    root: root,
    remote: remote,
    isCurrent: () => context.mounted,
  );
  // The restore wizard asked for the same connection and folder again. Keep
  // this choice so the next step starts from the original backup folder.
  ref.read(velockWizardSessionProvider.notifier)
    ..connectionSelected(connection.id)
    ..folderSelected(segments);
  return true;
}
