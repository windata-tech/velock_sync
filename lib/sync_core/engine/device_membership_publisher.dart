import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/crypto/device_membership.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';

/// Initializes local trust for the current device and conditionally publishes
/// its signed active member record. Remote member records never grant trust on
/// their own; the local database is updated from this explicit local action.
class DeviceMembershipPublisher {
  DeviceMembershipPublisher(
    this._database, {
    DeviceMembershipSigner? signer,
    DateTime Function()? now,
  }) : _signer = signer ?? DeviceMembershipSigner(),
       _now = now ?? DateTime.now;

  final SyncStateDatabase _database;
  final DeviceMembershipSigner _signer;
  final DateTime Function() _now;

  Future<void> ensureActive({
    required String vaultId,
    required String deviceId,
    required KeyPair signingKey,
    required RemoteObjectStore remote,
  }) async {
    final publicKey = await signingKey.extractPublicKey();
    if (publicKey is! SimplePublicKey || publicKey.bytes.length != 32) {
      throw ArgumentError.value(
        publicKey,
        'signingKey',
        'must contain an Ed25519 public key',
      );
    }
    await _database.trustDevice(
      vaultId: vaultId,
      deviceId: deviceId,
      signingPublicKey: Uint8List.fromList(publicKey.bytes),
    );
    final logicalKey = LogicalKeys.member(vaultId, deviceId);
    if (await remote.stat(logicalKey) != null) return;
    final artifact = await _signer.sign(
      draft: DeviceMembershipDraft(
        vaultId: vaultId,
        deviceId: deviceId,
        signingPublicKey: Uint8List.fromList(publicKey.bytes),
        status: DeviceMembershipStatus.active,
        issuedAt: _now().toUtc(),
        issuedByDeviceId: deviceId,
      ),
      issuerSigningKey: signingKey,
    );
    try {
      await remote.put(
        logicalKey,
        Stream.value(artifact),
        contentLength: artifact.length,
        ifAbsent: true,
      );
    } on RemoteObjectAlreadyExistsException {
      // A concurrent first run published the immutable active member record.
    }
  }
}
