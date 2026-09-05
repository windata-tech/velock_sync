import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_target_factory.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

part '../../../generated/features/connection/state/protocol_provider.g.dart';

/// Runs a one-shot connectivity probe for [protocol].
///
/// Callers that need a single check (the save form, status sweeps) should use
/// this helper directly instead of `protocolConnectCheckerProvider(...).future`.
/// The generated provider is autoDispose; in Riverpod 3, awaiting `.future` of
/// an autoDispose provider that gets disposed while the await is pending throws
/// `UnmountedRefException`, which previously turned successful saves into
/// spurious "保存失败" failures.
Future<bool> probeProtocolConnection({
  required CredentialStore credentials,
  required ProtocolModel protocol,
}) async {
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
      try {
        WebdavClient client;
        final password = await credentials.readWebDavPassword(
          protocol.credentialRef ?? '',
        );
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
          logw(
            'WebDAV probe for ${protocol.address}:${protocol.port} has no '
            'readable credentials; the request will be sent unauthenticated.',
          );
          client = WebdavClient.noAuth(
            url: '${protocol.address}:${protocol.port}',
          );
        }
        await client.ping();
        return true;
      } catch (e) {
        logw('WebDAV connection check failed with ${e.runtimeType}: $e');
        return false;
      }
    case OAuthProtocolModel(
      :final providerType,
      :final clientId,
      :final credentialRef,
      :final rootId,
    ):
      try {
        final remote = OAuthRemoteTargetFactory(credentialStore: credentials)
            .create(
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

@riverpod
Future<bool> protocolConnectChecker(Ref ref, ProtocolModel protocol) {
  return probeProtocolConnection(
    credentials: ref.read(credentialStoreProvider),
    protocol: protocol,
  );
}
