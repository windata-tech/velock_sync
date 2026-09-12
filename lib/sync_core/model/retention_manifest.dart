import 'dart:convert';

/// Privacy-safe retention manifest published by the trusted Velock producer.
///
/// It contains only opaque blob identifiers and protocol metadata. Sync uses
/// it to prevent GC of blobs required for recently-deleted recovery.
class RetentionManifest {
  const RetentionManifest({
    required this.vaultId,
    required this.trashBatchId,
    required this.producerDeviceId,
    required this.createdAt,
    required this.retainUntil,
    required this.blobRefs,
    required this.partCount,
    required this.partDigests,
    required this.keyId,
    required this.signature,
    this.schemaVersion = 1,
    this.signatureAlgorithm = 'Ed25519',
  });

  final int schemaVersion;
  final String vaultId;
  final String trashBatchId;
  final String producerDeviceId;
  final DateTime createdAt;
  final DateTime retainUntil;
  final List<String> blobRefs;
  final int partCount;
  final List<String> partDigests;
  final String signatureAlgorithm;
  final String keyId;
  final String signature;

  bool get isExpired => DateTime.now().toUtc().isAfter(retainUntil);

  bool referencesBlob(String blobId) => blobRefs.contains(blobId);

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'vaultId': vaultId,
    'trashBatchId': trashBatchId,
    'producerDeviceId': producerDeviceId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'retainUntil': retainUntil.toUtc().toIso8601String(),
    'blobRefs': blobRefs,
    'partCount': partCount,
    'partDigests': partDigests,
    'signatureAlgorithm': signatureAlgorithm,
    'keyId': keyId,
    'signature': signature,
  };

  /// Canonical bytes covered by [signature]. The signature field is excluded.
  Map<String, Object?> signaturePayload() => {
    'schemaVersion': schemaVersion,
    'vaultId': vaultId,
    'trashBatchId': trashBatchId,
    'producerDeviceId': producerDeviceId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'retainUntil': retainUntil.toUtc().toIso8601String(),
    'blobRefs': blobRefs,
    'partCount': partCount,
    'partDigests': partDigests,
    'signatureAlgorithm': signatureAlgorithm,
    'keyId': keyId,
  };

  String signatureCanonicalJson() => jsonEncode(signaturePayload());

  static RetentionManifest fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported retention manifest version.');
    }
    final vaultId = _string(json, 'vaultId');
    final trashBatchId = _string(json, 'trashBatchId');
    final producerDeviceId = _string(json, 'producerDeviceId');
    final createdAt = _date(json, 'createdAt');
    final retainUntil = _date(json, 'retainUntil');
    if (!retainUntil.isAfter(createdAt)) {
      throw const FormatException('Retention manifest expiry is invalid.');
    }
    final blobRefs = _stringList(json, 'blobRefs');
    final partDigests = _stringList(json, 'partDigests');
    final partCount = json['partCount'];
    if (partCount is! int || partCount < 1) {
      throw const FormatException('Retention manifest partCount is invalid.');
    }
    if (partDigests.length != partCount) {
      throw const FormatException(
        'Retention manifest part digest count is invalid.',
      );
    }
    return RetentionManifest(
      vaultId: vaultId,
      trashBatchId: trashBatchId,
      producerDeviceId: producerDeviceId,
      createdAt: createdAt,
      retainUntil: retainUntil,
      blobRefs: blobRefs,
      partCount: partCount,
      partDigests: partDigests,
      signatureAlgorithm: _string(json, 'signatureAlgorithm'),
      keyId: _string(json, 'keyId'),
      signature: _string(json, 'signature'),
    );
  }

  static String _string(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Invalid retention manifest $key.');
    }
    return value;
  }

  static DateTime _date(Map<String, dynamic> json, String key) {
    final value = _string(json, key);
    try {
      return DateTime.parse(value).toUtc();
    } on FormatException {
      throw FormatException('Invalid retention manifest $key.');
    }
  }

  static List<String> _stringList(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! List) {
      throw FormatException('Invalid retention manifest $key.');
    }
    final result = <String>[];
    for (final item in value) {
      if (item is! String || item.isEmpty) {
        throw FormatException('Invalid retention manifest $key.');
      }
      result.add(item);
    }
    return List.unmodifiable(result);
  }
}
