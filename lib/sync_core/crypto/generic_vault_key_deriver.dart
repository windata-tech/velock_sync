import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// RFC 5869 HKDF-SHA256 derivation for the VLS1 Generic Vault suite.
///
/// This class only derives short-lived working keys. It neither persists nor
/// serializes the supplied Vault Root Key.
class GenericVaultKeyDeriver {
  GenericVaultKeyDeriver(Uint8List rootKey)
    : _rootKey = Uint8List.fromList(rootKey) {
    if (rootKey.length != 32) {
      throw ArgumentError.value(rootKey.length, 'rootKey.length', 'must be 32');
    }
  }

  final Uint8List _rootKey;

  Uint8List metadataKey(String vaultId) => derive(
    salt: utf8.encode(vaultId),
    info: utf8.encode('velock-sync/v1/metadata'),
  );

  Uint8List blobRootKey(String vaultId) => derive(
    salt: utf8.encode(vaultId),
    info: utf8.encode('velock-sync/v1/blob-root'),
  );

  Uint8List identifierKey(String vaultId) => derive(
    salt: utf8.encode(vaultId),
    info: utf8.encode('velock-sync/v1/identifier'),
  );

  Uint8List blobKey({required String vaultId, required String blobId}) {
    if (blobId.isEmpty) throw ArgumentError.value(blobId, 'blobId');
    final root = blobRootKey(vaultId);
    return hkdfSha256(
      inputKeyMaterial: root,
      salt: utf8.encode(vaultId),
      info: utf8.encode('velock-sync/v1/blob/$blobId'),
      length: 32,
    );
  }

  Uint8List derive({
    required List<int> salt,
    required List<int> info,
    int length = 32,
  }) => hkdfSha256(
    inputKeyMaterial: _rootKey,
    salt: salt,
    info: info,
    length: length,
  );

  /// Generic RFC 5869 HKDF-SHA256, also exposed for protocol test vectors.
  static Uint8List hkdfSha256({
    required List<int> inputKeyMaterial,
    required List<int> salt,
    required List<int> info,
    required int length,
  }) {
    if (salt.isEmpty) throw ArgumentError.value(salt, 'salt');
    if (length < 1 || length > 255 * 32) {
      throw ArgumentError.value(length, 'length');
    }
    final prk = Hmac(sha256, salt).convert(inputKeyMaterial).bytes;
    final output = BytesBuilder(copy: false);
    var previous = <int>[];
    for (var counter = 1; output.length < length; counter++) {
      previous = Hmac(
        sha256,
        prk,
      ).convert(<int>[...previous, ...info, counter]).bytes;
      output.add(previous);
    }
    return Uint8List.fromList(output.takeBytes().sublist(0, length));
  }
}
