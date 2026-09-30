import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
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
    if (protocol is! WebDavProtocolModel) {
      throw ArgumentError.value(
        protocol,
        'protocol',
        'remote root scopes are supported only for WebDAV',
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
