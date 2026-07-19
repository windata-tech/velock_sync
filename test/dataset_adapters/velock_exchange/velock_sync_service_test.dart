import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_discovery.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_credential_store.dart';
import 'package:velock_sync/infrastructure/storage/available_space_probe.dart';
import 'package:velock_sync/infrastructure/storage/staging_disk_preflight.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await LocalDataManager.instance.init();
  });

  test(
    'runs active paired profiles through the standard runner using the secure WebDAV credential reference',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final remote = InMemoryObjectStore();
      await _publishIncomingFixture(
        remote,
        producerId: fixture.profile.pairedProducerId,
        batchId: 'paired-batch',
      );
      final dataset = _RecordingDataset();
      final adapterFactory = _FakeAdapterFactory(dataset);
      WebDavProtocolModel? receivedProtocol;
      String? receivedPassword;
      var remoteFactoryCalls = 0;
      final service = fixture.service(
        adapterFactory: adapterFactory,
        remoteFactory: ({required protocol, required password}) {
          remoteFactoryCalls += 1;
          receivedProtocol = protocol;
          receivedPassword = password;
          return remote;
        },
      );

      final result = await service.run(fixture.profile.profileId);

      expect(result.download.importedBatchCount, 1);
      expect(dataset.imported, hasLength(1));
      expect(adapterFactory.createdFor, fixture.profile.profileId);
      expect(remoteFactoryCalls, 1);
      expect(receivedProtocol!.credentialRef, fixture.credentialRef);
      expect(receivedPassword, 'password-from-secure-store');
      expect(
        jsonEncode(fixture.connection.toJson()),
        isNot(contains('password-from-secure-store')),
      );
      expect(
        await fixture.database.appliedSequence(
          profileId: fixture.profile.profileId,
          producerDeviceId: fixture.profile.pairedProducerId,
        ),
        1,
      );
      expect(
        await fixture.database.readTrustedDevicePublicKeys(
          vaultId: fixture.profile.vaultId,
        ),
        isEmpty,
      );
    },
  );

  for (final provider in [
    RemoteProviderType.googleDrive,
    RemoteProviderType.oneDrive,
  ]) {
    test(
      'runs a paired Velock profile through the shared OAuth remote factory for ${provider.name}',
      () async {
        final fixture = await _Fixture.create(
          connection: _oauthConnection(provider),
        );
        addTearDown(fixture.dispose);
        final remote = InMemoryObjectStore();
        OAuthProtocolModel? receivedProtocol;
        var oauthRemoteFactoryCalls = 0;

        final result = await fixture
            .service(
              adapterFactory: _FakeAdapterFactory(_RecordingDataset()),
              oauthRemoteFactory: (protocol) {
                oauthRemoteFactoryCalls += 1;
                receivedProtocol = protocol;
                return remote;
              },
            )
            .run(fixture.profile.profileId);

        expect(result.download.importedBatchCount, 0);
        expect(oauthRemoteFactoryCalls, 1);
        expect(receivedProtocol!.providerType, provider);
        expect(receivedProtocol!.credentialRef, 'oauth-secure-ref');
        expect(
          jsonEncode(fixture.connection.toJson()),
          isNot(contains('access-token')),
        );
      },
    );
  }

  test(
    'rejects a missing Velock profile before any adapter or remote work',
    () async {
      final fixture = await _Fixture.create(persistProfile: false);
      addTearDown(fixture.dispose);
      final adapterFactory = _FakeAdapterFactory(_RecordingDataset());
      var remoteFactoryCalls = 0;

      await expectLater(
        fixture
            .service(
              adapterFactory: adapterFactory,
              remoteFactory: ({required protocol, required password}) {
                remoteFactoryCalls += 1;
                return InMemoryObjectStore();
              },
            )
            .run('missing-profile'),
        throwsA(isA<StateError>()),
      );

      expect(adapterFactory.createCalls, 0);
      expect(remoteFactoryCalls, 0);
    },
  );

  test(
    'rejects a non-Velock common profile with the strict typed parser',
    () async {
      final fixture = await _Fixture.create(persistProfile: false);
      addTearDown(fixture.dispose);
      final profile = fixture.profile;
      await fixture.profiles.save(
        SyncProfileEnvelope(
          kind: SyncDatasetKind.selectedFolder,
          profileId: profile.profileId,
          datasetId: profile.datasetId,
          vaultId: profile.vaultId,
          deviceId: profile.deviceId,
          displayName: profile.displayName,
          connectionId: profile.connectionId,
          state: profile.state,
          backgroundPolicy: profile.backgroundPolicy,
          dataset: const {},
          createdAt: profile.createdAt,
        ),
      );

      await expectLater(
        fixture
            .service(adapterFactory: _FakeAdapterFactory(_RecordingDataset()))
            .run(profile.profileId),
        throwsFormatException,
      );
    },
  );

  test(
    'rejects an inactive Velock profile before remote construction',
    () async {
      final fixture = await _Fixture.create(
        profile: _profile(state: SyncProfileState.paused),
      );
      addTearDown(fixture.dispose);
      final adapterFactory = _FakeAdapterFactory(_RecordingDataset());
      var remoteFactoryCalls = 0;

      await expectLater(
        fixture
            .service(
              adapterFactory: adapterFactory,
              remoteFactory: ({required protocol, required password}) {
                remoteFactoryCalls += 1;
                return InMemoryObjectStore();
              },
            )
            .run(fixture.profile.profileId),
        throwsA(isA<StateError>()),
      );

      expect(adapterFactory.createCalls, 0);
      expect(remoteFactoryCalls, 0);
    },
  );

  test(
    'rejects a profile whose persisted remote connection is missing',
    () async {
      final fixture = await _Fixture.create(persistConnection: false);
      addTearDown(fixture.dispose);
      final adapterFactory = _FakeAdapterFactory(_RecordingDataset());

      await expectLater(
        fixture
            .service(adapterFactory: adapterFactory)
            .run(fixture.profile.profileId),
        throwsA(isA<StateError>()),
      );

      expect(adapterFactory.createCalls, 0);
    },
  );

  test(
    'does not construct a remote after adapter revalidation fails',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final adapterFactory = _FakeAdapterFactory(
        _RecordingDataset(),
        error: const VelockDatasetAdapterUnavailableException(
          VelockExchangeAvailability.authorizationRequired,
        ),
      );
      var remoteFactoryCalls = 0;

      await expectLater(
        fixture
            .service(
              adapterFactory: adapterFactory,
              remoteFactory: ({required protocol, required password}) {
                remoteFactoryCalls += 1;
                return InMemoryObjectStore();
              },
            )
            .run(fixture.profile.profileId),
        throwsA(isA<VelockDatasetAdapterUnavailableException>()),
      );

      expect(adapterFactory.createCalls, 1);
      expect(remoteFactoryCalls, 0);
    },
  );

  test(
    'fails disk preflight before remote construction or protocol bootstrap',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final remote = InMemoryObjectStore();
      var remoteFactoryCalls = 0;

      await expectLater(
        fixture
            .service(
              adapterFactory: _FakeAdapterFactory(_RecordingDataset()),
              availableSpace: const _FixedAvailableSpaceProbe(0),
              minimumFreeStagingBytes: 1,
              remoteFactory: ({required protocol, required password}) {
                remoteFactoryCalls += 1;
                return remote;
              },
            )
            .run(fixture.profile.profileId),
        throwsA(isA<StagingDiskSpaceException>()),
      );

      expect(remoteFactoryCalls, 0);
      expect(
        await remote.stat(LogicalKeys.protocol(fixture.profile.vaultId)),
        isNull,
      );
    },
  );
}

class _Fixture {
  _Fixture._({
    required this.database,
    required this.profiles,
    required this.connections,
    required this.profile,
    required this.connection,
    required this.credentialRef,
    required this.stagingRoot,
  });

  final SyncStateDatabase database;
  final SyncProfileRepository profiles;
  final ConnectionRepository connections;
  final VelockSyncProfile profile;
  final ConnectionModel connection;
  final String credentialRef;
  final Directory stagingRoot;

  static Future<_Fixture> create({
    VelockSyncProfile? profile,
    bool persistProfile = true,
    bool persistConnection = true,
    ConnectionModel? connection,
  }) async {
    final database = await SyncStateDatabase.inMemory();
    final profiles = SyncProfileRepository(database);
    final credentials = InMemoryCredentialStore();
    final connections = ConnectionRepository(
      LocalDataManager.instance,
      credentials,
      database,
    );
    final credentialRef = await credentials.writeWebDavPassword(
      'password-from-secure-store',
    );
    final resolvedProfile = profile ?? _profile();
    final resolvedConnection = connection ?? _connection(credentialRef);
    if (persistProfile) await profiles.save(resolvedProfile.toEnvelope());
    if (persistConnection) {
      await connections.setConnections([resolvedConnection]);
    }
    return _Fixture._(
      database: database,
      profiles: profiles,
      connections: connections,
      profile: resolvedProfile,
      connection: resolvedConnection,
      credentialRef: credentialRef,
      stagingRoot: await Directory.systemTemp.createTemp(
        'velock-service-test-',
      ),
    );
  }

  VelockSyncService service({
    required VelockDatasetAdapterFactory adapterFactory,
    VelockRemoteFactory? remoteFactory,
    VelockOAuthRemoteFactory? oauthRemoteFactory,
    AvailableSpaceProbe? availableSpace,
    int minimumFreeStagingBytes = 64 * 1024 * 1024,
  }) => VelockSyncService(
    database: database,
    profiles: profiles,
    connections: connections,
    adapterFactory: adapterFactory,
    stagingRoot: stagingRoot,
    remoteFactory: remoteFactory,
    oauthRemoteFactory: oauthRemoteFactory,
    availableSpace: availableSpace,
    minimumFreeStagingBytes: minimumFreeStagingBytes,
  );

  Future<void> dispose() async {
    await database.close();
    if (await stagingRoot.exists()) await stagingRoot.delete(recursive: true);
  }
}

VelockSyncProfile _profile({
  SyncProfileState state = SyncProfileState.active,
}) => VelockSyncProfile(
  profileId: 'profile-1',
  datasetId: 'dataset-1',
  vaultId: 'vault-1',
  deviceId: 'consumer-1',
  displayName: 'Velock vault',
  connectionId: 'connection-1',
  pairedProducerId: 'paired-producer',
  pairedProducerPublicKeyId: 'paired-producer-key',
  exchangeBindingId: 'exchange-1',
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  state: state,
  createdAt: DateTime.utc(2026, 7, 17),
);

ConnectionModel _oauthConnection(RemoteProviderType provider) =>
    ConnectionModel(
      id: 'connection-1',
      name: 'Test ${provider.name}',
      source: 'device',
      target: 'remote',
      protocol: ProtocolModel.oauth(
        providerType: provider,
        clientId: 'public-client-id',
        credentialRef: 'oauth-secure-ref',
        rootId: 'appDataFolder',
      ),
      createdAt: DateTime.utc(2026, 7, 17),
      updatedAt: DateTime.utc(2026, 7, 17),
      status: ConnectionStatus.active,
    );

ConnectionModel _connection(String credentialRef) => ConnectionModel(
  id: 'connection-1',
  name: 'Test WebDAV',
  source: 'device',
  target: 'remote',
  protocol: ProtocolModel.webDav(
    protocolType: WebDavProtocolType.https,
    address: 'https://example.test',
    port: '443',
    username: 'velock',
    credentialRef: credentialRef,
    path: 'sync',
  ),
  createdAt: DateTime.utc(2026, 7, 17),
  updatedAt: DateTime.utc(2026, 7, 17),
  status: ConnectionStatus.active,
);

class _FakeAdapterFactory implements VelockDatasetAdapterFactory {
  _FakeAdapterFactory(this.dataset, {this.error});

  final SyncDatasetAdapter dataset;
  final Object? error;
  int createCalls = 0;
  String? createdFor;

  @override
  Future<SyncDatasetAdapter> create(VelockSyncProfile profile) async {
    createCalls += 1;
    createdFor = profile.profileId;
    if (error != null) throw error!;
    return dataset;
  }
}

class _FixedAvailableSpaceProbe implements AvailableSpaceProbe {
  const _FixedAvailableSpaceProbe(this.bytes);

  final int bytes;

  @override
  Future<int> availableBytes(Directory directory) async => bytes;
}

class _RecordingDataset implements SyncDatasetAdapter {
  final List<IncomingBatch> imported = [];

  @override
  Future<void> acknowledgePublishedBatch({
    required String batchId,
    required int sequence,
  }) async {}

  @override
  Future<ImportResult> acceptIncomingBatch(IncomingBatch batch) async {
    imported.add(batch);
    return const ImportResult();
  }

  @override
  Future<DatasetAccessState> checkAccess() async =>
      DatasetAccessState.available;

  @override
  Future<DatasetDescriptor> describe() async => const DatasetDescriptor(
    datasetId: 'dataset-1',
    vaultId: 'vault-1',
    kind: DatasetKind.velockManaged,
    displayName: 'Velock vault',
    accessState: DatasetAccessState.available,
    encryptionMode: EncryptionMode.velockManaged,
  );

  @override
  Future<PreparedOutgoingBatch?> prepareNextBatch({
    required ExportCursor cursor,
    required BatchLimits limits,
  }) async => null;
}

Future<void> _publishIncomingFixture(
  InMemoryObjectStore remote, {
  required String producerId,
  required String batchId,
}) async {
  const vaultId = 'vault-1';
  final operations = Uint8List.fromList(<int>[1, 2, 3]);
  final envelope = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'vaultId': vaultId,
        'sourceDeviceId': producerId,
        'sequence': 1,
        'batchId': batchId,
        'operations': {
          'cipherSize': operations.length,
          'cipherSha256': sha256.convert(operations).toString(),
        },
        'blobs': const [],
      }),
    ),
  );
  final commit = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'vaultId': vaultId,
        'sourceDeviceId': producerId,
        'sequence': 1,
        'batchId': batchId,
        'envelopeSha256': sha256.convert(envelope).toString(),
      }),
    ),
  );
  Future<void> put(String key, Uint8List value) => remote.put(
    key,
    Stream.value(value),
    contentLength: value.length,
    ifAbsent: true,
  );

  await put(
    LogicalKeys.batchOperations(vaultId, producerId, 1, batchId),
    operations,
  );
  await put(
    LogicalKeys.batchEnvelope(vaultId, producerId, 1, batchId),
    envelope,
  );
  await put(LogicalKeys.commit(vaultId, producerId, 1, batchId), commit);
}
