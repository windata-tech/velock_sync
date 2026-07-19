import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class BatchBlobReference {
  const BatchBlobReference({
    required this.blobId,
    required this.logicalKey,
    required this.cipherSize,
    required this.cipherSha256,
    required this.chunkSize,
    this.protection = 'vlsb1',
  });

  final String blobId;
  final String logicalKey;
  final int cipherSize;
  final String cipherSha256;
  final int chunkSize;
  final String protection;
}

class GenericVaultBatchEnvelopeDraft {
  const GenericVaultBatchEnvelopeDraft({
    required this.vaultId,
    required this.sourceDeviceId,
    required this.sequence,
    required this.batchId,
    required this.keyId,
    required this.createdAt,
    required this.operationsCipherSize,
    required this.operationsCipherSha256,
    required this.operationCount,
    required this.blobs,
    this.previousBatchId,
    this.previousSequence,
  });

  final String vaultId;
  final String sourceDeviceId;
  final int sequence;
  final String batchId;
  final String keyId;
  final DateTime createdAt;
  final int operationsCipherSize;
  final String operationsCipherSha256;
  final int operationCount;
  final List<BatchBlobReference> blobs;
  final String? previousBatchId;
  final int? previousSequence;
}

class SignedBatchEnvelope {
  const SignedBatchEnvelope({
    required this.bytes,
    required this.signingPayload,
    required this.signature,
  });

  final Uint8List bytes;
  final Uint8List signingPayload;
  final Signature signature;
}

class VerifiedBatchEnvelope {
  const VerifiedBatchEnvelope({required this.draft, required this.signature});

  final GenericVaultBatchEnvelopeDraft draft;
  final Signature signature;
}

/// Builds the V1 public envelope. Cleartext file paths and operation payloads
/// are deliberately absent; they exist only inside operations.enc.
class GenericVaultBatchEnvelopeSigner {
  GenericVaultBatchEnvelopeSigner({Ed25519? algorithm})
    : _algorithm = algorithm ?? Ed25519();

  final Ed25519 _algorithm;

  Future<SignedBatchEnvelope> sign({
    required GenericVaultBatchEnvelopeDraft draft,
    required KeyPair keyPair,
  }) async {
    final signingPayload = Uint8List.fromList(utf8.encode(_canonical(draft)));
    final signature = await _algorithm.sign(signingPayload, keyPair: keyPair);
    final encodedSignature = base64UrlEncode(
      signature.bytes,
    ).replaceAll('=', '');
    final envelope = Uint8List.fromList(
      utf8.encode(_canonical(draft, signature: encodedSignature)),
    );
    return SignedBatchEnvelope(
      bytes: envelope,
      signingPayload: signingPayload,
      signature: signature,
    );
  }

  Future<bool> verify(SignedBatchEnvelope envelope) =>
      _algorithm.verify(envelope.signingPayload, signature: envelope.signature);

  /// Parses only the exact canonical V1 spelling emitted by [sign]. This keeps
  /// signature verification independent of JSON parser normalization and
  /// rejects duplicate/reordered fields before any encrypted payload is read.
  Future<VerifiedBatchEnvelope> parseAndVerify({
    required Uint8List envelope,
    required PublicKey trustedPublicKey,
  }) async {
    final source = utf8.decode(envelope, allowMalformed: false);
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Batch envelope must be a JSON object.');
    }
    if (decoded['protocol'] != 'velock-sync' ||
        decoded['protocolVersion'] != 1 ||
        decoded['signatureAlgorithm'] != 'Ed25519') {
      throw const FormatException('Unsupported batch envelope protocol.');
    }
    final signatureText = _string(decoded, 'signature');
    final draft = GenericVaultBatchEnvelopeDraft(
      vaultId: _string(decoded, 'vaultId'),
      sourceDeviceId: _string(decoded, 'sourceDeviceId'),
      sequence: _positiveInt(decoded, 'sequence'),
      batchId: _string(decoded, 'batchId'),
      keyId: _string(decoded, 'keyId'),
      createdAt: DateTime.parse(_string(decoded, 'createdAt')).toUtc(),
      operationsCipherSize: _nonNegativeInt(
        _object(decoded, 'operations'),
        'cipherSize',
      ),
      operationsCipherSha256: _string(
        _object(decoded, 'operations'),
        'cipherSha256',
      ),
      operationCount: _nonNegativeInt(
        _object(decoded, 'operations'),
        'operationCount',
      ),
      blobs: _blobs(decoded),
      previousBatchId: decoded['previousBatchId'] as String?,
      previousSequence: decoded['previousSequence'] as int?,
    );
    if ((draft.previousBatchId == null) != (draft.previousSequence == null)) {
      throw const FormatException('Invalid previous-batch linkage.');
    }
    final canonical = _canonical(draft, signature: signatureText);
    if (source != canonical) {
      throw const FormatException('Batch envelope is not canonical.');
    }
    final signature = Signature(
      _decodeBase64Url(signatureText),
      publicKey: trustedPublicKey,
    );
    final valid = await _algorithm.verify(
      Uint8List.fromList(utf8.encode(_canonical(draft))),
      signature: signature,
    );
    if (!valid) {
      throw const FormatException('Batch envelope signature is invalid.');
    }
    return VerifiedBatchEnvelope(draft: draft, signature: signature);
  }

  Uint8List commitMarker({
    required GenericVaultBatchEnvelopeDraft draft,
    required Uint8List envelope,
    required DateTime committedAt,
  }) => Uint8List.fromList(
    utf8.encode(
      '{'
      '"batchId":${jsonEncode(draft.batchId)},'
      '"committedAt":${jsonEncode(committedAt.toUtc().toIso8601String())},'
      '"envelopeSha256":"${sha256.convert(envelope)}",'
      '"sequence":${draft.sequence},'
      '"sourceDeviceId":${jsonEncode(draft.sourceDeviceId)},'
      '"vaultId":${jsonEncode(draft.vaultId)}'
      '}',
    ),
  );

  String _canonical(GenericVaultBatchEnvelopeDraft draft, {String? signature}) {
    _validate(draft);
    final blobs = [...draft.blobs]
      ..sort((a, b) => a.blobId.compareTo(b.blobId));
    final blobJson = blobs
        .map(
          (blob) =>
              '{'
              '"blobId":${jsonEncode(blob.blobId)},'
              '"chunkSize":${blob.chunkSize},'
              '"cipherSha256":${jsonEncode(blob.cipherSha256)},'
              '"cipherSize":${blob.cipherSize},'
              '"logicalKey":${jsonEncode(blob.logicalKey)},'
              '"protection":${jsonEncode(blob.protection)}'
              '}',
        )
        .join(',');
    final fields = <String>[
      '"batchId":${jsonEncode(draft.batchId)}',
      '"batchKind":"incremental"',
      '"blobs":[$blobJson]',
      '"createdAt":${jsonEncode(draft.createdAt.toUtc().toIso8601String())}',
      '"keyId":${jsonEncode(draft.keyId)}',
      '"operations":{'
          '"cipherSha256":${jsonEncode(draft.operationsCipherSha256)},'
          '"cipherSize":${draft.operationsCipherSize},'
          '"compression":"none",'
          '"logicalName":"operations.enc",'
          '"operationCount":${draft.operationCount}'
          '}',
      '"previousBatchId":${jsonEncode(draft.previousBatchId)}',
      '"previousSequence":${draft.previousSequence ?? 'null'}',
      '"protocol":"velock-sync"',
      '"protocolVersion":1',
      '"sequence":${draft.sequence}',
    ];
    if (signature != null) fields.add('"signature":${jsonEncode(signature)}');
    fields.addAll([
      '"signatureAlgorithm":"Ed25519"',
      '"sourceDeviceId":${jsonEncode(draft.sourceDeviceId)}',
      '"vaultId":${jsonEncode(draft.vaultId)}',
    ]);
    return '{${fields.join(',')}}';
  }

  void _validate(GenericVaultBatchEnvelopeDraft draft) {
    if (draft.sequence < 1 ||
        draft.operationsCipherSize < 0 ||
        draft.operationCount < 0 ||
        (draft.previousSequence == null) != (draft.previousBatchId == null)) {
      throw ArgumentError('Invalid V1 batch envelope fields.');
    }
    for (final value in [
      draft.vaultId,
      draft.sourceDeviceId,
      draft.batchId,
      draft.keyId,
    ]) {
      if (value.isEmpty) throw ArgumentError.value(value, 'identifier');
    }
  }

  List<BatchBlobReference> _blobs(Map<String, dynamic> value) {
    final raw = value['blobs'];
    if (raw is! List) throw const FormatException('Batch blobs are invalid.');
    return raw
        .map((item) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException('Batch blob is invalid.');
          }
          return BatchBlobReference(
            blobId: _string(item, 'blobId'),
            logicalKey: _string(item, 'logicalKey'),
            cipherSize: _nonNegativeInt(item, 'cipherSize'),
            cipherSha256: _string(item, 'cipherSha256'),
            chunkSize: _nonNegativeInt(item, 'chunkSize'),
            protection: _string(item, 'protection'),
          );
        })
        .toList(growable: false);
  }

  Map<String, dynamic> _object(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! Map<String, dynamic>) {
      throw FormatException('Batch envelope $key is invalid.');
    }
    return field;
  }

  String _string(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw FormatException('Batch envelope $key is invalid.');
    }
    return field;
  }

  int _positiveInt(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! int || field < 1) {
      throw FormatException('Batch envelope $key is invalid.');
    }
    return field;
  }

  int _nonNegativeInt(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! int || field < 0) {
      throw FormatException('Batch envelope $key is invalid.');
    }
    return field;
  }

  Uint8List _decodeBase64Url(String value) {
    try {
      final normalized = value.padRight((value.length + 3) ~/ 4 * 4, '=');
      return Uint8List.fromList(base64Url.decode(normalized));
    } on FormatException {
      throw const FormatException('Batch envelope signature is invalid.');
    }
  }
}
