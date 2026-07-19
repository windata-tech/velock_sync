import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  test('WebDAV preferences persist only an opaque credential reference', () {
    final protocol = ProtocolModel.webDav(
      protocolType: WebDavProtocolType.https,
      address: 'https://dav.example.test',
      port: '443',
      username: 'alice',
      credentialRef: 'velock-sync/webdav/opaque-id',
    );

    final json = protocol.toJson();

    expect(json['credentialRef'], 'velock-sync/webdav/opaque-id');
    expect(json, isNot(contains('password')));
  });

  test('OAuth preferences retain only public target configuration', () {
    final protocol = ProtocolModel.oauth(
      providerType: RemoteProviderType.googleDrive,
      clientId: 'public-client-id.apps.googleusercontent.com',
      credentialRef: 'velock-sync/oauth/opaque-id',
      rootId: 'appDataFolder',
      accountLabel: 'alice@example.test',
    );

    final json = protocol.toJson();
    final restored = ProtocolModel.fromJson(json);

    expect(restored, protocol);
    expect(protocol.targetLabel, 'alice@example.test');
    expect(protocol.credentialReference, 'velock-sync/oauth/opaque-id');
    expect(json, isNot(contains('accessToken')));
    expect(json, isNot(contains('refreshToken')));
    expect(json, isNot(contains('clientSecret')));
  });
}
