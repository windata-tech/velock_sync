import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';

typedef SecureBytes = Uint8List Function(int length);

class GenericVaultBlobFormatException implements Exception {
  const GenericVaultBlobFormatException(this.message);

  final String message;

  @override
  String toString() => 'Invalid VLSB1 blob: $message';
}

/// VLSB1 AES-256-GCM chunk encryption for Generic Vault file contents.
///
/// A single caller must keep the produced artifact for retries: regenerating a
/// nonce prefix changes ciphertext and is not resumable by design.
class GenericVaultBlobCipher {
  GenericVaultBlobCipher({
    required GenericVaultKeyDeriver keyDeriver,
    required this.keyId,
    this.chunkSize = 4 * 1024 * 1024,
    SecureBytes? secureBytes,
  }) : _keyDeriver = keyDeriver,
       _secureBytes = secureBytes ?? _randomBytes {
    if (keyId.isEmpty || utf8.encode(keyId).length > 0xffff) {
      throw ArgumentError.value(keyId, 'keyId');
    }
    if (chunkSize < 1) throw ArgumentError.value(chunkSize, 'chunkSize');
  }

  final GenericVaultKeyDeriver _keyDeriver;
  final String keyId;
  final int chunkSize;
  final SecureBytes _secureBytes;
  final AesGcm _cipher = AesGcm.with256bits();

  int encryptedLengthFor(int plaintextLength) {
    if (plaintextLength < 0) {
      throw ArgumentError.value(plaintextLength, 'plaintextLength');
    }
    final chunkCount = plaintextLength == 0
        ? 0
        : (plaintextLength + chunkSize - 1) ~/ chunkSize;
    return 28 + utf8.encode(keyId).length + plaintextLength + chunkCount * 20;
  }

  Stream<List<int>> encrypt({
    required String vaultId,
    required String blobId,
    required int plaintextLength,
    required Stream<List<int>> plaintext,
  }) async* {
    _validateId(vaultId, 'vaultId');
    _validateId(blobId, 'blobId');
    if (plaintextLength < 0) {
      throw ArgumentError.value(plaintextLength, 'plaintextLength');
    }
    final noncePrefix = _secureBytes(8);
    if (noncePrefix.length != 8) {
      throw StateError('Secure byte source must return the requested length.');
    }
    yield _header(plaintextLength, noncePrefix);

    final key = SecretKey(
      _keyDeriver.blobKey(vaultId: vaultId, blobId: blobId),
    );
    final pending = BytesBuilder(copy: false);
    var emitted = 0;
    var chunkIndex = 0;
    await for (final part in plaintext) {
      pending.add(part);
      while (pending.length >= chunkSize) {
        final all = pending.takeBytes();
        final chunk = Uint8List.fromList(all.sublist(0, chunkSize));
        if (all.length > chunkSize) pending.add(all.sublist(chunkSize));
        emitted += chunk.length;
        yield await _encryptChunk(
          key: key,
          vaultId: vaultId,
          blobId: blobId,
          totalLength: plaintextLength,
          chunkIndex: chunkIndex++,
          noncePrefix: noncePrefix,
          plaintext: chunk,
        );
      }
    }
    final finalChunk = pending.takeBytes();
    if (finalChunk.isNotEmpty) {
      emitted += finalChunk.length;
      yield await _encryptChunk(
        key: key,
        vaultId: vaultId,
        blobId: blobId,
        totalLength: plaintextLength,
        chunkIndex: chunkIndex,
        noncePrefix: noncePrefix,
        plaintext: Uint8List.fromList(finalChunk),
      );
    }
    if (emitted != plaintextLength) {
      throw StateError(
        'Plaintext stream length does not match plaintextLength.',
      );
    }
  }

  Future<Uint8List> decrypt({
    required String vaultId,
    required String blobId,
    required Uint8List encrypted,
  }) async {
    _validateId(vaultId, 'vaultId');
    _validateId(blobId, 'blobId');
    final header = _parseHeader(encrypted);
    if (header.keyId != keyId) {
      throw const GenericVaultBlobFormatException('unexpected key ID');
    }
    final key = SecretKey(
      _keyDeriver.blobKey(vaultId: vaultId, blobId: blobId),
    );
    final cleartext = BytesBuilder(copy: false);
    var offset = header.headerLength;
    var index = 0;
    while (cleartext.length < header.plaintextLength) {
      if (offset + 4 > encrypted.length) {
        throw const GenericVaultBlobFormatException('truncated chunk length');
      }
      final length = _readUint32(encrypted, offset);
      offset += 4;
      if (length < 1 ||
          length > chunkSize ||
          offset + length + 16 > encrypted.length) {
        throw const GenericVaultBlobFormatException(
          'invalid or truncated chunk',
        );
      }
      final nonce = _nonce(header.noncePrefix, index);
      final box = SecretBox(
        encrypted.sublist(offset, offset + length),
        nonce: nonce,
        mac: Mac(encrypted.sublist(offset + length, offset + length + 16)),
      );
      try {
        final plain = await _cipher.decrypt(
          box,
          secretKey: key,
          aad: _aad(vaultId, blobId, index, header.plaintextLength, length),
        );
        cleartext.add(plain);
      } on SecretBoxAuthenticationError {
        throw const GenericVaultBlobFormatException(
          'chunk authentication failed',
        );
      }
      offset += length + 16;
      index++;
    }
    if (cleartext.length != header.plaintextLength ||
        offset != encrypted.length) {
      throw const GenericVaultBlobFormatException(
        'unexpected trailing or missing data',
      );
    }
    return Uint8List.fromList(cleartext.takeBytes());
  }

  Future<Uint8List> _encryptChunk({
    required SecretKey key,
    required String vaultId,
    required String blobId,
    required int totalLength,
    required int chunkIndex,
    required Uint8List noncePrefix,
    required Uint8List plaintext,
  }) async {
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: _nonce(noncePrefix, chunkIndex),
      aad: _aad(vaultId, blobId, chunkIndex, totalLength, plaintext.length),
    );
    final output = BytesBuilder(copy: false)
      ..add(_uint32(plaintext.length))
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return Uint8List.fromList(output.takeBytes());
  }

  Uint8List _header(int plaintextLength, Uint8List noncePrefix) {
    final keyIdBytes = Uint8List.fromList(utf8.encode(keyId));
    final output = BytesBuilder(copy: false)
      ..add('VLSB'.codeUnits)
      ..addByte(1)
      ..addByte(0)
      ..add(_uint32(chunkSize))
      ..add(_uint64(plaintextLength))
      ..add(noncePrefix)
      ..add(_uint16(keyIdBytes.length))
      ..add(keyIdBytes);
    return Uint8List.fromList(output.takeBytes());
  }

  _Header _parseHeader(Uint8List input) {
    if (input.length < 28 ||
        String.fromCharCodes(input.sublist(0, 4)) != 'VLSB') {
      throw const GenericVaultBlobFormatException('missing VLSB magic');
    }
    if (input[4] != 1 || input[5] != 0 || _readUint32(input, 6) != chunkSize) {
      throw const GenericVaultBlobFormatException('unsupported header');
    }
    final keyIdLength = _readUint16(input, 26);
    final headerLength = 28 + keyIdLength;
    if (headerLength > input.length) {
      throw const GenericVaultBlobFormatException('truncated key ID');
    }
    return _Header(
      plaintextLength: _readUint64(input, 10),
      noncePrefix: Uint8List.fromList(input.sublist(18, 26)),
      keyId: utf8.decode(input.sublist(28, headerLength)),
      headerLength: headerLength,
    );
  }

  Uint8List _aad(
    String vaultId,
    String blobId,
    int index,
    int total,
    int length,
  ) {
    final vault = Uint8List.fromList(utf8.encode(vaultId));
    final blob = Uint8List.fromList(utf8.encode(blobId));
    return Uint8List.fromList(
      (BytesBuilder(copy: false)
            ..add('VLSA'.codeUnits)
            ..addByte(1)
            ..add(_uint16(vault.length))
            ..add(vault)
            ..add(_uint16(blob.length))
            ..add(blob)
            ..add(_uint32(index))
            ..add(_uint64(total))
            ..add(_uint32(length)))
          .takeBytes(),
    );
  }

  Uint8List _nonce(Uint8List prefix, int index) =>
      Uint8List.fromList([...prefix, ..._uint32(index)]);

  void _validateId(String value, String name) {
    if (value.isEmpty || utf8.encode(value).length > 0xffff) {
      throw ArgumentError.value(value, name);
    }
  }
}

class _Header {
  const _Header({
    required this.plaintextLength,
    required this.noncePrefix,
    required this.keyId,
    required this.headerLength,
  });

  final int plaintextLength;
  final Uint8List noncePrefix;
  final String keyId;
  final int headerLength;
}

Uint8List _uint16(int value) {
  final output = Uint8List(2);
  output.buffer.asByteData().setUint16(0, value);
  return output;
}

Uint8List _uint32(int value) {
  final output = Uint8List(4);
  output.buffer.asByteData().setUint32(0, value);
  return output;
}

Uint8List _uint64(int value) {
  final output = Uint8List(8);
  output.buffer.asByteData().setUint64(0, value);
  return output;
}

int _readUint16(Uint8List value, int offset) =>
    value.buffer.asByteData(value.offsetInBytes).getUint16(offset);
int _readUint32(Uint8List value, int offset) =>
    value.buffer.asByteData(value.offsetInBytes).getUint32(offset);
int _readUint64(Uint8List value, int offset) =>
    value.buffer.asByteData(value.offsetInBytes).getUint64(offset);
Uint8List _randomBytes(int length) => Uint8List.fromList(
  List<int>.generate(length, (_) => Random.secure().nextInt(256)),
);
