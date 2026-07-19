import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

enum DeviceMembershipStatus { active, revoked }

/// The signed V1 member object. It is transport metadata only: observing one
/// remotely never grants trust without an explicit local pairing decision.
class DeviceMembershipDraft {
  const DeviceMembershipDraft({
    required this.vaultId,
    required this.deviceId,
    required this.signingPublicKey,
    required this.status,
    required this.issuedAt,
    required this.issuedByDeviceId,
    this.friendlyNameCiphertext,
  });

  final String vaultId;
  final String deviceId;
  final Uint8List signingPublicKey;
  final DeviceMembershipStatus status;
  final DateTime issuedAt;
  final String issuedByDeviceId;
  final String? friendlyNameCiphertext;
}

/// Signs and verifies canonical `members/<deviceId>.member` documents. The
/// caller must supply a public key from its existing local trust record; this
/// type deliberately cannot discover or enroll trust from remote objects.
class DeviceMembershipSigner {
  DeviceMembershipSigner({Ed25519? algorithm})
    : _algorithm = algorithm ?? Ed25519();

  final Ed25519 _algorithm;

  Future<Uint8List> sign({
    required DeviceMembershipDraft draft,
    required KeyPair issuerSigningKey,
  }) async {
    final payload = Uint8List.fromList(utf8.encode(_canonical(draft)));
    final signature = await _algorithm.sign(payload, keyPair: issuerSigningKey);
    return Uint8List.fromList(
      utf8.encode(
        _canonical(draft, issuerSignature: _base64Url(signature.bytes)),
      ),
    );
  }

  /// Returns the validated member document, or `null` if it is malformed,
  /// non-canonical, issued by another device, or has an invalid signature.
  Future<DeviceMembershipDraft?> verify({
    required Uint8List member,
    required String expectedVaultId,
    required String expectedIssuerDeviceId,
    required PublicKey trustedIssuerPublicKey,
  }) async {
    try {
      final source = utf8.decode(member, allowMalformed: false);
      final value = jsonDecode(source);
      if (value is! Map<String, dynamic> || value['protocolVersion'] != 1) {
        return null;
      }
      final draft = DeviceMembershipDraft(
        vaultId: _string(value, 'vaultId'),
        deviceId: _string(value, 'deviceId'),
        signingPublicKey: _publicKey(value),
        status: _status(value['status']),
        issuedAt: DateTime.parse(_string(value, 'issuedAt')).toUtc(),
        issuedByDeviceId: _string(value, 'issuedByDeviceId'),
        friendlyNameCiphertext: _optionalBase64Url(
          value['friendlyNameCiphertext'],
        ),
      );
      final signature = _decodeBase64Url(_string(value, 'issuerSignature'));
      if (draft.vaultId != expectedVaultId ||
          draft.issuedByDeviceId != expectedIssuerDeviceId ||
          source != _canonical(draft, issuerSignature: _base64Url(signature))) {
        return null;
      }
      final verified = await _algorithm.verify(
        Uint8List.fromList(utf8.encode(_canonical(draft))),
        signature: Signature(signature, publicKey: trustedIssuerPublicKey),
      );
      return verified ? draft : null;
    } on Object {
      return null;
    }
  }

  String _canonical(DeviceMembershipDraft draft, {String? issuerSignature}) {
    _validate(draft);
    final fields = <String>['"deviceId":${jsonEncode(draft.deviceId)}'];
    if (draft.friendlyNameCiphertext != null) {
      fields.add(
        '"friendlyNameCiphertext":${jsonEncode(draft.friendlyNameCiphertext)}',
      );
    }
    fields.addAll([
      '"issuedAt":${jsonEncode(draft.issuedAt.toUtc().toIso8601String())}',
      '"issuedByDeviceId":${jsonEncode(draft.issuedByDeviceId)}',
    ]);
    if (issuerSignature != null) {
      fields.add('"issuerSignature":${jsonEncode(issuerSignature)}');
    }
    fields.addAll([
      '"protocolVersion":1',
      '"signingPublicKey":${jsonEncode(_base64Url(draft.signingPublicKey))}',
      '"status":${jsonEncode(draft.status.name)}',
      '"vaultId":${jsonEncode(draft.vaultId)}',
    ]);
    return '{${fields.join(',')}}';
  }

  void _validate(DeviceMembershipDraft draft) {
    if (draft.signingPublicKey.length != 32) {
      throw ArgumentError.value(
        draft.signingPublicKey.length,
        'signingPublicKey.length',
        'must be 32',
      );
    }
    for (final value in [
      draft.vaultId,
      draft.deviceId,
      draft.issuedByDeviceId,
    ]) {
      if (value.isEmpty || value.contains('/') || value.contains('..')) {
        throw ArgumentError.value(value, 'membership identifier');
      }
    }
    if (draft.friendlyNameCiphertext != null) {
      _decodeBase64Url(draft.friendlyNameCiphertext!);
    }
  }

  String _string(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) throw const FormatException();
    return field;
  }

  Uint8List _publicKey(Map<String, dynamic> value) {
    final key = _decodeBase64Url(_string(value, 'signingPublicKey'));
    if (key.length != 32) throw const FormatException();
    return key;
  }

  DeviceMembershipStatus _status(Object? value) =>
      DeviceMembershipStatus.values.firstWhere(
        (status) => status.name == value,
        orElse: () => throw const FormatException(),
      );

  String? _optionalBase64Url(Object? value) {
    if (value == null) return null;
    if (value is! String || value.isEmpty) throw const FormatException();
    _decodeBase64Url(value);
    return value;
  }

  String _base64Url(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  Uint8List _decodeBase64Url(String value) {
    try {
      final padding = '=' * ((4 - value.length % 4) % 4);
      return Uint8List.fromList(base64Url.decode('$value$padding'));
    } on FormatException {
      throw const FormatException();
    }
  }
}
