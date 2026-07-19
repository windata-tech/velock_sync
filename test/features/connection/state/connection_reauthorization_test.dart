import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  group('reauthorizedOAuthConnection', () {
    test(
      'replaces only the opaque OAuth reference and marks status pending',
      () {
        final original = _oauthConnection();
        final replacement = reauthorizedOAuthConnection(
          original,
          const OAuthProtocolModel(
            providerType: RemoteProviderType.googleDrive,
            clientId: 'public-client',
            credentialRef: 'new-secure-ref',
            rootId: 'folder-2',
            accountLabel: 'Account two',
          ),
          now: () => DateTime.utc(2026, 7, 15, 12),
        );

        expect(replacement.id, original.id);
        expect(replacement.createdAt, original.createdAt);
        expect(replacement.status, ConnectionStatus.pending);
        expect(replacement.updatedAt, DateTime.utc(2026, 7, 15, 12));
        expect(replacement.target, 'Account two');
        expect(
          (replacement.protocol as OAuthProtocolModel).credentialRef,
          'new-secure-ref',
        );
      },
    );

    test('rejects replacing a non-OAuth connection', () {
      final webDav = ConnectionModel(
        id: 'connection-1',
        name: 'WebDAV',
        source: 'folder',
        target: 'dav.example.test:443',
        protocol: const WebDavProtocolModel(
          protocolType: WebDavProtocolType.https,
          address: 'https://dav.example.test',
          port: '443',
        ),
        createdAt: DateTime.utc(2026, 7, 15),
        updatedAt: DateTime.utc(2026, 7, 15),
        status: ConnectionStatus.active,
      );

      expect(
        () => reauthorizedOAuthConnection(
          webDav,
          const OAuthProtocolModel(
            providerType: RemoteProviderType.oneDrive,
            clientId: 'client',
            credentialRef: 'secure-ref',
            rootId: 'root',
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('reconfiguredWebDavConnection', () {
    test('retains identity and replaces only WebDAV configuration', () {
      final original = ConnectionModel(
        id: 'connection-1',
        name: 'WebDAV',
        source: 'folder',
        target: 'https://old.example.test:443',
        protocol: const WebDavProtocolModel(
          protocolType: WebDavProtocolType.https,
          address: 'https://old.example.test',
          port: '443',
          credentialRef: 'old-secure-ref',
        ),
        createdAt: DateTime.utc(2026, 7, 14),
        updatedAt: DateTime.utc(2026, 7, 14),
        status: ConnectionStatus.active,
      );

      final replacement = reconfiguredWebDavConnection(
        original,
        const WebDavProtocolModel(
          protocolType: WebDavProtocolType.https,
          address: 'https://new.example.test',
          port: '8443',
          credentialRef: 'new-secure-ref',
        ),
        now: () => DateTime.utc(2026, 7, 15, 12),
      );

      expect(replacement.id, original.id);
      expect(replacement.createdAt, original.createdAt);
      expect(replacement.status, ConnectionStatus.pending);
      expect(replacement.updatedAt, DateTime.utc(2026, 7, 15, 12));
      expect(replacement.target, 'https://new.example.test:8443');
      expect(replacement.targetDescription, 'address=https://new.example.test');
      expect(
        (replacement.protocol as WebDavProtocolModel).credentialRef,
        'new-secure-ref',
      );
    });

    test('rejects replacing a non-WebDAV connection', () {
      expect(
        () => reconfiguredWebDavConnection(
          _oauthConnection(),
          const WebDavProtocolModel(
            protocolType: WebDavProtocolType.https,
            address: 'https://dav.example.test',
            port: '443',
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}

ConnectionModel _oauthConnection() => ConnectionModel(
  id: 'connection-1',
  name: 'Drive',
  source: 'folder',
  target: 'Account one',
  protocol: const OAuthProtocolModel(
    providerType: RemoteProviderType.googleDrive,
    clientId: 'public-client',
    credentialRef: 'old-secure-ref',
    rootId: 'folder-1',
    accountLabel: 'Account one',
  ),
  createdAt: DateTime.utc(2026, 7, 14),
  updatedAt: DateTime.utc(2026, 7, 14),
  status: ConnectionStatus.active,
);
