import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

/// Public, content-free cross-app intent. A request grants no authority: the
/// unlocked owner validates local pairing and obtains explicit user consent.
/// This file is kept byte-identical in Sync and Velock.
///
/// Keys a later version adds are extensions: kept, sorted and hashed or signed
/// with the rest, their meaning ignored (see `velock_exchange_extensions.dart`).
/// Every value, extensions included, must be a String or int.
class SnapshotControlRequest {
  SnapshotControlRequest({
    required this.requestId,
    required this.challenge,
    required this.operation,
    required this.snapshotId,
    required this.vaultId,
    required this.producerId,
    required this.actorDeviceId,
    required this.actorPublicKeyId,
    required this.exchangeBindingId,
    required this.syncAppInstanceId,
    required this.destinationLabel,
    required this.destinationHash,
    required this.createdAt,
    required this.expiresAt,
    this.extensions = const {},
  }) {
    for (final id in [
      requestId,
      challenge,
      snapshotId,
      vaultId,
      producerId,
      actorDeviceId,
      actorPublicKeyId,
      syncAppInstanceId,
    ]) {
      _identifier(id);
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(exchangeBindingId) ||
        !const {'build', 'apply'}.contains(operation) ||
        (operation == 'build' && producerId != actorDeviceId) ||
        (operation == 'apply' && producerId == actorDeviceId) ||
        destinationLabel.trim().isEmpty ||
        destinationLabel.length > 2048 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(destinationLabel) ||
        !_hash(destinationHash) ||
        !createdAt.isUtc ||
        !expiresAt.isUtc ||
        expiresAt.difference(createdAt) != const Duration(minutes: 5)) {
      throw const FormatException('Invalid snapshot request.');
    }
  }
  final String requestId, challenge, operation, snapshotId, vaultId, producerId;
  final String actorDeviceId, actorPublicKeyId, exchangeBindingId;
  final String syncAppInstanceId, destinationLabel, destinationHash;
  final DateTime createdAt, expiresAt;
  final Map<String, Object> extensions;

  static const _fields = {
    'kind',
    'version',
    'requestId',
    'challenge',
    'operation',
    'snapshotId',
    'vaultId',
    'producerId',
    'actorDeviceId',
    'actorPublicKeyId',
    'exchangeBindingId',
    'syncAppInstanceId',
    'destinationLabel',
    'destinationHash',
    'createdAt',
    'expiresAt',
  };

  void assertFresh(DateTime now) {
    if (now.isBefore(createdAt) || !now.isBefore(expiresAt)) {
      throw StateError('Snapshot approval request expired.');
    }
  }

  Map<String, Object> toJson() => {
    'kind': 'velock-snapshot-request',
    'version': 2,
    'requestId': requestId,
    'challenge': challenge,
    'operation': operation,
    'snapshotId': snapshotId,
    'vaultId': vaultId,
    'producerId': producerId,
    'actorDeviceId': actorDeviceId,
    'actorPublicKeyId': actorPublicKeyId,
    'exchangeBindingId': exchangeBindingId,
    'syncAppInstanceId': syncAppInstanceId,
    'destinationLabel': destinationLabel,
    'destinationHash': destinationHash,
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    ..._extensions(extensions, _fields),
  };
  Uint8List encode() => _encode(toJson());
  String get digest => sha256.convert(encode()).toString();

  static SnapshotControlRequest parse(List<int> bytes) {
    final m = _decode(bytes);
    _keys(m, _fields);
    if (m['kind'] != 'velock-snapshot-request' || m['version'] != 2) {
      throw const FormatException('Unsupported snapshot request.');
    }
    return SnapshotControlRequest(
      requestId: _string(m, 'requestId'),
      challenge: _string(m, 'challenge'),
      operation: _string(m, 'operation'),
      snapshotId: _string(m, 'snapshotId'),
      vaultId: _string(m, 'vaultId'),
      producerId: _string(m, 'producerId'),
      actorDeviceId: _string(m, 'actorDeviceId'),
      actorPublicKeyId: _string(m, 'actorPublicKeyId'),
      exchangeBindingId: _string(m, 'exchangeBindingId'),
      syncAppInstanceId: _string(m, 'syncAppInstanceId'),
      destinationLabel: _string(m, 'destinationLabel'),
      destinationHash: _string(m, 'destinationHash'),
      createdAt: _date(m, 'createdAt'),
      expiresAt: _date(m, 'expiresAt'),
      extensions: _unknown(m, _fields),
    );
  }
}

/// Signed proof of this exact request's completion. 'build' proves a staged
/// candidate, never remote upload or restore. 'apply' is issued only after the
/// owner's durable application and readback. Approval must precede expiry;
/// large work may finish later. Replaying a response for another request fails.
class SnapshotControlReceipt {
  SnapshotControlReceipt._(
    this.requestDigest,
    this.manifestHash,
    this.approvedAt,
    this.completedAt,
    this.signature, [
    this.extensions = const {},
  ]);
  final String requestDigest, manifestHash;
  final DateTime approvedAt, completedAt;
  final Uint8List signature;
  final Map<String, Object> extensions;

  static const _fields = {
    'kind',
    'version',
    'requestSha256',
    'manifestSha256',
    'approvedAt',
    'completedAt',
    'signature',
  };

  Map<String, Object> _body() => {
    'kind': 'velock-snapshot-receipt',
    'version': 2,
    'requestSha256': requestDigest,
    'manifestSha256': manifestHash,
    'approvedAt': approvedAt.toIso8601String(),
    'completedAt': completedAt.toIso8601String(),
    ..._extensions(extensions, _fields),
  };
  Uint8List encode() =>
      _encode({..._body(), 'signature': base64UrlEncode(signature)});
  static List<int> _payload(Map<String, Object> body) => [
    ...utf8.encode('VelockSnapshotControlReceipt/2\n'),
    ..._encode(body),
  ];
  static Future<SnapshotControlReceipt> sign({
    required SnapshotControlRequest request,
    required String manifestHash,
    required DateTime approvedAt,
    required DateTime completedAt,
    required KeyPair signingKey,
  }) async {
    request.assertFresh(approvedAt);
    if (!_hash(manifestHash) ||
        !approvedAt.isUtc ||
        !completedAt.isUtc ||
        completedAt.isBefore(approvedAt)) {
      throw const FormatException('Invalid snapshot completion.');
    }
    final draft = SnapshotControlReceipt._(
      request.digest,
      manifestHash,
      approvedAt,
      completedAt,
      Uint8List(0),
    );
    final signature = await Ed25519().sign(
      _payload(draft._body()),
      keyPair: signingKey,
    );
    return SnapshotControlReceipt._(
      request.digest,
      manifestHash,
      approvedAt,
      completedAt,
      Uint8List.fromList(signature.bytes).asUnmodifiableView(),
    );
  }

  static Future<SnapshotControlReceipt> verify({
    required List<int> bytes,
    required SnapshotControlRequest request,
    required PublicKey trustedActorKey,
  }) async {
    final m = _decode(bytes);
    _keys(m, _fields);
    final approved = _date(m, 'approvedAt');
    final completed = _date(m, 'completedAt');
    request.assertFresh(approved);
    final hash = _string(m, 'manifestSha256');
    if (m['kind'] != 'velock-snapshot-receipt' ||
        m['version'] != 2 ||
        m['requestSha256'] != request.digest ||
        !_hash(hash) ||
        completed.isBefore(approved)) {
      throw const FormatException('Snapshot receipt does not match request.');
    }
    final signature = base64Url.decode(_string(m, 'signature'));
    final result = SnapshotControlReceipt._(
      request.digest,
      hash,
      approved,
      completed,
      Uint8List.fromList(signature).asUnmodifiableView(),
      _unknown(m, _fields),
    );
    if (signature.length != 64 ||
        !await Ed25519().verify(
          _payload(result._body()),
          signature: Signature(signature, publicKey: trustedActorKey),
        )) {
      throw const FormatException('Snapshot receipt signature invalid.');
    }
    return result;
  }
}

Uint8List _encode(Map<String, Object> m) {
  final keys = m.keys.toList()..sort();
  return Uint8List.fromList(
    utf8.encode(jsonEncode({for (final k in keys) k: m[k]})),
  );
}

Map<String, dynamic> _decode(List<int> input) {
  if (input.isEmpty || input.length > 16384) {
    throw const FormatException('Control size limit.');
  }
  final value = jsonDecode(utf8.decode(input));
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Control object required.');
  }
  // All protocol fields are scalar and non-null. Require byte-canonical input.
  if (value.values.any((v) => v is! String && v is! int)) {
    throw const FormatException('Invalid control value.');
  }
  final encoded = _encode(value.cast<String, Object>());
  if (encoded.length != input.length) {
    throw const FormatException('Noncanonical control.');
  }
  for (var i = 0; i < input.length; i++) {
    if (input[i] != encoded[i]) {
      throw const FormatException('Noncanonical control.');
    }
  }
  return value;
}

void _keys(Map<String, dynamic> m, Set<String> expected) {
  if (!m.keys.toSet().containsAll(expected)) {
    throw const FormatException('Missing control fields.');
  }
}

Map<String, Object> _unknown(Map<String, dynamic> m, Set<String> known) =>
    Map.unmodifiable({
      for (final e in m.entries)
        if (!known.contains(e.key)) e.key: e.value as Object,
    });

Map<String, Object> _extensions(Map<String, Object> ext, Set<String> known) {
  for (final e in ext.entries) {
    if (known.contains(e.key) || (e.value is! String && e.value is! int)) {
      throw const FormatException('Invalid control extension.');
    }
  }
  return ext;
}

String _string(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is! String) throw const FormatException('Expected control string.');
  return v;
}

DateTime _date(Map<String, dynamic> m, String key) {
  final v = DateTime.tryParse(_string(m, key));
  if (v == null || !v.isUtc) {
    throw const FormatException('Expected UTC timestamp.');
  }
  return v;
}

void _identifier(String s) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(s) ||
      s.contains('..')) {
    throw const FormatException('Invalid control identifier.');
  }
}

bool _hash(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);
