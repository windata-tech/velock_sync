import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_target_factory.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

part '../../../generated/features/connection/state/protocol_provider.g.dart';

@riverpod
Future<bool> protocolConnectChecker(Ref ref, ProtocolModel protocol) async {
  // final dio = Dio();
  // dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: (){
  //   final client = HttpClient();
  //   client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  //   return client;
  // });
  // or
  // (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
  //   final client = HttpClient();
  //   client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  //   return client;
  // };

  switch (protocol) {
    case WebDavProtocolModel():
      WebdavClient client;
      final password = await ref
          .read(credentialStoreProvider)
          .readWebDavPassword(protocol.credentialRef ?? '');
      if (protocol.username != null &&
          protocol.username!.isNotEmpty &&
          password != null &&
          password.isNotEmpty) {
        client = WebdavClient.basicAuth(
          url: '${protocol.address}:${protocol.port}',
          user: protocol.username!,
          pwd: password,
        );
      } else {
        client = WebdavClient.noAuth(
          url: '${protocol.address}:${protocol.port}',
        );
      }
      try {
        await client.ping();
        return true;
      } catch (e) {
        if (e is WebdavException) {
          logw('WebDAV connection failed with HTTP ${e.statusCode}.');
        } else {
          logw('WebDAV connection failed with ${e.runtimeType}.');
        }
        logw('WebDAV connection check failed.');
        return false;
      }
    case OAuthProtocolModel(
      :final providerType,
      :final clientId,
      :final credentialRef,
      :final rootId,
    ):
      try {
        final remote =
            OAuthRemoteTargetFactory(
              credentialStore: ref.read(credentialStoreProvider),
            ).create(
              OAuthRemoteTargetConfig(
                providerType: providerType,
                clientId: clientId,
                credentialRef: credentialRef,
                rootId: rootId,
              ),
            );
        await remote.list(limit: 1);
        return true;
      } catch (e) {
        logw('OAuth connection check failed with ${e.runtimeType}.');
        logw('OAuth connection check failed.');
        return false;
      }
  }
}
