import 'dart:convert';
import 'dart:typed_data';

import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';

final RegExp _opaqueId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// Content-free request written by Velock Sync for one Velock-owned conflict.
///
/// The request identifies only protocol objects. Velock resolves and displays
/// the business record from its own authenticated database.
class VelockConflictControlRequest {
  const VelockConflictControlRequest({
    required this.requestId,
    required this.challenge,
    required this.conflictId,
    required this.vaultId,
    required this.producerId,
    required this.producerPublicKeyId,
    required this.exchangeBindingId,
    required this.syncAppInstanceId,
    required this.createdAt,
    required this.expiresAt,
  });

  final String requestId;
  final String challenge;
  final String conflictId;
  final String vaultId;
  final String producerId;
  final String producerPublicKeyId;
  final String exchangeBindingId;
  final String syncAppInstanceId;
  final DateTime createdAt;
  final DateTime expiresAt;

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  Map<String, Object> toJson() => {
    'challenge': challenge,
    'conflictId': conflictId,
    'controlVersion': VelockExchangeV1Contract.conflictControlVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'exchangeBindingId': exchangeBindingId,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'producerId': producerId,
    'producerPublicKeyId': producerPublicKeyId,
    'requestId': requestId,
    'syncAppInstanceId': syncAppInstanceId,
    'vaultId': vaultId,
  };

  static VelockConflictControlRequest parse(Uint8List bytes) {
    final json = _object(bytes, const {
      'challenge',
      'conflictId',
      'controlVersion',
      'createdAt',
      'exchangeBindingId',
      'expiresAt',
      'producerId',
      'producerPublicKeyId',
      'requestId',
      'syncAppInstanceId',
      'vaultId',
    });
    if (json['controlVersion'] !=
        VelockExchangeV1Contract.conflictControlVersion) {
      throw const FormatException('Unsupported Velock conflict request.');
    }
    final request = VelockConflictControlRequest(
      requestId: _id(json, 'requestId'),
      challenge: _id(json, 'challenge'),
      conflictId: _id(json, 'conflictId'),
      vaultId: _id(json, 'vaultId'),
      producerId: _id(json, 'producerId'),
      producerPublicKeyId: _id(json, 'producerPublicKeyId'),
      exchangeBindingId: _id(json, 'exchangeBindingId'),
      syncAppInstanceId: _id(json, 'syncAppInstanceId'),
      createdAt: _utc(json, 'createdAt'),
      expiresAt: _utc(json, 'expiresAt'),
    );
    if (!request.expiresAt.isAfter(request.createdAt) ||
        request.expiresAt.difference(request.createdAt) >
            VelockExchangeV1Contract.conflictRequestTtl) {
      throw const FormatException('Invalid Velock conflict request lifetime.');
    }
    return request;
  }
}

/// Velock-owned proof that its business conflict was durably resolved.
///
/// [resolutionArtifactId] is generated and persisted by Velock's resolution
/// transaction. Sync treats it as opaque and trusts it only under the paired
/// producer's Ed25519 signature and the exact request binding.
class VelockConflictControlReceipt {
  const VelockConflictControlReceipt({
    required this.requestId,
    required this.challenge,
    required this.conflictId,
    required this.vaultId,
    required this.producerId,
    required this.producerPublicKeyId,
    required this.exchangeBindingId,
    required this.syncAppInstanceId,
    required this.resolutionArtifactId,
    required this.resolvedAt,
    required this.expiresAt,
    required this.signature,
  });

  final String requestId;
  final String challenge;
  final String conflictId;
  final String vaultId;
  final String producerId;
  final String producerPublicKeyId;
  final String exchangeBindingId;
  final String syncAppInstanceId;
  final String resolutionArtifactId;
  final DateTime resolvedAt;
  final DateTime expiresAt;
  final Uint8List signature;

  Map<String, Object> unsignedJson() => {
    'challenge': challenge,
    'conflictId': conflictId,
    'controlVersion': VelockExchangeV1Contract.conflictControlVersion,
    'exchangeBindingId': exchangeBindingId,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'producerId': producerId,
    'producerPublicKeyId': producerPublicKeyId,
    'requestId': requestId,
    'resolutionArtifactId': resolutionArtifactId,
    'resolvedAt': resolvedAt.toUtc().toIso8601String(),
    'signatureAlgorithm': VelockExchangeV1Contract.signatureAlgorithm,
    'status': 'resolved',
    'syncAppInstanceId': syncAppInstanceId,
    'vaultId': vaultId,
  };

  Uint8List signaturePayload() =>
      Uint8List.fromList(utf8.encode(jsonEncode(unsignedJson())));

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        ...unsignedJson(),
        'signature': base64UrlEncode(signature).replaceAll('=', ''),
      }),
    ),
  );

  String get artifact =>
      'velock-conflict-v1:${base64UrlEncode(encode()).replaceAll('=', '')}';

  static VelockConflictControlReceipt parse(Uint8List bytes) {
    final json = _object(bytes, const {
      'challenge',
      'conflictId',
      'controlVersion',
      'exchangeBindingId',
      'expiresAt',
      'producerId',
      'producerPublicKeyId',
      'requestId',
      'resolutionArtifactId',
      'resolvedAt',
      'signature',
      'signatureAlgorithm',
      'status',
      'syncAppInstanceId',
      'vaultId',
    });
    if (json['controlVersion'] !=
            VelockExchangeV1Contract.conflictControlVersion ||
        json['signatureAlgorithm'] !=
            VelockExchangeV1Contract.signatureAlgorithm ||
        json['status'] != 'resolved') {
      throw const FormatException('Unsupported Velock conflict receipt.');
    }
    final signature = _base64(json, 'signature');
    if (signature.length != 64) {
      throw const FormatException('Invalid Velock conflict signature.');
    }
    final receipt = VelockConflictControlReceipt(
      requestId: _id(json, 'requestId'),
      challenge: _id(json, 'challenge'),
      conflictId: _id(json, 'conflictId'),
      vaultId: _id(json, 'vaultId'),
      producerId: _id(json, 'producerId'),
      producerPublicKeyId: _id(json, 'producerPublicKeyId'),
      exchangeBindingId: _id(json, 'exchangeBindingId'),
      syncAppInstanceId: _id(json, 'syncAppInstanceId'),
      resolutionArtifactId: _id(json, 'resolutionArtifactId'),
      resolvedAt: _utc(json, 'resolvedAt'),
      expiresAt: _utc(json, 'expiresAt'),
      signature: signature,
    );
    if (receipt.resolvedAt.isAfter(receipt.expiresAt)) {
      throw const FormatException('Invalid Velock conflict receipt lifetime.');
    }
    return receipt;
  }

  static VelockConflictControlReceipt fromArtifact(String artifact) {
    const prefix = 'velock-conflict-v1:';
    if (!artifact.startsWith(prefix)) {
      throw const FormatException('Invalid Velock conflict artifact.');
    }
    return parse(_decodeBase64(artifact.substring(prefix.length)));
  }
}

Map<String, dynamic> _object(Uint8List bytes, Set<String> fields) {
  if (bytes.isEmpty || bytes.length > 16 * 1024) {
    throw const FormatException('Invalid Velock conflict object size.');
  }
  final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  if (value is! Map<String, dynamic> ||
      value.keys.toSet().difference(fields).isNotEmpty ||
      fields.difference(value.keys.toSet()).isNotEmpty) {
    throw const FormatException('Invalid Velock conflict object.');
  }
  return value;
}

String _id(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || !_opaqueId.hasMatch(value)) {
    throw FormatException('Invalid Velock conflict $key.');
  }
  return value;
}

DateTime _utc(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid Velock conflict $key.');
  final parsed = DateTime.parse(value);
  if (!parsed.isUtc || parsed.toIso8601String() != value) {
    throw FormatException('Invalid Velock conflict $key.');
  }
  return parsed;
}

Uint8List _base64(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid Velock conflict $key.');
  return _decodeBase64(value);
}

Uint8List _decodeBase64(String value) {
  try {
    final padding = '=' * ((4 - value.length % 4) % 4);
    return Uint8List.fromList(base64Url.decode('$value$padding'));
  } on FormatException {
    throw const FormatException('Invalid Velock conflict base64.');
  }
}
