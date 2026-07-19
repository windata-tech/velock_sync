import 'dart:async';
import 'dart:convert';

import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_target_factory.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_service.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_session.dart';
import 'package:velock_sync/providers/oauth/oauth_public_client_configuration.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

class ConnectionRepository {
  ConnectionRepository(
    this._localDataManager,
    this._credentialStore,
    this._database,
  );

  final LocalDataManager _localDataManager;
  final CredentialStore _credentialStore;
  final SyncStateDatabase _database;

  Future<List<ConnectionModel>> loadConnections() async {
    final databasePayloads = await _database.readConnectionPayloads();
    if (databasePayloads.isNotEmpty) {
      return databasePayloads
          .map((payload) => ConnectionModel.fromJson(jsonDecode(payload)))
          .toList();
    }

    final json = _localDataManager.getStringList(AppKeys.connections);
    if (json == null) return [];

    var secureStorageMigrationFailed = false;
    final connections = <ConnectionModel>[];
    for (final value in json) {
      final raw = jsonDecode(value) as Map<String, dynamic>;
      var connection = ConnectionModel.fromJson(raw);
      final protocol = raw['protocol'];
      if (protocol is Map<String, dynamic> &&
          protocol['password'] is String &&
          connection.protocol is WebDavProtocolModel) {
        final legacyPassword = protocol['password'] as String;
        if (legacyPassword.isNotEmpty &&
            (connection.protocol as WebDavProtocolModel).credentialRef ==
                null) {
          try {
            final credentialRef = await _credentialStore.writeWebDavPassword(
              legacyPassword,
            );
            connection = connection.copyWith(
              protocol: (connection.protocol as WebDavProtocolModel).copyWith(
                credentialRef: credentialRef,
              ),
            );
          } on Object {
            // The old preference is intentionally left untouched: users can
            // retry migration or re-enter their password without data loss.
            secureStorageMigrationFailed = true;
          }
        }
      }
      connections.add(connection);
    }

    if (secureStorageMigrationFailed) return connections;

    await setConnections(connections);
    // Once the database and secure storage write complete, no copy of the
    // legacy connection JSON remains in regular preferences.
    await _localDataManager.setStringList(AppKeys.connections, []);
    return connections;
  }

  Future<void> setConnections(List<ConnectionModel> value) {
    final payloads = {
      for (final connection in value)
        connection.id: jsonEncode(connection.toJson()),
    };
    return _database.replaceConnectionPayloads(payloads);
  }

  Future<ConnectionModel?> getConnectionById(String id) async {
    final conns = await loadConnections();
    for (final connection in conns) {
      if (connection.id == id) return connection;
    }
    return null;
  }

  Future<String> storeWebDavPassword(String password) =>
      _credentialStore.writeWebDavPassword(password);

  Future<String?> readWebDavPassword(String? credentialRef) {
    if (credentialRef == null) return Future.value(null);
    return _credentialStore.readWebDavPassword(credentialRef);
  }

  Future<void> deleteCredential(String? credentialRef) async {
    if (credentialRef != null) await _credentialStore.delete(credentialRef);
  }

  /// Revokes a provider grant where the provider supports revocation before
  /// deleting its local secure reference. A revocation failure keeps both the
  /// connection and credentials intact for retry by the caller.
  Future<void> disconnectProtocol(ProtocolModel protocol) async {
    switch (protocol) {
      case WebDavProtocolModel(:final credentialRef):
        await deleteCredential(credentialRef);
      case OAuthProtocolModel(
        :final providerType,
        :final clientId,
        :final credentialRef,
      ):
        final config = OAuthPublicClientConfiguration.fromClientId(
          providerType: providerType,
          clientId: clientId,
        );
        await OAuthAuthorizationService(
          session: OAuthAuthorizationSession(
            stateStore: SecureOAuthAuthorizationStateStore(),
          ),
          tokenClient: OAuthTokenClient(),
          credentialStore: _credentialStore,
        ).disconnect(config: config, credentialRef: credentialRef);
    }
  }

  /// Reconstructs an OAuth-backed provider without exposing its token bundle to
  /// UI or sync callers.
  RemoteObjectStore createOAuthRemote(OAuthProtocolModel protocol) {
    return OAuthRemoteTargetFactory(credentialStore: _credentialStore).create(
      OAuthRemoteTargetConfig(
        providerType: protocol.providerType,
        clientId: protocol.clientId,
        credentialRef: protocol.credentialRef,
        rootId: protocol.rootId,
      ),
    );
  }
}
