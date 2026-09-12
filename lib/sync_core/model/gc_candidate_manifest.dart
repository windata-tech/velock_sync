import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/sync_core/engine/sync_garbage_collector.dart';

class GcCandidateManifest {
  const GcCandidateManifest({
    required this.vaultId,
    required this.producerDeviceId,
    required this.generatedAt,
    required this.candidates,
    required this.keyId,
    required this.signature,
    this.schemaVersion = 1,
    this.signatureAlgorithm = 'Ed25519',
  });

  final int schemaVersion;
  final String vaultId;
  final String producerDeviceId;
  final DateTime generatedAt;
  final List<GarbageCollectionCandidate> candidates;
  final String signatureAlgorithm;
  final String keyId;
  final String signature;

  Map<String, Object?> signaturePayload() => {
    'schemaVersion': schemaVersion,
    'vaultId': vaultId,
    'producerDeviceId': producerDeviceId,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'candidates': [
      for (final candidate in candidates)
        {
          'candidateId': candidate.candidateId,
          'logicalKeys': candidate.logicalKeys,
          'producerDeviceId': candidate.producerDeviceId,
          'sequence': candidate.sequence,
          'tombstoneAt': candidate.tombstoneAt!.toUtc().toIso8601String(),
          'retentionHoldUntil': candidate.retentionHoldUntil
              ?.toUtc()
              .toIso8601String(),
          'retentionManifestKey': candidate.retentionManifestKey,
          'isReferencedByActiveRevision':
              candidate.isReferencedByActiveRevision,
          'isReferencedByCheckpoint': candidate.isReferencedByCheckpoint,
          'isReferencedByRetentionHold': candidate.isReferencedByRetentionHold,
        },
    ],
    'signatureAlgorithm': signatureAlgorithm,
    'keyId': keyId,
  };

  String signatureCanonicalJson() => jsonEncode(signaturePayload());

  static GcCandidateManifest fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported GC candidate manifest.');
    }
    final rawCandidates = json['candidates'];
    if (rawCandidates is! List) {
      throw const FormatException('Invalid GC candidate list.');
    }
    final candidates = <GarbageCollectionCandidate>[];
    for (final raw in rawCandidates) {
      if (raw is! Map) {
        throw const FormatException('Invalid GC candidate.');
      }
      final candidate = Map<String, dynamic>.from(raw);
      final logicalKeys = candidate['logicalKeys'];
      if (logicalKeys is! List ||
          logicalKeys.any((item) => item is! String || item.isEmpty)) {
        throw const FormatException('Invalid GC logical keys.');
      }
      final sequence = candidate['sequence'];
      final tombstoneAt = candidate['tombstoneAt'];
      if (sequence is! int || sequence < 1 || tombstoneAt is! String) {
        throw const FormatException('Invalid GC candidate identity.');
      }
      final retention = candidate['retentionHoldUntil'];
      final retentionManifestKey = _string(candidate, 'retentionManifestKey');
      candidates.add(
        GarbageCollectionCandidate(
          candidateId: _string(candidate, 'candidateId'),
          logicalKeys: logicalKeys.cast<String>(),
          producerDeviceId: _string(candidate, 'producerDeviceId'),
          sequence: sequence,
          tombstoneAt: DateTime.parse(tombstoneAt).toUtc(),
          retentionHoldUntil: retention is String
              ? DateTime.parse(retention).toUtc()
              : null,
          isReferencedByActiveRevision:
              candidate['isReferencedByActiveRevision'] == true,
          isReferencedByCheckpoint:
              candidate['isReferencedByCheckpoint'] == true,
          retentionManifestKey: retentionManifestKey,
          isReferencedByRetentionHold:
              candidate['isReferencedByRetentionHold'] == true,
        ),
      );
    }
    return GcCandidateManifest(
      vaultId: _string(json, 'vaultId'),
      producerDeviceId: _string(json, 'producerDeviceId'),
      generatedAt: DateTime.parse(_string(json, 'generatedAt')).toUtc(),
      candidates: candidates,
      signatureAlgorithm: _string(json, 'signatureAlgorithm'),
      keyId: _string(json, 'keyId'),
      signature: _string(json, 'signature'),
    );
  }

  Future<void> verify(PublicKey producerKey) async {
    final valid = await Ed25519().verify(
      Uint8List.fromList(utf8.encode(signatureCanonicalJson())),
      signature: Signature(_base64(signature), publicKey: producerKey),
    );
    if (!valid) {
      throw const FormatException(
        'GC candidate manifest signature is invalid.',
      );
    }
  }

  static String _string(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Invalid GC candidate manifest $key.');
    }
    return value;
  }

  static List<int> _base64(String value) {
    try {
      return base64Url.decode(value.padRight((value.length + 3) ~/ 4 * 4, '='));
    } on FormatException {
      throw const FormatException('Invalid GC candidate signature.');
    }
  }
}
