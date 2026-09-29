import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_service.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/device_signing_key_store.dart';
import 'package:velock_sync/infrastructure/secure_storage/vault_key_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/initial_sync_assessment.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_core/engine/vault_protocol.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

class _Connections implements ConnectionRepository {
  _Connections(this.connection);

  final ConnectionModel connection;
  String? lastPasswordRef;

  @override
  Future<ConnectionModel?> getConnectionById(String id) async => connection;

  @override
  Future<String?> readWebDavPassword(String? credentialRef) async {
    lastPasswordRef = credentialRef;
    return 'secret';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VaultKeys implements VaultKeyStore {
  @override
  Future<Uint8List?> readRootKey(String keyRef) async =>
      Uint8List.fromList(List<int>.filled(32, 7));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SigningKeys implements DeviceSigningKeyStore {
  _SigningKeys(this.keyPair);

  final SimpleKeyPair keyPair;

  @override
  Future<SimpleKeyPair?> readEd25519Key(String keyRef) async => keyPair;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Captures the exact store the service reconstructed for this task.
class _CapturingRunner extends SyncProfileRunner {
  _CapturingRunner(super.database);

  RemoteObjectStore? remote;
  String? ranProfileId;
  int calls = 0;

  @override
  Future<SyncProfileRunResult> run({
    required String profileId,
    required String vaultId,
    required String deviceId,
    required VaultProtocolDocument protocol,
    required SyncDatasetAdapter dataset,
    required RemoteObjectStore remote,
    ExportCursor cursor = ExportCursor.empty,
    BatchLimits uploadLimits = const BatchLimits(),
    DownloadLimits downloadLimits = const DownloadLimits(),
    int maxUploadBatches = 100,
    bool enableGarbageCollection = false,
    Future<void> Function()? preflight,
    Future<void> Function()? postProtocolPreflight,
    Iterable<String>? trustedProducerDeviceIds,
  }) async {
    calls++;
    this.remote = remote;
    ranProfileId = profileId;
    return const SyncProfileRunResult(
      runId: 'run-1',
      upload: UploadRunResult.idle(),
      download: DownloadRunResult(0),
    );
  }
}

ConnectionModel _connection() => ConnectionModel(
  id: 'cloud',
  name: '我的 NAS',
  source: 'source',
  target: 'target',
  protocol: const ProtocolModel.webDav(
    protocolType: WebDavProtocolType.https,
    address: 'https://nas.invalid/base',
    port: '443',
    path: '/entry',
    credentialRef: 'cred-1',
  ),
  createdAt: DateTime.utc(2026, 9, 26),
  updatedAt: DateTime.utc(2026, 9, 26),
  status: ConnectionStatus.active,
);

SelectedFolderSyncProfile _profile({List<String> segments = const []}) =>
    SelectedFolderSyncProfile(
      profileId: 'profile-1',
      datasetId: 'dataset-1',
      vaultId: 'vault-1',
      deviceId: 'device-1',
      displayName: 'Documents',
      rootPath: '/safe/documents',
      connectionId: 'cloud',
      remoteRootSegments: segments,
      keyId: 'key-1',
      rootKeyRef: 'velock-sync/vault-root/opaque',
      signingKeyRef: 'velock-sync/device-signing/opaque',
      createdAt: DateTime.utc(2026, 9, 26),
    );

void main() {
  late SyncStateDatabase database;
  late SelectedFolderSyncProfileRepository profiles;
  late _Connections connections;
  late _CapturingRunner runner;
  late List<WebDavProtocolModel> scopes;
  late Directory staging;
  late SimpleKeyPair signingKey;

  setUp(() async {
    database = await SyncStateDatabase.inMemory();
    profiles = SelectedFolderSyncProfileRepository(database);
    connections = _Connections(_connection());
    runner = _CapturingRunner(database);
    scopes = [];
    staging = await Directory.systemTemp.createTemp('velock-folder-scope');
    signingKey = await Ed25519().newKeyPair();
  });

  tearDown(() async {
    await database.close();
    await staging.delete(recursive: true);
  });

  SelectedFolderSyncService service({RemoteObjectStore? remote}) =>
      SelectedFolderSyncService(
        database: database,
        profiles: profiles,
        connections: connections,
        vaultKeys: _VaultKeys(),
        signingKeys: _SigningKeys(signingKey),
        stagingRoot: staging,
        runner: runner,
        remoteFactory: ({required protocol, required password}) {
          scopes.add(protocol);
          return remote ?? InMemoryObjectStore();
        },
      );

  test('an untouched task keeps the connection root as its scope', () async {
    await profiles.save(_profile());

    final assessment = await service().inspectInitialSync('profile-1');

    expect(assessment.remoteState, InitialSyncRemoteState.empty);
    // Without a chosen folder the connection protocol is used unchanged, so
    // the provider path is still resolved later by the default factory.
    expect(scopes.single.address, 'https://nas.invalid/base');
    expect(scopes.single.path, '/entry');
    expect(connections.lastPasswordRef, 'cred-1');
  });

  test('inspect reads vault state inside the task’s own folder', () async {
    final remote = InMemoryObjectStore();
    await remote.put(
      LogicalKeys.protocol('vault-1'),
      Stream.value(Uint8List.fromList([1])),
      contentLength: 1,
      ifAbsent: true,
    );
    await profiles.save(_profile(segments: const ['USB_HDD_8T', '111']));

    final assessment = await service(
      remote: remote,
    ).inspectInitialSync('profile-1');

    expect(assessment.remoteState, InitialSyncRemoteState.expectedVault);
    expect(
      scopes.single.address,
      'https://nas.invalid/base/entry/USB_HDD_8T/111',
    );
    expect(
      scopes.single.path,
      isNull,
      reason: 'the provider path is folded in',
    );
    expect(connections.lastPasswordRef, 'cred-1');
  });

  test('run reconstructs the remote store inside the task’s folder', () async {
    await profiles.save(_profile(segments: const ['USB_HDD_8T', '111']));

    final result = await service().run('profile-1');

    expect(result.runId, 'run-1');
    expect(runner.calls, 1);
    expect(runner.ranProfileId, 'profile-1');
    expect(runner.remote, isNotNull);
    expect(
      scopes.single.address,
      'https://nas.invalid/base/entry/USB_HDD_8T/111',
    );
  });

  test('run cannot start while another page holds the location lock', () async {
    await profiles.save(_profile(segments: const ['111']));
    await database.tryAcquireProfileLock(
      profileId: 'velock-location:profile-1',
      owner: 'other-page',
      now: DateTime.now().toUtc(),
      staleAfter: const Duration(minutes: 5),
    );

    await expectLater(
      service().run('profile-1'),
      throwsA(isA<SyncRunBusyException>()),
    );
    expect(runner.calls, 0);
    expect(scopes, isEmpty);
  });

  test(
    'inspect cannot start while another page holds the location lock',
    () async {
      await profiles.save(_profile());
      await database.tryAcquireProfileLock(
        profileId: 'velock-location:profile-1',
        owner: 'other-page',
        now: DateTime.now().toUtc(),
        staleAfter: const Duration(minutes: 5),
      );

      await expectLater(
        service().inspectInitialSync('profile-1'),
        throwsA(isA<SyncRunBusyException>()),
      );
      expect(scopes, isEmpty);
    },
  );

  test('the location lock is released after a completed run', () async {
    await profiles.save(_profile());

    await service().run('profile-1');
    final reclaimed = await database.tryAcquireProfileLock(
      profileId: 'velock-location:profile-1',
      owner: 'next-page',
      now: DateTime.now().toUtc(),
      staleAfter: const Duration(minutes: 5),
    );

    expect(reclaimed, isTrue);
  });

  test('a relocated folder is used by the next run', () async {
    await profiles.save(_profile());
    final stored = (await profiles.read('profile-1'))!;
    await profiles.selectSyncFolder(
      expected: stored,
      segments: const ['USB_HDD_8T', '111'],
    );

    await service().run('profile-1');

    expect(
      scopes.single.address,
      'https://nas.invalid/base/entry/USB_HDD_8T/111',
    );
  });
}
