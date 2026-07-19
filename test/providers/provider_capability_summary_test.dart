import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/providers/provider_capability_summary.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  group('providerCapabilitySummary', () {
    test('describes the concrete Google adapter guarantees', () {
      final summary = providerCapabilitySummary(
        const ProtocolModel.oauth(
          providerType: RemoteProviderType.googleDrive,
          clientId: 'public-client',
          credentialRef: 'opaque-ref',
          rootId: 'appDataFolder',
        ),
      );

      expect(summary.providerName, 'Google Drive');
      expect(summary.features, containsAll(['PKCE 授权', '可恢复上传', '范围下载']));
      expect(summary.limitations.single, contains('授权应用'));
    });

    test('does not overpromise WebDAV resumable upload', () {
      final summary = providerCapabilitySummary(
        const ProtocolModel.webDav(
          protocolType: WebDavProtocolType.https,
          address: 'https://dav.example.test',
          port: '443',
        ),
      );

      expect(summary.providerName, 'WebDAV');
      expect(summary.features, isNot(contains('可恢复上传')));
      expect(summary.limitations.single, contains('服务器能力'));
    });
  });
}
