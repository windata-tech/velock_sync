import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/google_drive/google_drive_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_target_factory.dart';
import 'package:velock_sync/providers/one_drive/one_drive_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  final factory = OAuthRemoteTargetFactory(
    credentialStore: InMemoryCredentialStore(),
  );

  test('constructs Google Drive from public config and opaque reference', () {
    final config = OAuthRemoteTargetConfig(
      providerType: RemoteProviderType.googleDrive,
      clientId: 'public-client',
      credentialRef: 'velock-sync/oauth/opaque',
      rootId: 'root',
    );
    expect(factory.create(config), isA<GoogleDriveObjectStore>());
    expect(config.toSafeJson().values.join(), isNot(contains('refresh')));
  });

  test('constructs OneDrive and rejects non-OAuth providers', () {
    expect(
      factory.create(
        const OAuthRemoteTargetConfig(
          providerType: RemoteProviderType.oneDrive,
          clientId: 'client',
          credentialRef: 'velock-sync/oauth/opaque',
          rootId: 'root',
        ),
      ),
      isA<OneDriveObjectStore>(),
    );
    expect(
      () => factory.create(
        const OAuthRemoteTargetConfig(
          providerType: RemoteProviderType.webDav,
          clientId: 'client',
          credentialRef: 'ref',
          rootId: 'root',
        ),
      ),
      throwsUnsupportedError,
    );
  });

  test('refuses secret-requiring providers without a token broker', () {
    for (final providerType in [
      RemoteProviderType.baiduNetdisk,
      RemoteProviderType.aliyunDrive,
    ]) {
      expect(
        () => factory.create(
          OAuthRemoteTargetConfig(
            providerType: providerType,
            clientId: 'client',
            credentialRef: 'velock-sync/oauth/opaque',
            rootId: 'root',
          ),
        ),
        throwsA(
          isA<OAuthProviderRequiresTokenBrokerException>().having(
            (error) => error.errorCode,
            'errorCode',
            'provider.oauth.token_broker_required',
          ),
        ),
      );
    }
  });
}
