import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/providers/aliyun_drive/aliyun_drive_object_store.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
import 'package:velock_sync/providers/google_drive/google_drive_object_store.dart';
import 'package:velock_sync/providers/one_drive/one_drive_object_store.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/infrastructure/network/sync_http.dart';

/// Builds the provider-neutral remote store for one connection.
///
/// Both the sync runners and the read-only inventory scan go through this
/// factory so credentials and URL handling never diverge.
abstract final class RemoteObjectStoreFactory {
  static Future<RemoteObjectStore> create({
    required ConnectionRepository connections,
    required ProtocolModel protocol,
    List<String> remoteRootSegments = const [],
  }) async {
    final scopedProtocol = scopeProtocol(protocol, remoteRootSegments);
    return switch (scopedProtocol) {
      WebDavProtocolModel(:final credentialRef) => WebDavObjectStore(
        // Real timeouts: a connection that stalls without an RST (Wi-Fi drops
        // into a black hole, a NAS powers off, a VPN hangs) must fail the run
        // instead of hanging it for ever.
        dio: newSyncDio(),
        baseUri: webDavUri(scopedProtocol),
        username: scopedProtocol.username,
        password: await connections.readWebDavPassword(credentialRef),
      ),
      OAuthProtocolModel() => connections.createOAuthRemote(scopedProtocol),
    };
  }

  /// Whether a connection can hold a plain file-sync folder: one whose files
  /// keep their real names and folders, so the remote stays readable to people
  /// and other programs.
  static bool supportsPlainFolders(ProtocolModel protocol) =>
      switch (protocol) {
        WebDavProtocolModel() => true,
        // A Google connection made for Velock backups may only see its own
        // files and the hidden app folder; file sync needs one signed in with
        // full Drive access, rooted at an ordinary folder.
        OAuthProtocolModel(
          providerType: RemoteProviderType.googleDrive,
          :final fullDriveAccess,
          :final rootId,
        ) =>
          fullDriveAccess && rootId != 'appDataFolder',
        OAuthProtocolModel(:final providerType) =>
          plainFolderProviders.contains(providerType),
      };

  /// Cloud drives that can hold a plain sync folder. A Google Drive
  /// connection additionally needs full Drive access (see
  /// [supportsPlainFolders]); file-sync setup signs in with it.
  static const plainFolderProviders = [
    RemoteProviderType.googleDrive,
    RemoteProviderType.oneDrive,
    RemoteProviderType.baiduNetdisk,
    RemoteProviderType.aliyunDrive,
  ];

  /// The folder-tree view of a cloud drive that [supportsPlainFolders],
  /// scoped to [remoteRootSegments] below the connection's root.
  static RemoteObjectStore plainMirror(
    ConnectionRepository connections,
    OAuthProtocolModel protocol,
    List<String> remoteRootSegments,
  ) {
    final segments = _validatedRemoteRootSegments(remoteRootSegments);
    switch (protocol.providerType) {
      case RemoteProviderType.baiduNetdisk:
        final store = connections.createOAuthRemote(
          scopeProtocol(protocol, segments) as OAuthProtocolModel,
        );
        if (store is BaiduNetdiskObjectStore) return store.asMirror();
      case RemoteProviderType.oneDrive:
        final store = connections.createOAuthRemote(protocol);
        if (store is OneDriveObjectStore) {
          return store.asMirror(scope: segments);
        }
      case RemoteProviderType.aliyunDrive:
        final store = connections.createOAuthRemote(protocol);
        if (store is AliyunDriveObjectStore) {
          return store.asMirror(scope: segments);
        }
      case RemoteProviderType.googleDrive:
        if (!supportsPlainFolders(protocol)) break;
        final store = connections.createOAuthRemote(protocol);
        if (store is GoogleDriveObjectStore) {
          return store.asMirror(scope: segments);
        }
      default:
    }
    throw ArgumentError.value(
      protocol,
      'protocol',
      'plain folder sync needs a drive that keeps real paths',
    );
  }

  /// Adds one profile-specific relative path scope to a copied protocol.
  ///
  /// The supplied protocol is never mutated. Resetting [WebDavProtocolModel.path]
  /// after embedding the already-resolved URI prevents a later call from
  /// appending that provider path a second time.
  static ProtocolModel scopeProtocol(
    ProtocolModel protocol,
    List<String> remoteRootSegments,
  ) {
    final segments = _validatedRemoteRootSegments(remoteRootSegments);
    if (segments.isEmpty) return protocol;
    // Baidu Netdisk addresses folders by real path, so a scope is just a
    // longer root path. The other cloud drives root at an opaque item ID.
    if (protocol case OAuthProtocolModel(
      providerType: RemoteProviderType.baiduNetdisk,
      :final rootId,
    )) {
      final base = BaiduNetdiskObjectStore.normaliseRootPath(rootId);
      return protocol.copyWith(rootId: '$base/${segments.join('/')}');
    }
    if (protocol is! WebDavProtocolModel) {
      throw ArgumentError.value(
        protocol,
        'protocol',
        'remote root scopes are supported only for WebDAV and Baidu Netdisk',
      );
    }

    final currentUri = webDavUri(protocol);
    final scopedUri = currentUri.replace(
      pathSegments: [
        ...currentUri.pathSegments.where((segment) => segment.isNotEmpty),
        ...segments,
      ],
      query: null,
      fragment: null,
    );
    return protocol.copyWith(address: scopedUri.toString(), path: null);
  }

  static List<String> _validatedRemoteRootSegments(List<String> segments) {
    try {
      return VelockSyncProfile.canonicalRemoteRootSegments(segments);
    } on FormatException {
      throw ArgumentError.value(
        segments,
        'remoteRootSegments',
        'must contain decoded non-empty relative path segments',
      );
    }
  }

  /// The server address a person recognises: scheme, host, any non-default
  /// port and the configured path, decoded. For display only.
  static String webDavDisplayAddress(WebDavProtocolModel protocol) {
    try {
      final text = Uri.decodeFull(webDavUri(protocol).toString());
      return text.replaceFirst(RegExp(r'/+$'), '');
    } on Object {
      return protocol.address;
    }
  }

  static Uri webDavUri(WebDavProtocolModel protocol) {
    final address = Uri.tryParse(protocol.address);
    final port = int.tryParse(protocol.port);
    if (address == null || !address.hasAuthority || port == null || port < 1) {
      throw ArgumentError.value(protocol.address, 'protocol', 'is invalid');
    }
    final providerPath = Uri.tryParse(protocol.path ?? '');
    final providerSegments = <String>[...?providerPath?.pathSegments];
    // Both '/' and '/share/' identify collections. Strip only the final
    // separator, not empty interior segments that change path semantics.
    if (providerSegments.isNotEmpty && providerSegments.last.isEmpty) {
      providerSegments.removeLast();
    }
    final segments = <String>[
      ...address.pathSegments.where((segment) => segment.isNotEmpty),
      ...providerSegments.where(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      ),
    ];
    final expectedSegmentCount =
        address.pathSegments.where((segment) => segment.isNotEmpty).length +
        providerSegments.length;
    if (segments.length != expectedSegmentCount) {
      throw ArgumentError.value(protocol.path, 'protocol.path', 'is invalid');
    }
    return address.replace(
      scheme: protocol.protocolType.name,
      port: port,
      pathSegments: segments,
      query: null,
      fragment: null,
    );
  }
}
