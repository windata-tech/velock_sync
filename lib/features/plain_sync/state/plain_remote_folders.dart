import 'package:flutter/widgets.dart' show BuildContext;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
import 'package:velock_sync/providers/remote_provider_availability.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Browses and creates remote folders for a plain sync location, whatever
/// kind of connection holds it. Only connections for which
/// [RemoteObjectStoreFactory.supportsPlainFolders] is true are accepted.
class PlainRemoteFolders {
  const PlainRemoteFolders({
    required ConnectionRepository connections,
    required BackupFolderLoader webDavLoader,
    required BackupFolderCreator webDavCreator,
  }) : _connections = connections,
       _webDavLoader = webDavLoader,
       _webDavCreator = webDavCreator;

  final ConnectionRepository _connections;
  final BackupFolderLoader _webDavLoader;
  final BackupFolderCreator _webDavCreator;

  static const _maxPages = 50;

  /// The address shown in front of the chosen folder path.
  ///
  /// OneDrive and Aliyun Drive root a connection at a folder ID; its name is
  /// not known without a request, so a chosen folder shows as `…`.
  String basePath(BuildContext context, ConnectionModel connection) =>
      switch (connection.protocol) {
        final WebDavProtocolModel protocol =>
          RemoteObjectStoreFactory.webDavDisplayAddress(protocol),
        OAuthProtocolModel(
          providerType: RemoteProviderType.baiduNetdisk,
          :final rootId,
        ) =>
          BaiduNetdiskObjectStore.normaliseRootPath(rootId),
        OAuthProtocolModel(:final providerType, :final rootId) =>
          rootId == 'root'
              ? localizedRemoteProviderName(context, providerType)
              : '${localizedRemoteProviderName(context, providerType)}/…',
      };

  /// The folders directly inside [relativeSegments].
  Future<List<WebDavBackupFolder>> list(
    ConnectionModel connection,
    List<String> relativeSegments,
  ) async {
    final protocol = connection.protocol;
    if (protocol is WebDavProtocolModel) {
      return _webDavLoader(
        protocol: protocol,
        relativeSegments: relativeSegments,
      );
    }
    final mirror = _mirror(protocol, relativeSegments);
    final folders = <WebDavBackupFolder>[];
    String? cursor;
    try {
      for (var page = 0; page < _maxPages; page++) {
        final result = await mirror.list(cursor: cursor, limit: 500);
        folders.addAll([
          for (final item in result.items)
            if (item.isDirectory)
              WebDavBackupFolder(name: item.logicalKey.split('/').last),
        ]);
        cursor = result.nextCursor;
        if (cursor == null) break;
      }
    } on RemoteObjectNotFoundException {
      // Baidu creates the app folder on the first write, so a new connection
      // has no root folder yet; that is an empty start, not a failure.
      if (relativeSegments.isNotEmpty) rethrow;
      return const [];
    }
    folders.sort((a, b) => a.name.compareTo(b.name));
    return folders;
  }

  /// Creates exactly one empty folder named [name] inside [parentSegments].
  Future<void> create(
    ConnectionModel connection,
    List<String> parentSegments,
    String name,
  ) async {
    final protocol = connection.protocol;
    if (protocol is WebDavProtocolModel) {
      return _webDavCreator(
        protocol: protocol,
        relativeSegments: parentSegments,
        name: name,
      );
    }
    final mirror = _mirror(protocol, parentSegments);
    if (mirror is! RemoteCollectionCreator) {
      throw StateError('${protocol.runtimeType} cannot create folders');
    }
    await (mirror as RemoteCollectionCreator).createCollection(name);
  }

  RemoteObjectStore _mirror(
    ProtocolModel protocol,
    List<String> relativeSegments,
  ) {
    if (protocol is OAuthProtocolModel &&
        RemoteObjectStoreFactory.supportsPlainFolders(protocol)) {
      return RemoteObjectStoreFactory.plainMirror(
        _connections,
        protocol,
        relativeSegments,
      );
    }
    throw ArgumentError.value(
      protocol,
      'protocol',
      'plain folder sync needs a drive that keeps real paths',
    );
  }
}

final plainRemoteFoldersProvider = Provider<PlainRemoteFolders>(
  (ref) => PlainRemoteFolders(
    connections: ref.watch(connectionRepositoryProvider),
    webDavLoader: ref.watch(backupFolderLoaderProvider),
    webDavCreator: ref.watch(backupFolderCreatorProvider),
  ),
);
