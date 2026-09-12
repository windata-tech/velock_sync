import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/engine/join_request_transport.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

Uint8List _request(String deviceId, {String? vaultId}) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'version': 1,
        'vaultId': vaultId ?? 'vault-1',
        'deviceId': deviceId,
        'deviceDisplayName': '新 iPhone',
        'signingPublicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        'requestedAt': '2026-09-11T00:00:00.000Z',
        'signatureAlgorithm': 'Ed25519',
        'signature': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      }),
    ),
  );
}

void main() {
  const deviceId = 'a202a0b1-f5f1-4b15-9e61-f932ab019e02';

  test('uploads local join requests and downloads remote ones', () async {
    final root = await Directory.systemTemp.createTemp('velock-join-transport-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final transport = JoinRequestTransport(root);
    await transport.localRequests.create(recursive: true);
    await File('${transport.localRequests.path}/$deviceId.json')
        .writeAsBytes(_request(deviceId));

    final remote = InMemoryObjectStore();
    expect(await transport.uploadLocal(vaultId: 'vault-1', remote: remote), 1);
    final stored = await remote.read(
      'velock-sync/v1/vault-1/join-requests/$deviceId.json',
    ).expand((chunk) => chunk).toList();
    expect(stored, isNotEmpty);

    // A remote request published by a peer lands in the local control folder.
    final peerId = '6b71c91c-1604-45dc-91c4-fe54ae27d432';
    final peerBytes = _request(peerId);
    await remote.put(
      'velock-sync/v1/vault-1/join-requests/$peerId.json',
      Stream.value(peerBytes),
      contentLength: peerBytes.length,
    );
    // The remote also holds the request this device just uploaded, so both
    // artifacts are copied back into the local control folder.
    expect(await transport.downloadRemote(vaultId: 'vault-1', remote: remote), 2);
    final local = File('${transport.localRequests.path}/$peerId.json');
    expect(local.existsSync(), isTrue);
    expect(await local.readAsBytes(), peerBytes);
  });

  test('ignores malformed remote artifacts and non-canonical ids', () async {
    final root = await Directory.systemTemp.createTemp('velock-join-transport-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final transport = JoinRequestTransport(root);
    final remote = InMemoryObjectStore();

    final mismatched = _request(deviceId, vaultId: 'vault-1');
    final mismatchedBytes = Uint8List.fromList(utf8.encode('{"deviceId":"other"}'));
    await remote.put(
      'velock-sync/v1/vault-1/join-requests/$deviceId.json',
      Stream.value(mismatchedBytes),
      contentLength: mismatchedBytes.length,
    );
    expect(await transport.downloadRemote(vaultId: 'vault-1', remote: remote), 0);
    expect(transport.localRequests.existsSync(), isFalse);

    await remote.put(
      'velock-sync/v1/vault-1/join-requests/not-a-uuid.json',
      Stream.value(mismatched),
      contentLength: mismatched.length,
    );
    expect(await transport.downloadRemote(vaultId: 'vault-1', remote: remote), 0);
  });
}
