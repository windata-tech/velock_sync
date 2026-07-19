import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';

final RegExp _opaqueId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

class VelockPairingDescriptor {
  const VelockPairingDescriptor({
    required this.producerId,
    required this.producerPublicKeyId,
    required this.producerSigningPublicKey,
    required this.exchangeBindingId,
    required this.publishedAt,
  });

  final String producerId;
  final String producerPublicKeyId;
  final String producerSigningPublicKey;
  final String exchangeBindingId;
  final DateTime publishedAt;

  static VelockPairingDescriptor parse(Uint8List bytes) {
    final json = _object(bytes, const {
      'controlVersion',
      'exchangeBindingId',
      'exchangeVersion',
      'producerId',
      'producerPublicKeyId',
      'producerSigningPublicKey',
      'protocol',
      'protocolVersion',
      'publishedAt',
      'signatureAlgorithm',
    });
    if (json['controlVersion'] !=
            VelockExchangeV1Contract.pairingControlVersion ||
        json['exchangeVersion'] != VelockExchangeV1Contract.exchangeVersion ||
        json['protocol'] != VelockExchangeV1Contract.protocolName ||
        json['protocolVersion'] != VelockExchangeV1Contract.protocolVersion ||
        json['signatureAlgorithm'] !=
            VelockExchangeV1Contract.signatureAlgorithm) {
      throw const FormatException('Unsupported Velock pairing descriptor.');
    }
    final publicKey = _publicKey(json, 'producerSigningPublicKey');
    return VelockPairingDescriptor(
      producerId: _id(json, 'producerId'),
      producerPublicKeyId: _id(json, 'producerPublicKeyId'),
      producerSigningPublicKey: base64UrlEncode(publicKey),
      exchangeBindingId: _id(json, 'exchangeBindingId'),
      publishedAt: _utc(json, 'publishedAt'),
    );
  }

  SimplePublicKey get publicKey => SimplePublicKey(
    _decodePublicKey(producerSigningPublicKey),
    type: KeyPairType.ed25519,
  );
}

class VelockPairingControlRequest {
  const VelockPairingControlRequest({
    required this.requestId,
    required this.challenge,
    required this.producerId,
    required this.producerPublicKeyId,
    required this.exchangeBindingId,
    required this.syncAppInstanceId,
    required this.createdAt,
    required this.expiresAt,
  });

  final String requestId;
  final String challenge;
  final String producerId;
  final String producerPublicKeyId;
  final String exchangeBindingId;
  final String syncAppInstanceId;
  final DateTime createdAt;
  final DateTime expiresAt;

  Map<String, Object> toJson() {
    for (final entry in {
      'requestId': requestId,
      'challenge': challenge,
      'producerId': producerId,
      'producerPublicKeyId': producerPublicKeyId,
      'exchangeBindingId': exchangeBindingId,
      'syncAppInstanceId': syncAppInstanceId,
    }.entries) {
      _requireId(entry.value, entry.key);
    }
    if (!createdAt.isUtc ||
        !expiresAt.isUtc ||
        !expiresAt.isAfter(createdAt) ||
        expiresAt.difference(createdAt) >
            VelockExchangeV1Contract.pairingRequestTtl) {
      throw const FormatException('Invalid Velock pairing request lifetime.');
    }
    return {
      'challenge': challenge,
      'createdAt': createdAt.toIso8601String(),
      'exchangeBindingId': exchangeBindingId,
      'expiresAt': expiresAt.toIso8601String(),
      'producerId': producerId,
      'producerPublicKeyId': producerPublicKeyId,
      'requestId': requestId,
      'syncAppInstanceId': syncAppInstanceId,
    };
  }

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
}

class VelockPairingControlResponse {
  const VelockPairingControlResponse({
    required this.requestId,
    required this.challenge,
    required this.producerId,
    required this.producerPublicKeyId,
    required this.producerSigningPublicKey,
    required this.exchangeBindingId,
    required this.vaultId,
    required this.vaultDisplayName,
    required this.deviceDisplayName,
    required this.approvedAt,
    required this.expiresAt,
    required this.signature,
  });

  final String requestId;
  final String challenge;
  final String producerId;
  final String producerPublicKeyId;
  final String producerSigningPublicKey;
  final String exchangeBindingId;
  final String vaultId;
  final String vaultDisplayName;
  final String deviceDisplayName;
  final DateTime approvedAt;
  final DateTime expiresAt;
  final Uint8List signature;

  static VelockPairingControlResponse parse(Uint8List bytes) {
    final json = _object(bytes, const {
      'approvedAt',
      'challenge',
      'deviceDisplayName',
      'exchangeBindingId',
      'expiresAt',
      'producerId',
      'producerPublicKeyId',
      'producerSigningPublicKey',
      'requestId',
      'signature',
      'vaultDisplayName',
      'vaultId',
    });
    final signatureText = json['signature'];
    if (signatureText is! String) {
      throw const FormatException('Invalid Velock pairing signature.');
    }
    final signature = _base64(signatureText, 'signature');
    if (signature.length != 64) {
      throw const FormatException('Invalid Velock pairing signature.');
    }
    final response = VelockPairingControlResponse(
      requestId: _id(json, 'requestId'),
      challenge: _id(json, 'challenge'),
      producerId: _id(json, 'producerId'),
      producerPublicKeyId: _id(json, 'producerPublicKeyId'),
      producerSigningPublicKey: base64UrlEncode(
        _publicKey(json, 'producerSigningPublicKey'),
      ),
      exchangeBindingId: _id(json, 'exchangeBindingId'),
      vaultId: _id(json, 'vaultId'),
      vaultDisplayName: _displayName(json, 'vaultDisplayName'),
      deviceDisplayName: _displayName(json, 'deviceDisplayName'),
      approvedAt: _utc(json, 'approvedAt'),
      expiresAt: _utc(json, 'expiresAt'),
      signature: signature,
    );
    if (!response.expiresAt.isAfter(response.approvedAt)) {
      throw const FormatException('Invalid Velock pairing response lifetime.');
    }
    return response;
  }

  Map<String, Object> unsignedJson() => {
    'approvedAt': approvedAt.toIso8601String(),
    'challenge': challenge,
    'deviceDisplayName': deviceDisplayName,
    'exchangeBindingId': exchangeBindingId,
    'expiresAt': expiresAt.toIso8601String(),
    'producerId': producerId,
    'producerPublicKeyId': producerPublicKeyId,
    'producerSigningPublicKey': producerSigningPublicKey,
    'requestId': requestId,
    'vaultDisplayName': vaultDisplayName,
    'vaultId': vaultId,
  };

  Uint8List signaturePayload() =>
      Uint8List.fromList(utf8.encode(jsonEncode(unsignedJson())));

  Future<bool> verify({
    required VelockPairingDescriptor descriptor,
    required VelockPairingControlRequest request,
    DateTime Function()? now,
  }) async {
    final current = (now ?? DateTime.now)().toUtc();
    if (!current.isBefore(expiresAt) ||
        request.requestId != requestId ||
        request.challenge != challenge ||
        request.producerId != producerId ||
        request.producerPublicKeyId != producerPublicKeyId ||
        request.exchangeBindingId != exchangeBindingId ||
        descriptor.producerId != producerId ||
        descriptor.producerPublicKeyId != producerPublicKeyId ||
        descriptor.producerSigningPublicKey != producerSigningPublicKey ||
        descriptor.exchangeBindingId != exchangeBindingId) {
      return false;
    }
    return Ed25519().verify(
      signaturePayload(),
      signature: Signature(signature, publicKey: descriptor.publicKey),
    );
  }
}

enum VelockPairingControlStatus { pending, approved, denied, expired, revoked }

/// Platform-neutral pairing control boundary.
///
/// Android implements this through the signature-protected provider; Apple
/// implements it through the dedicated, entitlement-protected App Group.
abstract interface class VelockPairingControlChannel {
  Future<VelockPairingDescriptor> pairingDescriptor();
  Future<VelockPairingControlStatus> submitPairingRequest(
    VelockPairingControlRequest request,
  );
  Future<VelockPairingControlResult> queryPairingResponse(String requestId);
  Future<void> acknowledgePairing(String requestId);
}

class VelockPairingControlResult {
  const VelockPairingControlResult({required this.status, this.response});

  final VelockPairingControlStatus status;
  final VelockPairingControlResponse? response;
}

Map<String, dynamic> _object(Uint8List bytes, Set<String> expected) {
  if (bytes.length > 16 * 1024) {
    throw const FormatException('Velock pairing object is too large.');
  }
  final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  if (value is! Map<String, dynamic> ||
      value.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(value.keys.toSet()).isNotEmpty) {
    throw const FormatException('Invalid Velock pairing object.');
  }
  return value;
}

String _id(Map<String, dynamic> json, String key) => _requireId(json[key], key);

String _requireId(Object? value, String name) {
  if (value is! String || !_opaqueId.hasMatch(value)) {
    throw FormatException('Invalid Velock pairing $name.');
  }
  return value;
}

DateTime _utc(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid pairing $key.');
  final parsed = DateTime.parse(value);
  if (!parsed.isUtc) throw FormatException('Invalid pairing $key.');
  return parsed;
}

String _displayName(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String ||
      value.trim().isEmpty ||
      value != value.trim() ||
      value.length > 128) {
    throw FormatException('Invalid pairing $key.');
  }
  return value;
}

List<int> _publicKey(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid pairing $key.');
  final bytes = _decodePublicKey(value);
  if (bytes.length != 32) throw FormatException('Invalid pairing $key.');
  return bytes;
}

List<int> _decodePublicKey(String value) => _base64(value, 'public key');

Uint8List _base64(String value, String name) {
  try {
    return Uint8List.fromList(
      base64Url.decode(value.padRight((value.length + 3) ~/ 4 * 4, '=')),
    );
  } on FormatException {
    throw FormatException('Invalid Velock pairing $name.');
  }
}
