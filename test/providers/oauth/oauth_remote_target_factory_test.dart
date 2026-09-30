import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/providers/aliyun_drive/aliyun_drive_object_store.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
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

  test('constructs Baidu Netdisk and Aliyun Drive stores', () {
    expect(
      factory.create(
        const OAuthRemoteTargetConfig(
          providerType: RemoteProviderType.baiduNetdisk,
          clientId: 'app-key',
          credentialRef: 'velock-sync/oauth/opaque',
          rootId: '/apps/Velock Sync',
        ),
      ),
      isA<BaiduNetdiskObjectStore>(),
    );
    expect(
      factory.create(
        const OAuthRemoteTargetConfig(
          providerType: RemoteProviderType.aliyunDrive,
          clientId: 'client',
          credentialRef: 'velock-sync/oauth/opaque',
          rootId: 'root',
        ),
      ),
      isA<AliyunDriveObjectStore>(),
    );
  });
}
