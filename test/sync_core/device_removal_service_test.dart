import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/engine/device_removal_service.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  test('publishes a revocation before removing local download trust', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final issuer = await Ed25519().newKeyPair();
    final removed = await Ed25519().newKeyPair();
    final removedPublic = await removed.extractPublicKey();
    await database.trustDevice(
      vaultId: 'vault-1',
      deviceId: 'device-2',
      signingPublicKey: Uint8List.fromList(removedPublic.bytes),
    );
    final remote = InMemoryObjectStore();

    await DeviceRemovalService(database).revoke(
      vaultId: 'vault-1',
      deviceId: 'device-2',
      issuerDeviceId: 'device-1',
      issuerSigningKey: issuer,
      remote: remote,
      userConfirmed: true,
      now: DateTime.utc(2026, 7, 15, 12),
    );

    expect(
      await database.readTrustedDevicePublicKeys(vaultId: 'vault-1'),
      isEmpty,
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in remote.read(
      LogicalKeys.member('vault-1', 'device-2'),
    )) {
      bytes.add(chunk);
    }
    expect(jsonDecode(utf8.decode(bytes.takeBytes()))['status'], 'revoked');
  });

  test('does not change local trust without confirmation', () async {
    final database = await SyncStateDatabase.inMemory();
    addTearDown(database.close);
    final key = await (await Ed25519().newKeyPair()).extractPublicKey();
    await database.trustDevice(
      vaultId: 'vault-1',
      deviceId: 'device-2',
      signingPublicKey: Uint8List.fromList(key.bytes),
    );

    await expectLater(
      DeviceRemovalService(database).revoke(
        vaultId: 'vault-1',
        deviceId: 'device-2',
        issuerDeviceId: 'device-1',
        issuerSigningKey: await Ed25519().newKeyPair(),
        remote: InMemoryObjectStore(),
        userConfirmed: false,
        now: DateTime.utc(2026, 7, 15, 12),
      ),
      throwsStateError,
    );
    expect(
      (await database.readTrustedDevicePublicKeys(vaultId: 'vault-1')).keys,
      contains('device-2'),
    );
  });
}
