import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control_files.dart';

void main() {
  final now = DateTime.utc(2026, 9, 27);
  SnapshotControlRequest request({
    String challenge = 'challenge',
    String location = 'New backup',
    String? hash,
  }) => SnapshotControlRequest(
    requestId: 'request',
    challenge: challenge,
    operation: 'build',
    snapshotId: 'snapshot',
    vaultId: 'vault',
    producerId: 'source',
    actorDeviceId: 'source',
    actorPublicKeyId: 'key',
    exchangeBindingId: '_' * 43,
    syncAppInstanceId: 'sync',
    destinationLabel: location,
    destinationHash: hash ?? 'a' * 64,
    createdAt: now,
    expiresAt: now.add(const Duration(minutes: 5)),
  );
  test('canonical request roundtrip and exact approval boundary', () {
    final r = request();
    final parsed = SnapshotControlRequest.parse(r.encode());
    expect(parsed.digest, r.digest);
    expect(parsed.destinationLabel, 'New backup');
    parsed.assertFresh(now);
    expect(
      () => parsed.assertFresh(now.subtract(const Duration(microseconds: 1))),
      throwsStateError,
    );
    expect(() => parsed.assertFresh(r.expiresAt), throwsStateError);
  });
  test(
    'completion can finish after request expiry but approval cannot',
    () async {
      final key = await Ed25519().newKeyPair();
      final r = request();
      final receipt = await SnapshotControlReceipt.sign(
        request: r,
        manifestHash: 'b' * 64,
        approvedAt: now.add(const Duration(minutes: 4)),
        completedAt: now.add(const Duration(hours: 1)),
        signingKey: key,
      );
      final parsed = await SnapshotControlReceipt.verify(
        bytes: receipt.encode(),
        request: r,
        trustedActorKey: await key.extractPublicKey(),
      );
      expect(parsed.manifestHash, 'b' * 64);
      await expectLater(
        SnapshotControlReceipt.sign(
          request: r,
          manifestHash: 'b' * 64,
          approvedAt: r.expiresAt,
          completedAt: r.expiresAt,
          signingKey: key,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'receipt rejects different challenge, location, scope, key and tampering',
    () async {
      final key = await Ed25519().newKeyPair();
      final other = await Ed25519().newKeyPair();
      final r = request();
      final receipt = await SnapshotControlReceipt.sign(
        request: r,
        manifestHash: 'b' * 64,
        approvedAt: now,
        completedAt: now,
        signingKey: key,
      );
      for (final changed in [
        request(challenge: 'new'),
        request(location: 'Other'),
        request(hash: 'c' * 64),
      ]) {
        await expectLater(
          SnapshotControlReceipt.verify(
            bytes: receipt.encode(),
            request: changed,
            trustedActorKey: await key.extractPublicKey(),
          ),
          throwsFormatException,
        );
      }
      await expectLater(
        SnapshotControlReceipt.verify(
          bytes: receipt.encode(),
          request: r,
          trustedActorKey: await other.extractPublicKey(),
        ),
        throwsFormatException,
      );
      final changed = utf8.encode(
        utf8.decode(receipt.encode()).replaceFirst('b' * 64, 'd' * 64),
      );
      await expectLater(
        SnapshotControlReceipt.verify(
          bytes: changed,
          request: r,
          trustedActorKey: await key.extractPublicKey(),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'rejects oversized noncanonical unknown fields and malformed identifiers',
    () {
      final r = request();
      expect(
        () => SnapshotControlRequest.parse([32, ...r.encode()]),
        throwsFormatException,
      );
      expect(
        () => SnapshotControlRequest.parse(List.filled(16385, 32)),
        throwsFormatException,
      );
      final m = r.toJson();
      for (final change in [
        <String, Object>{'unexpected': 'value'},
        {'operation': 'reset'},
        {'snapshotId': '../escape'},
        {'expiresAt': now.add(const Duration(hours: 1)).toIso8601String()},
        {'destinationLabel': '\nMisleading'},
      ]) {
        final edited = {...m, ...change};
        final keys = edited.keys.toList()..sort();
        expect(
          () => SnapshotControlRequest.parse(
            utf8.encode(jsonEncode({for (final k in keys) k: edited[k]})),
          ),
          throwsFormatException,
        );
      }
    },
  );
  late Directory root;
  late SnapshotControlFiles files;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('snapshot-control-');
    files = SnapshotControlFiles(root);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test('control artifact is immutable, bounded and resumable', () async {
    expect(await files.read('SnapshotRequests', 'id'), isNull);
    await files.publish('SnapshotRequests', 'id', request().encode());
    await files.publish('SnapshotRequests', 'id', request().encode());
    expect(await files.read('SnapshotRequests', 'id'), request().encode());
    await expectLater(
      files.publish(
        'SnapshotRequests',
        'id',
        request(challenge: 'different').encode(),
      ),
      throwsStateError,
    );
    await expectLater(
      files.publish('SnapshotRequests', '../escape', [1]),
      throwsFormatException,
    );
    await expectLater(
      files.publish('Arbitrary', 'id', [1]),
      throwsArgumentError,
    );
    await expectLater(
      files.publish('SnapshotRequests', 'large', List.filled(16385, 1)),
      throwsFormatException,
    );
  });
  test('concurrent publication cannot replace different winner', () async {
    final results = await Future.wait(
      [1, 2].map((n) async {
        try {
          await files.publish('SnapshotRequests', 'race', [n]);
          return true;
        } catch (_) {
          return false;
        }
      }),
    );
    expect(results.where((r) => r).length, 1);
    final stored = await files.read('SnapshotRequests', 'race');
    expect(stored!.single, anyOf(1, 2));
  });
  test('rejects symbolic links at collection, request and file', () async {
    final outside = await Directory.systemTemp.createTemp('snapshot-outside-');
    addTearDown(() => outside.delete(recursive: true));
    await Directory('${root.path}/Control').create();
    await Link('${root.path}/Control/SnapshotRequests').create(outside.path);
    await expectLater(
      files.read('SnapshotRequests', 'id'),
      throwsFormatException,
    );
    await Link('${root.path}/Control/SnapshotRequests').delete();
    await Directory('${root.path}/Control/SnapshotRequests').create();
    await Link('${root.path}/Control/SnapshotRequests/id').create(outside.path);
    await expectLater(
      files.read('SnapshotRequests', 'id'),
      throwsFormatException,
    );
    await Link('${root.path}/Control/SnapshotRequests/id').delete();
    await Directory('${root.path}/Control/SnapshotRequests/id').create();
    await File('${outside.path}/data').writeAsString('{}');
    await Link(
      '${root.path}/Control/SnapshotRequests/id/artifact.json',
    ).create('${outside.path}/data');
    await expectLater(
      files.read('SnapshotRequests', 'id'),
      throwsFormatException,
    );
  });
}
