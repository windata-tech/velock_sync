import 'dart:convert';

class SyncAcknowledgement {
  const SyncAcknowledgement({
    required this.vaultId,
    required this.consumerDeviceId,
    required this.producerDeviceId,
    required this.appliedThroughSequence,
    required this.createdAt,
    required this.signature,
    this.protocolVersion = 1,
    this.signatureAlgorithm = 'Ed25519',
  });

  final String vaultId;
  final String consumerDeviceId;
  final String producerDeviceId;
  final int appliedThroughSequence;
  final DateTime createdAt;
  final String signature;
  final int protocolVersion;
  final String signatureAlgorithm;

  Map<String, Object?> signaturePayload() => {
    'appliedThroughSequence': appliedThroughSequence,
    'consumerDeviceId': consumerDeviceId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'producerDeviceId': producerDeviceId,
    'protocolVersion': protocolVersion,
    'signatureAlgorithm': signatureAlgorithm,
    'vaultId': vaultId,
  };

  String signatureCanonicalJson() => jsonEncode(signaturePayload());

  static SyncAcknowledgement fromJson(Map<String, dynamic> json) {
    final applied = json['appliedThroughSequence'];
    final protocol = json['protocolVersion'];
    if (applied is! int || applied < 1 || protocol != 1) {
      throw const FormatException('Invalid sync acknowledgement.');
    }
    final createdAt = json['createdAt'];
    if (createdAt is! String) {
      throw const FormatException('Invalid sync acknowledgement timestamp.');
    }
    return SyncAcknowledgement(
      vaultId: _string(json, 'vaultId'),
      consumerDeviceId: _string(json, 'consumerDeviceId'),
      producerDeviceId: _string(json, 'producerDeviceId'),
      appliedThroughSequence: applied,
      createdAt: DateTime.parse(createdAt).toUtc(),
      signature: _string(json, 'signature'),
      signatureAlgorithm: _string(json, 'signatureAlgorithm'),
    );
  }

  static String _string(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Invalid sync acknowledgement $key.');
    }
    return value;
  }
}
