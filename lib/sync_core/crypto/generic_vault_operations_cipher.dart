import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';

class OperationsCipherContext {
  const OperationsCipherContext({
    required this.vaultId,
    required this.batchId,
    required this.sourceDeviceId,
    required this.sequence,
    required this.keyId,
  });

  final String vaultId;
  final String batchId;
  final String sourceDeviceId;
  final int sequence;
  final String keyId;
}

class GenericVaultOperationsFormatException implements Exception {
  const GenericVaultOperationsFormatException(this.message);

  final String message;

  @override
  String toString() => 'Invalid VLSO operations artifact: $message';
}

/// AES-256-GCM codec for operations.enc. All business data stays in the
/// ciphertext; the authenticated header contains only protocol routing data.
class GenericVaultOperationsCipher {
  GenericVaultOperationsCipher({
    required GenericVaultKeyDeriver keyDeriver,
    List<int> Function(int length)? secureBytes,
  }) : _keyDeriver = keyDeriver,
       _secureBytes = secureBytes ?? _randomBytes;

  final GenericVaultKeyDeriver _keyDeriver;
  final List<int> Function(int length) _secureBytes;
  final AesGcm _cipher = AesGcm.with256bits();

  Future<Uint8List> encrypt({
    required OperationsCipherContext context,
    required Uint8List plaintext,
  }) async {
    final header = _header(context);
    final nonce = _secureBytes(12);
    if (nonce.length != 12) {
      throw StateError('Secure byte source must return 12 bytes.');
    }
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: SecretKey(_keyDeriver.metadataKey(context.vaultId)),
      nonce: nonce,
      aad: header,
    );
    return Uint8List.fromList([
      ...'VLSO'.codeUnits,
      1,
      0,
      ..._uint16(header.length),
      ...header,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  Future<Uint8List> decrypt({
    required OperationsCipherContext context,
    required Uint8List encrypted,
  }) async {
    if (encrypted.length < 8 + 12 + 16 ||
        String.fromCharCodes(encrypted.sublist(0, 4)) != 'VLSO' ||
        encrypted[4] != 1 ||
        encrypted[5] != 0) {
      throw const GenericVaultOperationsFormatException('unsupported header');
    }
    final headerLength = _readUint16(encrypted, 6);
    final bodyOffset = 8 + headerLength;
    if (bodyOffset + 28 > encrypted.length) {
      throw const GenericVaultOperationsFormatException('truncated artifact');
    }
    final header = encrypted.sublist(8, bodyOffset);
    if (!_bytesEqual(header, _header(context))) {
      throw const GenericVaultOperationsFormatException(
        'context does not match header',
      );
    }
    final cipherTextEnd = encrypted.length - 16;
    try {
      final plaintext = await _cipher.decrypt(
        SecretBox(
          encrypted.sublist(bodyOffset + 12, cipherTextEnd),
          nonce: encrypted.sublist(bodyOffset, bodyOffset + 12),
          mac: Mac(encrypted.sublist(cipherTextEnd)),
        ),
        secretKey: SecretKey(_keyDeriver.metadataKey(context.vaultId)),
        aad: header,
      );
      return Uint8List.fromList(plaintext);
    } on SecretBoxAuthenticationError {
      throw const GenericVaultOperationsFormatException(
        'authentication failed',
      );
    }
  }

  Uint8List _header(OperationsCipherContext context) {
    _validateContext(context);
    // These fields are ASCII opaque identifiers and decimal integers. The
    // lexicographic key order and compact spelling are JCS-equivalent here.
    final json =
        '{'
        '"batchId":${jsonEncode(context.batchId)},'
        '"compression":"none",'
        '"keyId":${jsonEncode(context.keyId)},'
        '"sequence":${context.sequence},'
        '"sourceDeviceId":${jsonEncode(context.sourceDeviceId)},'
        '"vaultId":${jsonEncode(context.vaultId)}'
        '}';
    final header = Uint8List.fromList(utf8.encode(json));
    if (header.length > 0xffff) {
      throw ArgumentError.value(header.length, 'header.length');
    }
    return header;
  }

  void _validateContext(OperationsCipherContext context) {
    if (context.sequence < 1) {
      throw ArgumentError.value(context.sequence, 'sequence');
    }
    for (final value in [
      context.vaultId,
      context.batchId,
      context.sourceDeviceId,
      context.keyId,
    ]) {
      if (value.isEmpty || value.codeUnits.any((unit) => unit > 0x7f)) {
        throw ArgumentError.value(value, 'context identifier');
      }
    }
  }
}

Uint8List _uint16(int value) {
  final output = Uint8List(2);
  output.buffer.asByteData().setUint16(0, value);
  return output;
}

int _readUint16(Uint8List value, int offset) =>
    value.buffer.asByteData(value.offsetInBytes).getUint16(offset);

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

List<int> _randomBytes(int length) =>
    List<int>.generate(length, (_) => Random.secure().nextInt(256));
