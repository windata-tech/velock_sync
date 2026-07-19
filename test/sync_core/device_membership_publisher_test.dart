import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/engine/device_membership_publisher.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  test(
    'trusts and publishes the local active member without overwriting it',
    () async {
      final database = await SyncStateDatabase.inMemory();
      addTearDown(database.close);
      final remote = InMemoryObjectStore();
      final key = await Ed25519().newKeyPair();
      final publisher = DeviceMembershipPublisher(
        database,
        now: () => DateTime.utc(2026, 7, 15),
      );

      await publisher.ensureActive(
        vaultId: 'vault-1',
        deviceId: 'device-1',
        signingKey: key,
        remote: remote,
      );
      final memberKey = LogicalKeys.member('vault-1', 'device-1');
      final first = await _read(remote, memberKey);
      await publisher.ensureActive(
        vaultId: 'vault-1',
        deviceId: 'device-1',
        signingKey: key,
        remote: remote,
      );

      expect(await _read(remote, memberKey), first);
      expect(
        (await database.readTrustedDevicePublicKeys(vaultId: 'vault-1')).keys,
        ['device-1'],
      );
    },
  );
}

Future<Uint8List> _read(InMemoryObjectStore remote, String key) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in remote.read(key)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
