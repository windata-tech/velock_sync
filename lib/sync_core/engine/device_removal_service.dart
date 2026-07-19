import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/crypto/device_membership.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';

/// Performs the reversible-record-first half of device removal. Callers must
/// obtain explicit user confirmation before invoking it and rotate Vault keys
/// separately when future confidentiality from the removed device is needed.
class DeviceRemovalService {
  DeviceRemovalService(
    this._database, {
    DeviceMembershipSigner? membershipSigner,
  }) : _membershipSigner = membershipSigner ?? DeviceMembershipSigner();

  final SyncStateDatabase _database;
  final DeviceMembershipSigner _membershipSigner;

  Future<void> revoke({
    required String vaultId,
    required String deviceId,
    required String issuerDeviceId,
    required KeyPair issuerSigningKey,
    required RemoteObjectStore remote,
    required bool userConfirmed,
    required DateTime now,
  }) async {
    if (!userConfirmed) {
      throw StateError('Device removal requires explicit user confirmation.');
    }
    if (vaultId.isEmpty || deviceId.isEmpty || issuerDeviceId.isEmpty) {
      throw ArgumentError('Device identity is required.');
    }
    if (deviceId == issuerDeviceId) {
      throw ArgumentError.value(deviceId, 'deviceId', 'cannot revoke issuer');
    }
    final trusted = await _database.readTrustedDevicePublicKeys(
      vaultId: vaultId,
    );
    final removedKey = trusted[deviceId];
    if (removedKey == null) {
      throw StateError('Device is not locally trusted.');
    }
    final artifact = await _membershipSigner.sign(
      draft: DeviceMembershipDraft(
        vaultId: vaultId,
        deviceId: deviceId,
        signingPublicKey: Uint8List.fromList(removedKey),
        status: DeviceMembershipStatus.revoked,
        issuedAt: now.toUtc(),
        issuedByDeviceId: issuerDeviceId,
      ),
      issuerSigningKey: issuerSigningKey,
    );
    await remote.put(
      LogicalKeys.member(vaultId, deviceId),
      Stream.value(artifact),
      contentLength: artifact.length,
    );
    await _database.revokeTrustedDevice(vaultId: vaultId, deviceId: deviceId);
  }
}
