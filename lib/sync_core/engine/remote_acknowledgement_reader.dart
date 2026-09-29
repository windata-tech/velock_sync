import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_acknowledgement.dart';

/// Reads signed acknowledgements published by consumers of one vault.
///
/// A vault whose devices never published an acknowledgement has no
/// `acknowledgements/` collection at all; that reads as "nothing acknowledged"
/// rather than as an error.
class RemoteAcknowledgementReader {
  const RemoteAcknowledgementReader();

  Future<Map<String, Map<String, int>>> read({
    required String vaultId,
    required RemoteObjectStore remote,
    required Map<String, PublicKey> trustedDeviceKeys,
  }) async {
    final root = '${LogicalKeys.vaultPrefix(vaultId)}acknowledgements/';
    final acknowledgements = <String, Map<String, int>>{};
    // ACKs live at acknowledgements/<consumer>/<producer>/<seq>.ack. Some
    // providers list recursively by prefix, but WebDAV answers one level
    // (Depth: 1), which returned only the <consumer> folders, so no ACK was
    // ever read and multi-device cleanup waited for ever. Walk the two folder
    // levels explicitly.
    final pending = <({String prefix, int depth})>[(prefix: root, depth: 0)];
    final seen = <String>{};
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      String? cursor;
      do {
        final RemoteObjectPage page;
        try {
          page = await remote.list(prefix: next.prefix, cursor: cursor);
        } on RemoteObjectNotFoundException {
          // Providers answer 404 for a collection that was never created: no
          // device has published an acknowledgement yet. That is the same GC
          // decision as an empty collection (every consumer has acknowledged
          // nothing), and missing acknowledgements can only block a deletion,
          // never authorize one.
          break;
        }
        for (final item in page.items) {
          if (!item.logicalKey.startsWith(root)) continue;
          if (item.isDirectory) {
            if (next.depth < 2) {
              pending.add((
                prefix: '${item.logicalKey}/',
                depth: next.depth + 1,
              ));
            }
            continue;
          }
          if (!item.logicalKey.endsWith('.ack')) continue;
          if (!seen.add(item.logicalKey)) continue;
          await _readOne(
            item,
            remote: remote,
            vaultId: vaultId,
            trustedDeviceKeys: trustedDeviceKeys,
            into: acknowledgements,
          );
        }
        cursor = page.nextCursor;
      } while (cursor != null);
    }
    return acknowledgements;
  }

  Future<void> _readOne(
    RemoteObjectMetadata item, {
    required RemoteObjectStore remote,
    required String vaultId,
    required Map<String, PublicKey> trustedDeviceKeys,
    required Map<String, Map<String, int>> into,
  }) async {
    final bytes = await remote
        .read(item.logicalKey)
        .expand((chunk) => chunk)
        .toList();
    if (bytes.length != item.size) {
      throw const FormatException(
        'Acknowledgement size does not match remote metadata.',
      );
    }
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Acknowledgement JSON is invalid.');
    }
    final ack = SyncAcknowledgement.fromJson(decoded);
    if (ack.vaultId != vaultId) {
      throw const FormatException('Acknowledgement vault is invalid.');
    }
    final key = trustedDeviceKeys[ack.consumerDeviceId];
    if (key == null) {
      // Revoked or otherwise untrusted devices must not block the
      // authenticated active-device GC decision.
      return;
    }
    final valid = await Ed25519().verify(
      Uint8List.fromList(utf8.encode(ack.signatureCanonicalJson())),
      signature: Signature(_base64(ack.signature), publicKey: key),
    );
    if (!valid) {
      throw const FormatException('Acknowledgement signature is invalid.');
    }
    final byProducer = into.putIfAbsent(
      ack.consumerDeviceId,
      () => <String, int>{},
    );
    final current = byProducer[ack.producerDeviceId] ?? 0;
    if (ack.appliedThroughSequence > current) {
      byProducer[ack.producerDeviceId] = ack.appliedThroughSequence;
    }
  }

  List<int> _base64(String value) {
    try {
      return base64Url.decode(value.padRight((value.length + 3) ~/ 4 * 4, '='));
    } on FormatException {
      throw const FormatException('Acknowledgement signature is invalid.');
    }
  }
}
