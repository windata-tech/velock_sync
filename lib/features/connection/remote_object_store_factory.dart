import 'package:dio/dio.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

/// Builds the provider-neutral remote store for one connection.
///
/// Both the sync runners and the read-only inventory scan go through this
/// factory so credentials and URL handling never diverge.
abstract final class RemoteObjectStoreFactory {
  static Future<RemoteObjectStore> create({
    required ConnectionRepository connections,
    required ProtocolModel protocol,
  }) async => switch (protocol) {
    WebDavProtocolModel(:final credentialRef) => WebDavObjectStore(
      dio: Dio(),
      baseUri: webDavUri(protocol),
      username: protocol.username,
      password: await connections.readWebDavPassword(credentialRef),
    ),
    OAuthProtocolModel() => connections.createOAuthRemote(protocol),
  };

  static Uri webDavUri(WebDavProtocolModel protocol) {
    final address = Uri.tryParse(protocol.address);
    final port = int.tryParse(protocol.port);
    if (address == null || !address.hasAuthority || port == null || port < 1) {
      throw ArgumentError.value(protocol.address, 'protocol', 'is invalid');
    }
    final providerPath = Uri.tryParse(protocol.path ?? '');
    final segments = <String>[
      ...address.pathSegments.where((segment) => segment.isNotEmpty),
      ...?providerPath?.pathSegments.where(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      ),
    ];
    final expectedSegmentCount =
        address.pathSegments.where((segment) => segment.isNotEmpty).length +
        (providerPath?.pathSegments.length ?? 0);
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
