import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';

class GenericVaultAcknowledgementDraft {
  const GenericVaultAcknowledgementDraft({
    required this.vaultId,
    required this.consumerDeviceId,
    required this.producerDeviceId,
    required this.appliedThroughSequence,
    required this.createdAt,
  });

  final String vaultId;
  final String consumerDeviceId;
  final String producerDeviceId;
  final int appliedThroughSequence;
  final DateTime createdAt;
}

/// Creates the signed, immutable acknowledgement artifact defined by Sync
/// Protocol V1 for generic datasets.
class GenericVaultAcknowledgementSigner {
  GenericVaultAcknowledgementSigner({Ed25519? algorithm})
    : _algorithm = algorithm ?? Ed25519();

  final Ed25519 _algorithm;

  Future<ImmutableArtifact> sign({
    required GenericVaultAcknowledgementDraft draft,
    required KeyPair signingKey,
  }) async {
    final signingPayload = Uint8List.fromList(utf8.encode(_canonical(draft)));
    final signature = await _algorithm.sign(
      signingPayload,
      keyPair: signingKey,
    );
    final encodedSignature = base64UrlEncode(
      signature.bytes,
    ).replaceAll('=', '');
    return ImmutableArtifact.fromBytes(
      Uint8List.fromList(
        utf8.encode(_canonical(draft, signature: encodedSignature)),
      ),
    );
  }

  Future<bool> verify({
    required Uint8List acknowledgement,
    required PublicKey trustedPublicKey,
  }) async {
    final source = utf8.decode(acknowledgement, allowMalformed: false);
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['protocolVersion'] != 1 ||
        decoded['signatureAlgorithm'] != 'Ed25519') {
      return false;
    }
    try {
      final draft = GenericVaultAcknowledgementDraft(
        vaultId: _string(decoded, 'vaultId'),
        consumerDeviceId: _string(decoded, 'consumerDeviceId'),
        producerDeviceId: _string(decoded, 'producerDeviceId'),
        appliedThroughSequence: _positiveInt(decoded, 'appliedThroughSequence'),
        createdAt: DateTime.parse(_string(decoded, 'createdAt')).toUtc(),
      );
      final signature = _string(decoded, 'signature');
      if (source != _canonical(draft, signature: signature)) return false;
      return _algorithm.verify(
        Uint8List.fromList(utf8.encode(_canonical(draft))),
        signature: Signature(
          _decodeBase64Url(signature),
          publicKey: trustedPublicKey,
        ),
      );
    } on FormatException {
      return false;
    }
  }

  String _canonical(
    GenericVaultAcknowledgementDraft draft, {
    String? signature,
  }) {
    _validate(draft);
    final fields = <String>[
      '"appliedThroughSequence":${draft.appliedThroughSequence}',
      '"consumerDeviceId":${jsonEncode(draft.consumerDeviceId)}',
      '"createdAt":${jsonEncode(draft.createdAt.toUtc().toIso8601String())}',
      '"producerDeviceId":${jsonEncode(draft.producerDeviceId)}',
      '"protocolVersion":1',
    ];
    if (signature != null) fields.add('"signature":${jsonEncode(signature)}');
    fields.addAll([
      '"signatureAlgorithm":"Ed25519"',
      '"vaultId":${jsonEncode(draft.vaultId)}',
    ]);
    return '{${fields.join(',')}}';
  }

  void _validate(GenericVaultAcknowledgementDraft draft) {
    if (draft.appliedThroughSequence < 1) {
      throw ArgumentError.value(
        draft.appliedThroughSequence,
        'appliedThroughSequence',
        'must be positive',
      );
    }
    for (final value in [
      draft.vaultId,
      draft.consumerDeviceId,
      draft.producerDeviceId,
    ]) {
      if (value.isEmpty) throw ArgumentError.value(value, 'identifier');
    }
  }

  String _string(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw FormatException('Acknowledgement $key is invalid.');
    }
    return field;
  }

  int _positiveInt(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! int || field < 1) {
      throw FormatException('Acknowledgement $key is invalid.');
    }
    return field;
  }

  Uint8List _decodeBase64Url(String value) {
    try {
      return Uint8List.fromList(
        base64Url.decode(value.padRight((value.length + 3) ~/ 4 * 4, '=')),
      );
    } on FormatException {
      throw const FormatException('Acknowledgement signature is invalid.');
    }
  }
}
