import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_conflict_control_plane.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_service.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';

typedef VelockConflictLauncher = Future<bool> Function(Uri uri);

/// iOS-first conflict control plane over the dedicated Exchange App Group.
///
/// Opening Velock only creates or resumes a content-free request. A Sync
/// conflict completes only after [verify] validates the Velock-owned receipt
/// under the public key retained during pairing.
class AppleVelockConflictGateway
    implements VelockConflictOpener, VelockConflictReceiptVerifier {
  AppleVelockConflictGateway({
    required SyncStateDatabase database,
    AppleExchangeRootLocator? rootLocator,
    VelockConflictLauncher? launchVelock,
    String Function()? nextChallenge,
    DateTime Function()? now,
  }) : _database = database,
       _rootLocator = rootLocator ?? AppleExchangeRootLocator(),
       _launchVelock = launchVelock ?? launchUrl,
       _nextChallenge = nextChallenge ?? const Uuid().v4,
       _now = now ?? DateTime.now;

  final SyncStateDatabase _database;
  final AppleExchangeRootLocator _rootLocator;
  final VelockConflictLauncher _launchVelock;
  final String Function() _nextChallenge;
  final DateTime Function() _now;

  @override
  Future<VelockConflictResolutionReceipt> open({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
  }) async {
    final velockProfile = VelockSyncProfile.fromEnvelope(profile);
    final root = await _root();
    final requestId = _requestId(profile.profileId, conflict.conflictId);
    final requestFile = File(
      '${root.path}/Control/ConflictRequests/$requestId.json',
    );
    final receiptFile = File(
      '${root.path}/Control/ConflictReceipts/$requestId.json',
    );
    final consumedFile = File(
      '${root.path}/Control/ConflictConsumed/$requestId.json',
    );
    if (await consumedFile.exists()) {
      throw const ConflictResolutionFailure('velock-receipt-consumed');
    }

    var request = await requestFile.exists()
        ? VelockConflictControlRequest.parse(await _readBounded(requestFile))
        : null;
    if (request != null && !_matchesRequest(request, velockProfile, conflict)) {
      throw const ConflictResolutionFailure('velock-request-mismatch');
    }
    final now = _now().toUtc();
    if (request != null && !now.isBefore(request.expiresAt)) {
      if (await receiptFile.exists()) {
        throw const ConflictResolutionFailure('velock-receipt-expired');
      }
      await requestFile.delete();
      request = null;
    }
    request ??= VelockConflictControlRequest(
      requestId: requestId,
      challenge: _opaque(_nextChallenge(), 'challenge'),
      conflictId: _opaque(conflict.conflictId, 'conflictId'),
      vaultId: _opaque(profile.vaultId, 'vaultId'),
      producerId: _opaque(velockProfile.pairedProducerId, 'producerId'),
      producerPublicKeyId: _opaque(
        velockProfile.pairedProducerPublicKeyId,
        'producerPublicKeyId',
      ),
      exchangeBindingId: _opaque(
        velockProfile.exchangeBindingId,
        'exchangeBindingId',
      ),
      syncAppInstanceId: _opaque(profile.deviceId, 'syncAppInstanceId'),
      createdAt: now,
      expiresAt: now.add(VelockExchangeV1Contract.conflictRequestTtl),
    );
    if (!await requestFile.exists()) {
      await _writeAtomic(requestFile, request.encode());
    }

    if (await receiptFile.exists()) {
      return VelockConflictResolutionReceipt(
        VelockConflictControlReceipt.parse(
          await _readBounded(receiptFile),
        ).artifact,
      );
    }
    final launched = await _launchVelock(
      Uri(
        scheme: 'velock',
        host: 'sync-conflict',
        queryParameters: {'requestId': requestId},
      ),
    );
    if (!launched) {
      throw const ConflictResolutionFailure('velock-launch-failed');
    }
    if (await receiptFile.exists()) {
      return VelockConflictResolutionReceipt(
        VelockConflictControlReceipt.parse(
          await _readBounded(receiptFile),
        ).artifact,
      );
    }
    throw const ConflictResolutionFailure('velock-resolution-pending');
  }

  @override
  Future<bool> verify({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
    required VelockConflictResolutionReceipt receipt,
  }) async {
    try {
      final velockProfile = VelockSyncProfile.fromEnvelope(profile);
      final parsed = VelockConflictControlReceipt.fromArtifact(
        receipt.artifact,
      );
      final root = await _root();
      final requestFile = File(
        '${root.path}/Control/ConflictRequests/${parsed.requestId}.json',
      );
      if (!await requestFile.exists()) return false;
      final request = VelockConflictControlRequest.parse(
        await _readBounded(requestFile),
      );
      final now = _now().toUtc();
      if (!now.isBefore(parsed.expiresAt) ||
          !_matchesRequest(request, velockProfile, conflict) ||
          parsed.requestId != request.requestId ||
          parsed.challenge != request.challenge ||
          parsed.conflictId != request.conflictId ||
          parsed.vaultId != request.vaultId ||
          parsed.producerId != request.producerId ||
          parsed.producerPublicKeyId != request.producerPublicKeyId ||
          parsed.exchangeBindingId != request.exchangeBindingId ||
          parsed.syncAppInstanceId != request.syncAppInstanceId ||
          parsed.expiresAt != request.expiresAt ||
          parsed.resolvedAt.isBefore(request.createdAt)) {
        return false;
      }
      final trusted = await _database.readTrustedDevicePublicKeys(
        vaultId: profile.vaultId,
      );
      final key = trusted[velockProfile.pairedProducerId];
      if (key == null) return false;
      return await Ed25519().verify(
        parsed.signaturePayload(),
        signature: Signature(
          parsed.signature,
          publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      return false;
    }
  }

  @override
  Future<void> acknowledge({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
    required VelockConflictResolutionReceipt receipt,
  }) async {
    final parsed = VelockConflictControlReceipt.fromArtifact(receipt.artifact);
    final root = await _root();
    await _writeAtomic(
      File('${root.path}/Control/ConflictConsumed/${parsed.requestId}.json'),
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'consumedAt': _now().toUtc().toIso8601String(),
            'requestId': parsed.requestId,
            'resolutionArtifactId': parsed.resolutionArtifactId,
          }),
        ),
      ),
    );
    for (final path in [
      '${root.path}/Control/ConflictRequests/${parsed.requestId}.json',
      '${root.path}/Control/ConflictReceipts/${parsed.requestId}.json',
    ]) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  bool _matchesRequest(
    VelockConflictControlRequest request,
    VelockSyncProfile profile,
    SyncConflictRecord conflict,
  ) =>
      request.requestId == _requestId(profile.profileId, conflict.conflictId) &&
      request.conflictId == conflict.conflictId &&
      request.vaultId == profile.vaultId &&
      request.producerId == profile.pairedProducerId &&
      request.producerPublicKeyId == profile.pairedProducerPublicKeyId &&
      request.exchangeBindingId == profile.exchangeBindingId &&
      request.syncAppInstanceId == profile.deviceId;

  Future<Directory> _root() async {
    final root = await _rootLocator.locate();
    if (!await root.exists() || await FileSystemEntity.isLink(root.path)) {
      throw StateError('Velock exchange App Group is unavailable.');
    }
    return root;
  }

  Future<Uint8List> _readBounded(File file) async {
    if (!await file.exists() || await FileSystemEntity.isLink(file.path)) {
      throw StateError('Velock conflict artifact is unavailable.');
    }
    final length = await file.length();
    if (length < 1 || length > 16 * 1024) {
      throw const FormatException('Velock conflict artifact is too large.');
    }
    return file.readAsBytes();
  }

  Future<void> _writeAtomic(File target, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 16 * 1024) {
      throw const FormatException('Velock conflict artifact is invalid.');
    }
    await target.parent.create(recursive: true);
    if (await FileSystemEntity.isLink(target.parent.path)) {
      throw StateError('Velock conflict directory is invalid.');
    }
    final temporary = File('${target.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
  }
}

String _requestId(String profileId, String conflictId) => base64UrlEncode(
  sha256
      .convert(
        utf8.encode(
          'velock-conflict-request-v1\u0000$profileId\u0000$conflictId',
        ),
      )
      .bytes,
).replaceAll('=', '');

String _opaque(String value, String name) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
    throw ArgumentError.value(value, name);
  }
  return value;
}
