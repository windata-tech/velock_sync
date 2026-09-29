import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_current_snapshot_transport.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control_files.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_recovery.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_trust.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  late Directory root, exchange;
  late SyncStateDatabase db;
  late SyncProfileRepository profiles;
  late VelockSnapshotRecoveryService service;
  late _Factory factory;
  late VelockExchangeDatasetAdapter adapter;
  late InMemoryObjectStore remote;
  late SimpleKeyPair sourceKey, ownerKey;
  late DateTime now;
  late List<Uri> launches;
  late Uint8List manifest;
  final profile = VelockSyncProfile(
    profileId: 'p',
    datasetId: 'dataset',
    vaultId: 'vault',
    deviceId: 'sync',
    displayName: 'Backup',
    connectionId: 'nas',
    pairedProducerId: 'consumer',
    pairedProducerPublicKeyId: 'root-key',
    exchangeBindingId: 'a' * 43,
    trustedProducerIds: ['source', 'consumer'],
    remoteRootSegments: ['new'],
    snapshotDiscoveryPending: true,
    backgroundPolicy: const SyncProfileBackgroundPolicy(),
    state: SyncProfileState.active,
    createdAt: DateTime.utc(2026, 9, 27),
  );
  Future<void> put(String key, List<int> bytes) async {
    await remote.put(key, Stream.value(bytes), contentLength: bytes.length);
  }

  Future<void> trust({
    KeyPair? signer,
    String? binding,
    bool includeSource = true,
  }) async {
    final bytes = await VelockSnapshotTrust.sign(
      vaultId: 'vault',
      keyId: 'root-key',
      actorDeviceId: 'consumer',
      exchangeBindingId: binding ?? profile.exchangeBindingId,
      activeProducerKeys: {
        'consumer': base64UrlEncode((await ownerKey.extractPublicKey()).bytes),
        if (includeSource)
          'source': base64UrlEncode((await sourceKey.extractPublicKey()).bytes),
      },
      now: now,
      signingKey: signer ?? ownerKey,
    );
    final f = File('${exchange.path}/Control/SnapshotTrust.json');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  Future<void> snapshot({KeyPair? signer, bool corrupt = false}) async {
    final part = utf8.encode('encrypted full body');
    final body = {
      'kind': VelockSnapshotInventory.kind,
      'version': 2,
      'snapshotId': 'snapshot',
      'vaultId': 'vault',
      'producerId': 'source',
      'keyId': 'root-key',
      'createdAt': now.toIso8601String(),
      'recordCount': 2,
      'heads': {
        'source': {'sequence': 7, 'batchId': 'old-7'},
      },
      'parts': [
        {
          'number': 1,
          'size': part.length,
          'sha256': sha256.convert(part).toString(),
          'records': 2,
        },
      ],
      'blobs': [],
    };
    final sig = await Ed25519().sign([
      ...utf8.encode('VelockCurrentStateSnapshot/2\n'),
      ...snapshotJson(body),
    ], keyPair: signer ?? sourceKey);
    manifest = snapshotJson({...body, 'signature': base64UrlEncode(sig.bytes)});
    final prefix = 'vaults/vault/current-snapshots/snapshot/';
    await put('${prefix}manifest.json', manifest);
    await put(
      '${prefix}part-1.enc',
      corrupt ? List.filled(part.length, 0) : part,
    );
    await put(
      '${prefix}commit.json',
      snapshotJson({
        'kind': VelockSnapshotInventory.kind,
        'version': 2,
        'snapshotId': 'snapshot',
        'vaultId': 'vault',
        'manifestSha256': sha256.convert(manifest).toString(),
      }),
    );
  }

  Future<VelockSyncProfile> current() async =>
      VelockSyncProfile.fromEnvelope((await profiles.read('p'))!);
  Future<bool> prepare() async => service.prepare(
    expected: (await profiles.read('p'))!,
    locationLabel: 'NAS /new',
  );
  Future<VelockSyncProfile> reconcile() async =>
      VelockSnapshotRecoveryService.reconcile(
        database: db,
        profiles: profiles,
        profile: await current(),
        adapter: adapter,
      );
  Future<void> applied({
    KeyPair? signer,
    String? hash,
    String consumer = 'consumer',
  }) async {
    final body = {
      'kind': 'velock-current-state-snapshot-applied',
      'version': 2,
      'snapshotId': 'snapshot',
      'vaultId': 'vault',
      'producerId': 'source',
      'consumerId': consumer,
      'manifestSha256': hash ?? sha256.convert(manifest).toString(),
      'recordCount': 2,
      'completedAt': now.toIso8601String(),
    };
    final sig = await Ed25519().sign([
      ...utf8.encode('VelockCurrentStateSnapshotApplied/2\n'),
      ...snapshotJson(body),
    ], keyPair: signer ?? ownerKey);
    await SnapshotControlFiles(exchange).publish(
      'SnapshotApplied',
      'snapshot',
      snapshotJson({...body, 'signature': base64UrlEncode(sig.bytes)}),
    );
  }

  setUp(() async {
    now = DateTime.utc(2026, 9, 27);
    root = await Directory.systemTemp.createTemp('snapshot-recovery-');
    exchange = await Directory('${root.path}/exchange').create();
    db = await SyncStateDatabase.inMemory();
    profiles = SyncProfileRepository(db);
    await profiles.save(profile.toEnvelope());
    sourceKey = await Ed25519().newKeyPair();
    ownerKey = await Ed25519().newKeyPair();
    await db.trustDevice(
      vaultId: 'vault',
      deviceId: 'consumer',
      signingPublicKey: Uint8List.fromList(
        (await ownerKey.extractPublicKey()).bytes,
      ),
    );
    adapter = VelockExchangeDatasetAdapter(
      datasetId: 'dataset',
      vaultId: 'vault',
      producerDeviceId: 'consumer',
      displayName: 'Backup',
      exchange: VelockExchangeStore(exchange),
    );
    factory = _Factory(adapter);
    remote = InMemoryObjectStore();
    launches = [];
    var serial = 0;
    service = VelockSnapshotRecoveryService(
      database: db,
      profiles: profiles,
      adapterFactory: factory,
      openRemote: (id, segments) async {
        expect(id, 'nas');
        expect(segments, ['new']);
        return remote;
      },
      launchVelock: (uri) async {
        launches.add(uri);
        return true;
      },
      now: () => now,
      nextId: () => 'request-${++serial}',
    );
    await trust();
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  test(
    'discovery and download do not advance cursors; only bound owner receipt does',
    () async {
      await snapshot();
      expect(await prepare(), true);
      final pending = await current();
      expect(pending.snapshotDiscoveryPending, false);
      expect(pending.snapshotRestoreRequestId, isNotNull);
      expect(
        await db.appliedSequence(profileId: 'p', producerDeviceId: 'source'),
        0,
      );
      await expectLater(
        reconcile(),
        throwsA(isA<VelockSnapshotApplicationRequired>()),
      );
      expect(
        await db.appliedSequence(profileId: 'p', producerDeviceId: 'source'),
        0,
      );
      expect(launches, isEmpty);
      await service.open('p');
      expect(launches.single.host, 'sync-snapshot');
      await applied();
      final ready = await reconcile();
      expect(ready.snapshotRestoreRequestId, isNull);
      expect(ready.currentSnapshotId, 'snapshot');
      expect(
        await db.appliedSequence(profileId: 'p', producerDeviceId: 'source'),
        7,
      );
      expect(
        (await reconcile()).toEnvelope().toJson(),
        ready.toEnvelope().toJson(),
      );
    },
  );
  test(
    'local receipt schedules continuation without accepting unverified data',
    () async {
      expect(await service.hasAppliedReceipt('p'), isFalse);
      await snapshot();
      await prepare();
      expect(await service.hasAppliedReceipt('p'), isFalse);
      await applied(signer: sourceKey);
      expect(await service.hasAppliedReceipt('p'), isTrue);
      await expectLater(reconcile(), throwsFormatException);
      expect((await current()).snapshotRestoreRequestId, isNotNull);
    },
  );

  test('expired request refresh preserves exact downloaded snapshot', () async {
    await snapshot();
    await prepare();
    final old = await current();
    final cached = await File(
      '${exchange.path}/Snapshots/Incoming/snapshot/manifest.json',
    ).readAsBytes();
    now = now.add(const Duration(minutes: 6));
    await service.open('p');
    final updated = await current();
    expect(
      updated.snapshotRestoreRequestId,
      isNot(old.snapshotRestoreRequestId),
    );
    expect(updated.currentSnapshotId, old.currentSnapshotId);
    expect(
      await File(
        '${exchange.path}/Snapshots/Incoming/snapshot/manifest.json',
      ).readAsBytes(),
      cached,
    );
    final req = SnapshotControlRequest.parse(
      (await SnapshotControlFiles(
        exchange,
      ).read('SnapshotRequests', updated.snapshotRestoreRequestId!))!,
    );
    req.assertFresh(now);
    expect(req.destinationHash, isNotEmpty);
  });
  test('interrupted corrupt download keeps restore intent for retry', () async {
    await snapshot(corrupt: true);
    await expectLater(prepare(), throwsA(isA<FormatException>()));
    expect((await current()).snapshotDiscoveryPending, true);
    expect((await current()).currentSnapshotId, isNull);
    await snapshot();
    expect(await prepare(), true);
  });
  test(
    'legacy folder clears discovery without requiring Apple snapshot adapter',
    () async {
      factory.adapter = _Legacy();
      expect(await prepare(), false);
      expect((await current()).snapshotDiscoveryPending, false);
      expect((await current()).currentSnapshotId, isNull);
    },
  );
  for (final attack in ['signer', 'binding', 'revoked-source']) {
    test(
      'local trust rejects $attack without remote-based key fallback',
      () async {
        await snapshot();
        await trust(
          signer: attack == 'signer' ? sourceKey : null,
          binding: attack == 'binding' ? 'b' * 43 : null,
          includeSource: attack != 'revoked-source',
        );
        await expectLater(
          prepare(),
          throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
        );
        expect((await current()).snapshotDiscoveryPending, true);
      },
    );
  }
  for (final attack in ['signer', 'hash', 'consumer']) {
    test('application proof rejects $attack and leaves cursor zero', () async {
      await snapshot();
      await prepare();
      await applied(
        signer: attack == 'signer' ? sourceKey : null,
        hash: attack == 'hash' ? '0' * 64 : null,
        consumer: attack == 'consumer' ? 'another' : 'consumer',
      );
      await expectLater(reconcile(), throwsFormatException);
      expect(
        await db.appliedSequence(profileId: 'p', producerDeviceId: 'source'),
        0,
      );
      expect((await current()).snapshotRestoreRequestId, isNotNull);
    });
  }
  test('revocation after download rejects application proof', () async {
    await snapshot();
    await prepare();
    await applied();
    await trust(includeSource: false);
    await expectLater(reconcile(), throwsStateError);
    expect(
      await db.appliedSequence(profileId: 'p', producerDeviceId: 'source'),
      0,
    );
  });
  test(
    'stale compare-and-swap cannot replace edits or resurrect removed profile',
    () async {
      final original = profile.toEnvelope();
      final updated = profile
          .copyWith(remoteRootSegments: ['elsewhere'])
          .toEnvelope();
      await profiles.save(updated);
      await expectLater(
        profiles.saveIfUnchanged(expected: original, updated: original),
        throwsStateError,
      );
      expect((await profiles.read('p'))!.toJson(), updated.toJson());
      await profiles.setState('p', SyncProfileState.accessRequired);
      await expectLater(
        profiles.saveIfUnchanged(expected: updated, updated: original),
        throwsStateError,
      );
      expect(
        (await profiles.read('p'))!.state,
        SyncProfileState.accessRequired,
      );
    },
  );
}

class _Factory implements VelockDatasetAdapterFactory {
  _Factory(this.adapter);
  SyncDatasetAdapter adapter;
  @override
  Future<SyncDatasetAdapter> create(VelockSyncProfile profile) async => adapter;
}

class _Legacy implements SyncDatasetAdapter {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
