import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/model/sync_acknowledgement.dart';

class RemoteAcknowledgementReader {
  const RemoteAcknowledgementReader();

  Future<Map<String, Map<String, int>>> read({
    required String vaultId,
    required RemoteObjectStore remote,
    required Map<String, PublicKey> trustedDeviceKeys,
  }) async {
    final prefix = '${LogicalKeys.vaultPrefix(vaultId)}acknowledgements/';
    final acknowledgements = <String, Map<String, int>>{};
    String? cursor;
    do {
      final page = await remote.list(prefix: prefix, cursor: cursor);
      for (final item in page.items) {
        if (!item.logicalKey.endsWith('.ack')) continue;
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
          continue;
        }
        final valid = await Ed25519().verify(
          Uint8List.fromList(utf8.encode(ack.signatureCanonicalJson())),
          signature: Signature(_base64(ack.signature), publicKey: key),
        );
        if (!valid) {
          throw const FormatException('Acknowledgement signature is invalid.');
        }
        final byProducer = acknowledgements.putIfAbsent(
          ack.consumerDeviceId,
          () => <String, int>{},
        );
        final current = byProducer[ack.producerDeviceId] ?? 0;
        if (ack.appliedThroughSequence > current) {
          byProducer[ack.producerDeviceId] = ack.appliedThroughSequence;
        }
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    return acknowledgements;
  }

  List<int> _base64(String value) {
    try {
      return base64Url.decode(value.padRight((value.length + 3) ~/ 4 * 4, '='));
    } on FormatException {
      throw const FormatException('Acknowledgement signature is invalid.');
    }
  }
}
