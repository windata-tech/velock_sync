import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

/// Applies user-approved join decisions to a local profile's allow-list.
///
/// Velock signs an approval with the same device key it publishes in the
/// pairing descriptor. Sync verifies that signature and merges the approved
/// producer ids into the profile, so batches from the newly joined device
/// become downloadable. Sync never decides trust on its own.
class JoinApprovalApplier {
  const JoinApprovalApplier({
    required SyncProfileRepository profiles,
    required SyncStateDatabase database,
  }) : _profiles = profiles,
       _database = database;

  final SyncProfileRepository _profiles;
  final SyncStateDatabase _database;

  /// Reads `Control/JoinApprovals/*.json` from the shared exchange folder and
  /// returns the merged trusted producer ids for [profile].
  Future<List<String>> apply({
    required VelockSyncProfile profile,
    required Directory exchangeRoot,
    required String velockSigningPublicKey,
  }) async {
    final directory = Directory('${exchangeRoot.path}/Control/JoinApprovals');
    if (!await directory.exists()) return profile.trustedProducerIds;

    final approved = <String>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final parsed = _parse(await entity.readAsBytes());
        if (parsed == null) continue;
        if (parsed.vaultId != profile.vaultId) continue;
        if (!await parsed.verifyAgainst(velockSigningPublicKey)) continue;
        // The download engine verifies batch signatures with this device key,
        // so trust the approved device locally as well.
        await _database.trustDevice(
          vaultId: profile.vaultId,
          deviceId: parsed.deviceId,
          signingPublicKey: _decodeBase64Url(parsed.signingPublicKey),
        );
        approved.addAll(parsed.trustedProducerIds);
      } on Object {
        continue;
      }
    }
    if (approved.isEmpty) return profile.trustedProducerIds;

    final merged = <String>{
      ...profile.trustedProducerIds,
      ...approved,
    }.toList(growable: false);
    if (merged.length == profile.trustedProducerIds.length) {
      return profile.trustedProducerIds;
    }
    final updated = VelockSyncProfile(
      profileId: profile.profileId,
      datasetId: profile.datasetId,
      vaultId: profile.vaultId,
      deviceId: profile.deviceId,
      displayName: profile.displayName,
      connectionId: profile.connectionId,
      pairedProducerId: profile.pairedProducerId,
      pairedProducerPublicKeyId: profile.pairedProducerPublicKeyId,
      exchangeBindingId: profile.exchangeBindingId,
      trustedProducerIds: merged,
      backgroundPolicy: profile.backgroundPolicy,
      state: profile.state,
      createdAt: profile.createdAt,
    );
    await _profiles.save(updated.toEnvelope());
    return updated.trustedProducerIds;
  }

  _JoinApproval? _parse(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['version'] != 1 ||
          decoded['signatureAlgorithm'] != 'Ed25519') {
        return null;
      }
      final trusted = decoded['trustedProducerIds'];
      if (trusted is! List) return null;
      final ids = trusted.whereType<String>().toList(growable: false);
      if (ids.isEmpty) return null;
      return _JoinApproval(
        vaultId: decoded['vaultId']! as String,
        deviceId: decoded['deviceId']! as String,
        signingPublicKey: decoded['signingPublicKey']! as String,
        approvedBy: decoded['approvedBy']! as String,
        trustedProducerIds: ids,
        approvedAt: DateTime.parse(decoded['approvedAt']! as String).toUtc(),
        signature: decoded['signature']! as String,
      );
    } on Object {
      return null;
    }
  }
}

class _JoinApproval {
  const _JoinApproval({
    required this.vaultId,
    required this.deviceId,
    required this.signingPublicKey,
    required this.approvedBy,
    required this.trustedProducerIds,
    required this.approvedAt,
    required this.signature,
  });

  final String vaultId;
  final String deviceId;
  final String signingPublicKey;
  final String approvedBy;
  final List<String> trustedProducerIds;
  final DateTime approvedAt;
  final String signature;

  Map<String, Object?> unsignedJson() => {
    'version': 1,
    'vaultId': vaultId,
    'deviceId': deviceId,
    'signingPublicKey': signingPublicKey,
    'approvedBy': approvedBy,
    'trustedProducerIds': trustedProducerIds,
    'approvedAt': approvedAt.toUtc().toIso8601String(),
    'signatureAlgorithm': 'Ed25519',
  };

  Future<bool> verifyAgainst(String approvingPublicKey) async {
    try {
      final keyBytes = _decodeBase64Url(approvingPublicKey);
      final signatureBytes = _decodeBase64Url(signature);
      if (keyBytes.length != 32 || signatureBytes.length != 64) return false;
      final payload = Uint8List.fromList(
        utf8.encode(jsonEncode(_sortedJson(unsignedJson()))),
      );
      return await Ed25519().verify(
        payload,
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      return false;
    }
  }



  static Map<String, Object?> _sortedJson(Map<String, Object?> value) => {
    for (final key in value.keys.toList()..sort()) key: value[key],
  };
}

Uint8List _decodeBase64Url(String value) {
  final padded = value.padRight((value.length + 3) ~/ 4 * 4, '=');
  return Uint8List.fromList(base64Url.decode(padded));
}
