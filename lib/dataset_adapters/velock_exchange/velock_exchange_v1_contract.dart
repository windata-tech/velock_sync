import 'dart:convert';
import 'dart:typed_data';

import 'package:velock_sync/sync_core/model/sync_models.dart';

/// Frozen outer contract shared with the trusted Velock companion.
///
/// Sync may inspect this metadata for routing, limits, and integrity, but it
/// never receives the business decryption key and never opens operations.
abstract final class VelockExchangeV1Contract {
  static const exchangeVersion = 1;
  static const protocolName = 'velock-sync';
  static const protocolVersion = 1;
  static const signatureAlgorithm = 'Ed25519';
  static const batchKind = 'incremental';
  static const pairingControlVersion = 1;
  static const pairingRequestTtl = Duration(minutes: 5);
  static const conflictControlVersion = 1;
  static const conflictRequestTtl = Duration(hours: 24);

  static const maxEnvelopeBytes = 4 * 1024 * 1024;
  static const maxOperationsCipherBytes = 64 * 1024 * 1024;
  static const maxOperationsPerBatch = 500;
  static const maxBlobsPerBatch = 500;

  static const androidAuthority = 'tech.windata.velock.sync.exchange';
  static const androidCompanionPackage = 'tech.windata.velock';
  static const androidSyncPackage = 'tech.windata.velock.sync.velock_sync';
  static const androidPermission =
      'tech.windata.velock.permission.SYNC_EXCHANGE';
  static const androidFlutterChannel =
      'tech.windata.velock.sync/velock_exchange';
  static const androidPairingDescriptorMethod = 'pairingDescriptor';
  static const androidSubmitPairingRequestMethod = 'submitPairingRequest';
  static const androidQueryPairingResponseMethod = 'queryPairingResponse';
  static const androidAcknowledgePairingMethod = 'acknowledgePairing';

  static const appleAppGroup = 'group.tech.windata.velock.sync.exchange';
  static const appleSyncFlutterChannel = 'tech.windata.velock.sync/exchange';
  static const appleSyncRootMethod = 'exchangeRoot';
  static const appleCompanionFlutterChannel =
      'tech.windata.velock/method_channel';
  static const appleCompanionRootMethod = 'getSyncExchangeRoot';
  static const appleExchangeSubdirectory = 'SyncExchange';

  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');

  static VelockExchangeEnvelopeMetadata parseEnvelope(Uint8List bytes) {
    if (bytes.length > maxEnvelopeBytes) {
      throw const FormatException('Velock Exchange envelope is too large.');
    }
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Velock Exchange envelope is invalid.');
    }
    _exactKeys(decoded, const {
      'batchId',
      'batchKind',
      'blobs',
      'createdAt',
      'keyId',
      'operations',
      'previousBatchId',
      'previousSequence',
      'protocol',
      'protocolVersion',
      'sequence',
      'signature',
      'signatureAlgorithm',
      'sourceDeviceId',
      'vaultId',
    }, 'envelope');
    if (decoded['protocol'] != protocolName ||
        decoded['protocolVersion'] != protocolVersion ||
        decoded['signatureAlgorithm'] != signatureAlgorithm ||
        decoded['batchKind'] != batchKind) {
      throw const FormatException(
        'Unsupported Velock Exchange envelope version.',
      );
    }
    final vaultId = _string(decoded, 'vaultId');
    final sourceDeviceId = _string(decoded, 'sourceDeviceId');
    final sequence = _positive(decoded, 'sequence');
    final batchId = _string(decoded, 'batchId');
    _string(decoded, 'keyId');
    _string(decoded, 'signature');
    if (!_isUtcTimestamp(decoded['createdAt'])) {
      throw const FormatException('Velock Exchange createdAt is invalid.');
    }

    final previousBatchId = decoded['previousBatchId'];
    final previousSequence = decoded['previousSequence'];
    if ((previousBatchId == null) != (previousSequence == null) ||
        (previousBatchId != null && previousBatchId is! String) ||
        (previousSequence != null && previousSequence is! int) ||
        (sequence == 1 && previousBatchId != null) ||
        (sequence > 1 && previousBatchId == null) ||
        (previousSequence is int && previousSequence != sequence - 1)) {
      throw const FormatException(
        'Velock Exchange previous batch linkage is invalid.',
      );
    }

    final operations = _object(decoded, 'operations');
    _exactKeys(operations, const {
      'cipherSha256',
      'cipherSize',
      'compression',
      'logicalName',
      'operationCount',
    }, 'operations');
    final operationsCipherSize = _nonNegative(operations, 'cipherSize');
    final operationCount = _nonNegative(operations, 'operationCount');
    if (operationsCipherSize > maxOperationsCipherBytes ||
        operationCount > maxOperationsPerBatch ||
        operations['compression'] != 'none' ||
        operations['logicalName'] != 'operations.enc') {
      throw const FormatException(
        'Velock Exchange operations descriptor is invalid.',
      );
    }
    final operationsCipherSha256 = _digest(operations, 'cipherSha256');

    final rawBlobs = decoded['blobs'];
    if (rawBlobs is! List || rawBlobs.length > maxBlobsPerBatch) {
      throw const FormatException(
        'Velock Exchange blob descriptors are invalid.',
      );
    }
    final blobIds = <String>{};
    final blobs = rawBlobs
        .map((item) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException(
              'Velock Exchange blob descriptor is invalid.',
            );
          }
          _exactKeys(item, const {
            'blobId',
            'chunkSize',
            'cipherSha256',
            'cipherSize',
            'logicalKey',
            'protection',
          }, 'blob');
          final blobId = _string(item, 'blobId');
          if (blobId.length < 2 || !blobIds.add(blobId)) {
            throw const FormatException('Duplicate Velock Exchange blob ID.');
          }
          final expectedLogicalKey =
              'velock-sync/v1/$vaultId/blobs/${blobId.substring(0, 2)}/$blobId.blob';
          if (item['logicalKey'] != expectedLogicalKey) {
            throw const FormatException(
              'Velock Exchange blob logical key is invalid.',
            );
          }
          _string(item, 'protection');
          return BlobDescriptor(
            blobId: blobId,
            cipherSize: _nonNegative(item, 'cipherSize'),
            cipherSha256: _digest(item, 'cipherSha256'),
            chunkSize: _nonNegative(item, 'chunkSize'),
          );
        })
        .toList(growable: false);

    return VelockExchangeEnvelopeMetadata(
      vaultId: vaultId,
      sourceDeviceId: sourceDeviceId,
      sequence: sequence,
      batchId: batchId,
      operationsCipherSize: operationsCipherSize,
      operationsCipherSha256: operationsCipherSha256,
      blobs: List.unmodifiable(blobs),
    );
  }

  static void _exactKeys(
    Map<String, dynamic> value,
    Set<String> expected,
    String name,
  ) {
    if (value.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(value.keys.toSet()).isNotEmpty) {
      throw FormatException('Velock Exchange $name schema is invalid.');
    }
  }

  static String _string(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw FormatException('Invalid Velock Exchange $key.');
    }
    return field;
  }

  static String _digest(Map<String, dynamic> value, String key) {
    final field = _string(value, key);
    if (!_sha256.hasMatch(field)) {
      throw FormatException('Invalid Velock Exchange $key.');
    }
    return field;
  }

  static int _positive(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! int || field < 1) {
      throw FormatException('Invalid Velock Exchange $key.');
    }
    return field;
  }

  static int _nonNegative(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! int || field < 0) {
      throw FormatException('Invalid Velock Exchange $key.');
    }
    return field;
  }

  static Map<String, dynamic> _object(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! Map<String, dynamic>) {
      throw FormatException('Invalid Velock Exchange $key.');
    }
    return field;
  }

  static bool _isUtcTimestamp(Object? value) {
    if (value is! String || value.isEmpty) return false;
    try {
      return DateTime.parse(value).isUtc;
    } on FormatException {
      return false;
    }
  }
}

class VelockExchangeEnvelopeMetadata {
  const VelockExchangeEnvelopeMetadata({
    required this.vaultId,
    required this.sourceDeviceId,
    required this.sequence,
    required this.batchId,
    required this.operationsCipherSize,
    required this.operationsCipherSha256,
    required this.blobs,
  });

  final String vaultId;
  final String sourceDeviceId;
  final int sequence;
  final String batchId;
  final int operationsCipherSize;
  final String operationsCipherSha256;
  final List<BlobDescriptor> blobs;
}
