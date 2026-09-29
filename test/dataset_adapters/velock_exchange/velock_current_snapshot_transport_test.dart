import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_verification_record.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_baseline.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_remote_history_guard.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_current_snapshot_transport.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  late Directory root;
  late Directory source;
  late KeyPair key;
  late Uint8List manifest, commit;
  late VelockSnapshotInventory inventory;
  late _Remote remote;
  PublicKey? inventoryKey;
  const transport = VelockCurrentSnapshotTransport();
  final part = utf8.encode('opaque-part');
  final blob = List<int>.generate(180000, (i) => i % 251);

  Future<VelockSnapshotInventory> verify({
    PublicKey? publicKey,
    int? budget,
  }) async => VelockSnapshotInventory.verify(
    manifest: manifest,
    commit: commit,
    snapshotId: 'snapshot-1',
    vaultId: 'vault-1',
    producerId: 'producer-1',
    keyId: 'key-1',
    trustedSigningKey: publicKey ?? await key.extractPublicKey(),
    maxTotalBytes: budget ?? 1000000,
  );
  Future<void> sign(Map<String, dynamic> payload) async {
    final sig = await Ed25519().sign([
      ...utf8.encode('VelockCurrentStateSnapshot/2\n'),
      ...snapshotJson(payload),
    ], keyPair: key);
    manifest = snapshotJson({
      ...payload,
      'signature': base64UrlEncode(sig.bytes),
    });
    commit = snapshotJson({
      'kind': VelockSnapshotInventory.kind,
      'version': 2,
      'snapshotId': 'snapshot-1',
      'vaultId': 'vault-1',
      'manifestSha256': sha256.convert(manifest).toString(),
    });
  }

  Future<void> upload() =>
      transport.upload(source: source, inventory: inventory, remote: remote);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('snapshot-transport-');
    source = await Directory('${root.path}/source').create();
    key = await Ed25519().newKeyPairFromSeed(List<int>.filled(32, 17));
    await sign({
      'kind': VelockSnapshotInventory.kind,
      'version': 2,
      'snapshotId': 'snapshot-1',
      'vaultId': 'vault-1',
      'producerId': 'producer-1',
      'keyId': 'key-1',
      'createdAt': '2026-09-27T00:00:00.000Z',
      'recordCount': 2,
      'heads': {
        'producer-1': {'sequence': 7, 'batchId': 'old-batch-7'},
      },
      'parts': [
        {
          'number': 1,
          'size': part.length,
          'sha256': sha256.convert(part).toString(),
          'records': 2,
        },
      ],
      'blobs': [
        {
          'id': 'attachment-1',
          'size': blob.length,
          'sha256': sha256.convert(blob).toString(),
          'chunkSize': 0,
          'protection': 'source-opaque',
        },
      ],
    });
    inventory = await verify();
    for (final e in {
      'manifest.json': manifest,
      'commit.json': commit,
      'part-1.enc': part,
      'blob-attachment-1': blob,
    }.entries) {
      await File('${source.path}/${e.key}').writeAsBytes(e.value);
    }
    remote = _Remote();
  });
  tearDown(() async => root.delete(recursive: true));

  Future<VerifiedVelockSnapshotBaseline> baseline({PublicKey? trusted}) =>
      VerifiedVelockSnapshotBaseline.verify(
        remote: remote,
        snapshotId: 'snapshot-1',
        vaultId: 'vault-1',
        producerId: 'producer-1',
        keyId: 'key-1',
        trustedSigningKey: trusted ?? inventoryKey!,
      );
  Future<void> history(
    VerifiedVelockSnapshotBaseline? proof,
    int through, {
    String producer = 'producer-1',
    RemoteObjectStore? scope,
  }) => verifyVelockRemoteHistory(
    remote: scope ?? remote,
    vaultId: 'vault-1',
    producerDeviceId: producer,
    requiredThroughSequence: through,
    baseline: proof,
  );
  Future<void> putCommit(int sequence, {String? batch}) async {
    final bytes = utf8.encode(
      'guard checks names only; importer checks signatures',
    );
    await remote.put(
      LogicalKeys.commit(
        'vault-1',
        'producer-1',
        sequence,
        batch ?? 'batch-$sequence',
      ),
      Stream.value(bytes),
      contentLength: bytes.length,
    );
  }

  test(
    'complete trusted snapshot covers only its heads; later gaps and forks still block',
    () async {
      inventoryKey = await key.extractPublicKey();
      await upload();
      await expectLater(history(null, 7), throwsA(isA<SyncFailureException>()));
      final proof = await baseline();
      await history(proof, 7);
      await expectLater(
        history(proof, 8),
        throwsA(isA<SyncFailureException>()),
      );
      await putCommit(8);
      await putCommit(9);
      await history(proof, 9);
      await putCommit(9, batch: 'fork');
      await expectLater(
        history(proof, 9),
        throwsA(isA<SyncFailureException>()),
      );
      await expectLater(
        history(proof, 1, producer: 'other'),
        throwsA(isA<SyncFailureException>()),
      );
      await expectLater(history(proof, 7, scope: _Remote()), throwsStateError);
    },
  );
  test(
    'missing blob or forged trusted key cannot produce baseline proof',
    () async {
      inventoryKey = await key.extractPublicKey();
      await upload();
      final attacker = await Ed25519().newKeyPair();
      await expectLater(
        baseline(trusted: await attacker.extractPublicKey()),
        throwsFormatException,
      );
      await remote.delete('${inventory.remotePrefix}blob-attachment-1');
      await expectLater(
        baseline(),
        throwsA(isA<RemoteObjectNotFoundException>()),
      );
    },
  );

  test(
    'commit last, exact-byte retry and complete download survive reopening',
    () async {
      await upload();
      expect(remote.puts.last, '${inventory.remotePrefix}commit.json');
      expect(remote.puts, hasLength(4));
      await upload();
      expect(remote.puts, hasLength(4));
      final target = await transport.download(
        destinationRoot: Directory('${root.path}/incoming'),
        inventory: inventory,
        remote: remote,
      );
      expect(
        await File('${target.path}/blob-attachment-1').readAsBytes(),
        blob,
      );
      expect(
        await File('${target.path}/manifest.json').readAsBytes(),
        manifest,
      );
      await transport.verifyRemote(inventory: inventory, remote: remote);
      final reopened = await transport.download(
        destinationRoot: target.parent,
        inventory: inventory,
        remote: remote,
      );
      expect(reopened.path, target.path);
    },
  );

  test(
    'interruption cannot publish commit; retry uses already uploaded bytes',
    () async {
      remote.failPutAt = 2;
      await expectLater(upload(), throwsStateError);
      expect(await remote.stat('${inventory.remotePrefix}commit.json'), isNull);
      remote.failPutAt = null;
      await upload();
      expect(
        remote.puts.where((key) => key.endsWith('part-1.enc')),
        hasLength(1),
      );
      await transport.verifyRemote(inventory: inventory, remote: remote);
    },
  );

  test('existing corrupt object cannot be overwritten or accepted', () async {
    final badKey = '${inventory.remotePrefix}blob-attachment-1';
    await remote.put(
      badKey,
      Stream.value(List<int>.filled(blob.length, 0)),
      contentLength: blob.length,
    );
    await expectLater(upload(), throwsFormatException);
    expect(await remote.stat('${inventory.remotePrefix}commit.json'), isNull);
    expect(await remote.read(badKey).expand((c) => c).first, 0);
  });

  test(
    'missing remote blob rejects verification and leaves no usable download',
    () async {
      await upload();
      await remote.delete('${inventory.remotePrefix}blob-attachment-1');
      await expectLater(
        transport.verifyRemote(inventory: inventory, remote: remote),
        throwsA(isA<RemoteObjectNotFoundException>()),
      );
      final incoming = Directory('${root.path}/incoming');
      await expectLater(
        transport.download(
          destinationRoot: incoming,
          inventory: inventory,
          remote: remote,
        ),
        throwsA(isA<RemoteObjectNotFoundException>()),
      );
      expect(await Directory('${incoming.path}/snapshot-1').exists(), isFalse);
      expect(await incoming.list().toList(), isEmpty);
    },
  );

  test('same-length local ciphertext mutation fails before commit', () async {
    await File(
      '${source.path}/blob-attachment-1',
    ).writeAsBytes(List<int>.filled(blob.length, 2));
    await expectLater(upload(), throwsFormatException);
    expect(await remote.stat('${inventory.remotePrefix}commit.json'), isNull);
  });

  test('local file symlink is refused', () async {
    final file = File('${source.path}/blob-attachment-1');
    await file.delete();
    final outside = await File('${root.path}/outside').writeAsBytes(blob);
    await Link(file.path).create(outside.path);
    await expectLater(upload(), throwsFormatException);
    expect(await remote.stat('${inventory.remotePrefix}commit.json'), isNull);
  });

  test(
    'corrupt completed cache is rejected without silent replacement',
    () async {
      await upload();
      final target = await transport.download(
        destinationRoot: Directory('${root.path}/incoming'),
        inventory: inventory,
        remote: remote,
      );
      await File('${target.path}/part-1.enc').writeAsBytes([0]);
      await expectLater(
        transport.download(
          destinationRoot: target.parent,
          inventory: inventory,
          remote: remote,
        ),
        throwsFormatException,
      );
      expect(await File('${target.path}/part-1.enc').readAsBytes(), [0]);
    },
  );

  test(
    'a recently verified snapshot is not downloaded again on every run',
    () async {
      // Every run used to read every part and blob back: gigabytes of photos
      // on each resume, network change and background task.
      await upload();
      inventoryKey = await key.extractPublicKey();
      final record = FileVelockSnapshotVerificationRecord(
        File('${root.path}/record.json'),
      );
      Future<VerifiedVelockSnapshotBaseline> checked(String scope) =>
          VerifiedVelockSnapshotBaseline.verify(
            remote: remote,
            snapshotId: 'snapshot-1',
            vaultId: 'vault-1',
            producerId: 'producer-1',
            keyId: 'key-1',
            trustedSigningKey: inventoryKey!,
            skipObjectCheck: (inventory) => record.isFresh(scope, inventory),
            onObjectsVerified: (inventory) =>
                record.remember(scope, inventory),
          );
      final prefix = 'vaults/vault-1/current-snapshots/snapshot-1/';

      remote.reads.clear();
      await checked('location-a');
      expect(remote.reads, contains('${prefix}blob-attachment-1'));

      remote.reads.clear();
      final second = await checked('location-a');
      expect(remote.reads, ['${prefix}commit.json', '${prefix}manifest.json']);
      expect(
        second.coveredThrough(
          remote: remote,
          vaultId: 'vault-1',
          producerId: 'producer-1',
        ),
        7,
      );

      remote.reads.clear();
      await checked('location-b');
      expect(
        remote.reads,
        contains('${prefix}blob-attachment-1'),
        reason: 'another backup location is verified in full',
      );

      final expired = FileVelockSnapshotVerificationRecord(
        File('${root.path}/record.json'),
        now: () => DateTime.now().add(const Duration(days: 31)),
      );
      expect(await expired.isFresh('location-a', inventory), isFalse);
    },
  );

  test('cancelled transfer writes no commit', () async {
    final cancel = RemoteOperationCancellation()..cancel();
    await expectLater(
      transport.upload(
        source: source,
        inventory: inventory,
        remote: remote,
        cancellation: cancel,
      ),
      throwsA(isA<RemoteOperationCancelledException>()),
    );
    expect(remote.puts, isEmpty);
  });

  test('untrusted signing key and undersized budget are rejected', () async {
    final other = await Ed25519().newKeyPair();
    await expectLater(
      verify(publicKey: await other.extractPublicKey()),
      throwsFormatException,
    );
    await expectLater(verify(budget: 100), throwsFormatException);
  });

  for (final mutation in [
    'version',
    'path',
    'duplicate',
    'records',
    'head',
    'unknown',
    'timestamp',
  ]) {
    test('rejects signed invalid inventory: $mutation', () async {
      final payload = jsonDecode(utf8.decode(manifest)) as Map<String, dynamic>;
      payload.remove('signature');
      switch (mutation) {
        case 'version':
          payload['version'] = 1;
        case 'path':
          payload['blobs'][0]['id'] = '../outside';
        case 'duplicate':
          payload['blobs'].add(payload['blobs'][0]);
        case 'records':
          payload['recordCount'] = 3;
        case 'head':
          payload['heads']['producer-1']['sequence'] = 0;
        case 'unknown':
          payload['acceptAnyway'] = true;
        case 'timestamp':
          payload['createdAt'] = 'yesterday';
      }
      await sign(payload);
      await expectLater(verify(), throwsFormatException);
    });
  }
  test('ambiguous noncanonical JSON rejected', () async {
    manifest = Uint8List.fromList([...manifest, 32]);
    await expectLater(verify(), throwsFormatException);
  });
}

class _Remote extends InMemoryObjectStore {
  final puts = <String>[];
  final reads = <String>[];
  int? failPutAt;

  @override
  Stream<List<int>> read(
    String logicalKey, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  }) {
    reads.add(logicalKey);
    return super.read(
      logicalKey,
      start: start,
      endInclusive: endInclusive,
      cancellation: cancellation,
    );
  }

  @override
  Future<RemoteObjectMetadata> put(
    String logicalKey,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    if (puts.length + 1 == failPutAt) {
      throw StateError('Injected connection loss');
    }
    final result = await super.put(
      logicalKey,
      content,
      contentLength: contentLength,
      ifAbsent: ifAbsent,
      cancellation: cancellation,
    );
    puts.add(logicalKey);
    return result;
  }
}
