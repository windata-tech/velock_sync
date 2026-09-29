import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// QA 2026-09-29 (finding 2): a connection saved without a name kept the page
/// title 「新建连接」, which then read like an "add" button in the list.
void main() {
  const webDav = ProtocolModel.webDav(
    protocolType: WebDavProtocolType.http,
    address: 'http://192.168.1.20',
    port: '5005',
    path: '/',
  );

  test('WebDAV is named after its host, with a non-default port', () {
    expect(defaultConnectionName(webDav), '192.168.1.20:5005');
    expect(
      defaultConnectionName(
        const ProtocolModel.webDav(
          protocolType: WebDavProtocolType.https,
          address: 'https://dav.example.com',
          port: '443',
        ),
      ),
      'dav.example.com',
    );
  });

  test('a cloud drive is named after its account, else its provider', () {
    expect(
      defaultConnectionName(
        const ProtocolModel.oauth(
          providerType: RemoteProviderType.googleDrive,
          clientId: 'id',
          credentialRef: 'ref',
          rootId: 'root',
          accountLabel: 'me@example.com',
        ),
      ),
      'me@example.com',
    );
    expect(
      defaultConnectionName(
        const ProtocolModel.oauth(
          providerType: RemoteProviderType.googleDrive,
          clientId: 'id',
          credentialRef: 'ref',
          rootId: 'root',
        ),
      ),
      isNot(anyOf('新建连接', 'New Connection', '')),
    );
  });

  Future<ConnectionModel> save(String draftName) async {
    final repository = _Repository();
    final container = ProviderContainer(
      overrides: [
        connectionRepositoryProvider.overrideWithValue(repository),
        protocolConnectionProbeProvider.overrideWithValue(
          ({required credentials, required protocol}) async => true,
        ),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(connectionCreationProvider.notifier)
        .prepareNewConnection(name: draftName, source: '格间', target: null);
    await container
        .read(connectionCreationProvider.notifier)
        .setProtocolAndFinalize(protocolModel: webDav);
    return repository.saved.single;
  }

  test('the page title is replaced, in either language', () async {
    expect((await save('新建连接')).name, '192.168.1.20:5005');
    expect((await save('New Connection')).name, '192.168.1.20:5005');
    expect((await save('   ')).name, '192.168.1.20:5005');
  });

  test('a name the user typed is kept', () async {
    expect((await save('家里的 NAS')).name, '家里的 NAS');
  });
}

class _Repository implements ConnectionRepository {
  List<ConnectionModel> saved = const [];

  @override
  Future<List<ConnectionModel>> loadConnections() async => const [];

  @override
  Future<void> setConnections(List<ConnectionModel> value) async {
    saved = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
