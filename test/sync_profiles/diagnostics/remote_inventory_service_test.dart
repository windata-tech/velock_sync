import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';
import 'package:velock_sync/sync_profiles/diagnostics/remote_inventory_service.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await LocalDataManager.instance.init();
  });

  test(
    'passes the per-profile remote scope to the inventory factory',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final connections = ConnectionRepository(
        LocalDataManager.instance,
        InMemoryCredentialStore(),
        database,
      );
      await connections.setConnections([_connection()]);
      final remote = InMemoryObjectStore();
      ProtocolModel? receivedProtocol;
      List<String>? receivedScope;
      final service = RemoteInventoryService(
        connections: connections,
        remoteFactory:
            ({
              required connections,
              required protocol,
              required remoteRootSegments,
            }) async {
              receivedProtocol = protocol;
              receivedScope = List<String>.of(remoteRootSegments);
              return remote;
            },
      );

      final snapshot = await service.scan(
        connectionId: 'connection-1',
        vaultId: 'vault-1',
        remoteRootSegments: const ['团队 备份', '%', '#', '?'],
      );

      expect(receivedProtocol, isA<WebDavProtocolModel>());
      expect(
        (receivedProtocol as WebDavProtocolModel).address,
        'https://dav.example.test',
      );
      expect(receivedScope, ['团队 备份', '%', '#', '?']);
      expect(snapshot.totalCount, 0);
    },
  );
}

ConnectionModel _connection() => ConnectionModel(
  id: 'connection-1',
  name: 'WebDAV',
  source: 'Velock',
  target: 'Remote',
  protocol: const ProtocolModel.webDav(
    protocolType: WebDavProtocolType.https,
    address: 'https://dav.example.test',
    port: '443',
    username: 'alice',
    credentialRef: 'opaque-ref',
    path: '/root',
  ),
  createdAt: DateTime.utc(2026, 9, 26),
  updatedAt: DateTime.utc(2026, 9, 26),
  status: ConnectionStatus.active,
);
