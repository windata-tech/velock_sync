import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/remote_acknowledgement_reader.dart';
import 'package:velock_sync/sync_core/model/sync_acknowledgement.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  test('reads the highest verified acknowledgement per producer', () async {
    final consumer = await Ed25519().newKeyPair();
    final payload = <String, Object?>{
      'appliedThroughSequence': 7,
      'consumerDeviceId': 'consumer-1',
      'createdAt': DateTime.utc(2026, 9, 10).toIso8601String(),
      'producerDeviceId': 'producer-1',
      'protocolVersion': 1,
      'signatureAlgorithm': 'Ed25519',
      'vaultId': 'vault-1',
    };
    final signature = await Ed25519().sign(
      utf8.encode(jsonEncode(payload)),
      keyPair: consumer,
    );
    final ack = SyncAcknowledgement(
      vaultId: 'vault-1',
      consumerDeviceId: 'consumer-1',
      producerDeviceId: 'producer-1',
      appliedThroughSequence: 7,
      createdAt: DateTime.utc(2026, 9, 10),
      signature: base64UrlEncode(signature.bytes).replaceAll('=', ''),
    );
    final remote = InMemoryObjectStore();
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({...ack.signaturePayload(), 'signature': ack.signature}),
      ),
    );
    await remote.put(
      LogicalKeys.acknowledgement('vault-1', 'consumer-1', 'producer-1', 7),
      Stream.value(bytes),
      contentLength: bytes.length,
      ifAbsent: true,
    );

    final result = await const RemoteAcknowledgementReader().read(
      vaultId: 'vault-1',
      remote: remote,
      trustedDeviceKeys: {'consumer-1': await consumer.extractPublicKey()},
    );

    expect(result['consumer-1']?['producer-1'], 7);

    // WebDAV lists one level (Depth: 1): the ACK sits two folders below the
    // collection and was never reached before.
    final oneLevel = await const RemoteAcknowledgementReader().read(
      vaultId: 'vault-1',
      remote: _OneLevelStore(remote),
      trustedDeviceKeys: {'consumer-1': await consumer.extractPublicKey()},
    );
    expect(oneLevel['consumer-1']?['producer-1'], 7);
  });

  test(
    'reads a vault whose acknowledgements collection was never created',
    () async {
      // WebDAV answers 404 for a collection that was never created. Before the
      // first acknowledgement is published that is a normal empty state: no
      // consumer has acknowledged anything, which can only block a deletion.
      final remote = InMemoryObjectStore(
        answerNotFoundForMissingCollections: true,
      );

      final result = await const RemoteAcknowledgementReader().read(
        vaultId: 'vault-1',
        remote: remote,
        trustedDeviceKeys: {'consumer-1': await Ed25519().newKeyPair()
            .then((pair) => pair.extractPublicKey())},
      );

      expect(result, isEmpty);
    },
  );
}

/// Lists like WebDAV `PROPFIND Depth: 1`: direct children only, with
/// sub-folders reported as directories.
class _OneLevelStore extends InMemoryObjectStore {
  _OneLevelStore(this._inner);

  final InMemoryObjectStore _inner;

  @override
  Future<RemoteObjectPage> list({
    String prefix = '',
    String? cursor,
    int limit = 100,
    RemoteOperationCancellation? cancellation,
  }) async {
    final all = <RemoteObjectMetadata>[];
    String? next;
    do {
      final page = await _inner.list(prefix: prefix, cursor: next);
      all.addAll(page.items);
      next = page.nextCursor;
    } while (next != null);
    final children = <String, RemoteObjectMetadata>{};
    for (final item in all) {
      final rest = item.logicalKey.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        children[item.logicalKey] = item;
      } else {
        final folder = '$prefix${rest.substring(0, slash)}';
        children[folder] = RemoteObjectMetadata(
          logicalKey: folder,
          size: 0,
          updatedAt: DateTime.utc(2026),
          isDirectory: true,
        );
      }
    }
    return RemoteObjectPage(items: children.values.toList());
  }

  @override
  Stream<List<int>> read(
    String logicalKey, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  }) => _inner.read(logicalKey, cancellation: cancellation);
}
