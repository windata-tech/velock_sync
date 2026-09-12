import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/infrastructure/secure_storage/vault_key_store.dart';

/// A password-wrapped, portable Generic Vault root-key package.
///
/// The returned package is a bearer secret and must be shown once or carried
/// through a protected channel. It contains no cleartext root key and is never
/// written to SQLite, preferences, logs, or remote storage by this class.
class VaultRecoveryPackageCodec {
  VaultRecoveryPackageCodec({
    int iterations = _defaultIterations,
    Uint8List Function(int length)? randomBytes,
  }) : _iterations = iterations,
       _randomBytes = randomBytes ?? _secureRandomBytes {
    _validateIterations(iterations);
  }

  static const _prefix = 'VLSR1.';
  static const _aad = 'velock-sync/recovery/v1';
  static const _defaultIterations = 600000;
  static const _minimumIterations = 100000;
  static const _maximumIterations = 1000000;
  static const _saltLength = 16;
  static const _nonceLength = 12;
  static const _macLength = 16;
  static const _maximumPackageLength = 65536;
  static const _maximumTrustedDevices = 128;

  final int _iterations;
  final Uint8List Function(int length) _randomBytes;
  final AesGcm _cipher = AesGcm.with256bits();

  Future<String> create({
    required Uint8List rootKey,
    required String passphrase,
  }) async {
    _validateRecoveryRootKey(rootKey);
    _validatePassphrase(passphrase);
    return _createPayload(version: 1, payload: rootKey, passphrase: passphrase);
  }

  /// Creates an authenticated recovery bundle that transfers both the Vault
  /// root key and the local device trust anchors required to verify existing
  /// remote batches. Public keys are inside the passphrase-encrypted AEAD
  /// payload; an untrusted remote can neither replace nor add a device.
  Future<String> createBundle({
    required Uint8List rootKey,
    required String vaultId,
    required Map<String, Uint8List> trustedDevices,
    required String passphrase,
  }) async {
    _validateRecoveryRootKey(rootKey);
    _validateVaultId(vaultId);
    _validatePassphrase(passphrase);
    if (trustedDevices.isEmpty ||
        trustedDevices.length > _maximumTrustedDevices) {
      throw ArgumentError.value(trustedDevices.length, 'trustedDevices.length');
    }
    final entries = trustedDevices.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    for (final entry in entries) {
      _validateDeviceId(entry.key);
      if (entry.value.length != 32) {
        throw ArgumentError.value(
          entry.value.length,
          'trustedDevices[${entry.key}].length',
        );
      }
    }
    final payload = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'vaultId': vaultId,
          'rootKey': _base64Url(rootKey),
          'trustedDevices': [
            for (final entry in entries)
              {
                'deviceId': entry.key,
                'signingPublicKey': _base64Url(entry.value),
              },
          ],
        }),
      ),
    );
    return _createPayload(version: 2, payload: payload, passphrase: passphrase);
  }

  Future<String> _createPayload({
    required int version,
    required Uint8List payload,
    required String passphrase,
  }) async {
    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    if (salt.length != _saltLength || nonce.length != _nonceLength) {
      throw StateError('Recovery random source returned an invalid length.');
    }
    final secretKey = await _deriveKey(
      passphrase: passphrase,
      salt: salt,
      iterations: _iterations,
    );
    final box = await _cipher.encrypt(
      payload,
      secretKey: secretKey,
      nonce: nonce,
      aad: utf8.encode(_aad),
    );
    final body = <String, Object>{
      'v': version,
      'kdf': 'PBKDF2-HMAC-SHA256',
      'i': _iterations,
      's': _base64Url(salt),
      'n': _base64Url(nonce),
      'c': _base64Url(box.cipherText),
      'm': _base64Url(box.mac.bytes),
    };
    return '$_prefix${_base64Url(utf8.encode(jsonEncode(body)))}';
  }

  Future<Uint8List> restore({
    required String recoveryPackage,
    required String passphrase,
  }) async {
    final bundle = await restoreBundle(
      recoveryPackage: recoveryPackage,
      passphrase: passphrase,
    );
    return Uint8List.fromList(bundle.rootKey);
  }

  Future<VaultRecoveryBundle> restoreBundle({
    required String recoveryPackage,
    required String passphrase,
  }) async {
    _validatePassphrase(passphrase);
    final parsed = _parse(recoveryPackage);
    final secretKey = await _deriveKey(
      passphrase: passphrase,
      salt: parsed.salt,
      iterations: parsed.iterations,
    );
    try {
      final cleartext = Uint8List.fromList(
        await _cipher.decrypt(
          SecretBox(parsed.cipherText, nonce: parsed.nonce, mac: parsed.mac),
          secretKey: secretKey,
          aad: utf8.encode(_aad),
        ),
      );
      if (parsed.version == 1) {
        _validateRecoveryRootKey(cleartext);
        return VaultRecoveryBundle(rootKey: cleartext);
      }
      return _decodeBundle(cleartext);
    } on SecretBoxAuthenticationError {
      throw const VaultRecoveryPackageException();
    } on FormatException {
      throw const VaultRecoveryPackageException();
    } on ArgumentError {
      // Authenticated payloads still cross a serialization boundary. Normalize
      // validator failures so callers never need to distinguish malformed
      // bundle fields from any other invalid recovery package.
      throw const VaultRecoveryPackageException();
    }
  }

  VaultRecoveryBundle _decodeBundle(Uint8List cleartext) {
    final value = jsonDecode(utf8.decode(cleartext));
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value['v'] != 1 ||
        value['vaultId'] is! String ||
        value['rootKey'] is! String ||
        value['trustedDevices'] is! List<dynamic>) {
      throw const FormatException('Recovery trust bundle is invalid.');
    }
    final vaultId = value['vaultId'] as String;
    _validateVaultId(vaultId);
    final rootKey = _decodeBase64Url(value['rootKey'] as String);
    _validateRecoveryRootKey(rootKey);
    final values = value['trustedDevices'] as List<dynamic>;
    if (values.isEmpty || values.length > _maximumTrustedDevices) {
      throw const FormatException('Recovery trust bundle is invalid.');
    }
    final trusted = <String, Uint8List>{};
    for (final item in values) {
      if (item is! Map<String, dynamic> ||
          item.length != 2 ||
          item['deviceId'] is! String ||
          item['signingPublicKey'] is! String) {
        throw const FormatException('Recovery trust bundle is invalid.');
      }
      final deviceId = item['deviceId'] as String;
      _validateDeviceId(deviceId);
      final key = _decodeBase64Url(item['signingPublicKey'] as String);
      if (key.length != 32 || trusted.containsKey(deviceId)) {
        throw const FormatException('Recovery trust bundle is invalid.');
      }
      trusted[deviceId] = key;
    }
    return VaultRecoveryBundle(
      rootKey: rootKey,
      vaultId: vaultId,
      trustedDevices: trusted,
    );
  }

  Future<SecretKey> _deriveKey({
    required String passphrase,
    required List<int> salt,
    required int iterations,
  }) {
    return Pbkdf2.hmacSha256(
      iterations: iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: passphrase, nonce: salt);
  }

  _RecoveryPackage _parse(String value) {
    if (!value.startsWith(_prefix) || value.length > _maximumPackageLength) {
      throw const VaultRecoveryPackageException();
    }
    try {
      final decoded = jsonDecode(
        utf8.decode(_decodeBase64Url(value.substring(_prefix.length))),
      );
      if (decoded is! Map<String, dynamic> ||
          decoded.length != 7 ||
          (decoded['v'] != 1 && decoded['v'] != 2) ||
          decoded['kdf'] != 'PBKDF2-HMAC-SHA256' ||
          decoded['i'] is! int ||
          decoded['s'] is! String ||
          decoded['n'] is! String ||
          decoded['c'] is! String ||
          decoded['m'] is! String) {
        throw const VaultRecoveryPackageException();
      }
      final iterations = decoded['i'] as int;
      _validateIterations(iterations);
      final salt = _decodeBase64Url(decoded['s'] as String);
      final nonce = _decodeBase64Url(decoded['n'] as String);
      final cipherText = _decodeBase64Url(decoded['c'] as String);
      final mac = _decodeBase64Url(decoded['m'] as String);
      if (salt.length != _saltLength ||
          nonce.length != _nonceLength ||
          (decoded['v'] == 1
              ? cipherText.length != 32
              : cipherText.isEmpty || cipherText.length > 48 * 1024) ||
          mac.length != _macLength) {
        throw const VaultRecoveryPackageException();
      }
      return _RecoveryPackage(
        version: decoded['v'] as int,
        iterations: iterations,
        salt: salt,
        nonce: nonce,
        cipherText: cipherText,
        mac: Mac(mac),
      );
    } on FormatException {
      throw const VaultRecoveryPackageException();
    }
  }

  static void _validatePassphrase(String value) {
    if (value.isEmpty || value.length > 1024) {
      throw ArgumentError.value(value, 'passphrase');
    }
  }

  static void _validateRecoveryRootKey(Uint8List rootKey) {
    if (rootKey.length != 32) {
      throw ArgumentError.value(rootKey.length, 'rootKey.length', 'must be 32');
    }
  }

  static void _validateVaultId(String value) {
    if (value.isEmpty || value.length > 512 || value.contains('/')) {
      throw ArgumentError.value(value, 'vaultId');
    }
  }

  static void _validateDeviceId(String value) {
    if (value.isEmpty ||
        value.length > 512 ||
        value.contains('/') ||
        value.contains('..') ||
        value.contains('\\')) {
      throw ArgumentError.value(value, 'deviceId');
    }
  }

  static void _validateIterations(int value) {
    if (value < _minimumIterations || value > _maximumIterations) {
      throw ArgumentError.value(value, 'iterations');
    }
  }

  static String _base64Url(List<int> value) =>
      base64UrlEncode(value).replaceAll('=', '');

  static Uint8List _decodeBase64Url(String value) {
    final padding = '=' * ((4 - value.length % 4) % 4);
    return Uint8List.fromList(base64Url.decode('$value$padding'));
  }

  static Uint8List _secureRandomBytes(int length) => Uint8List.fromList(
    List<int>.generate(length, (_) => Random.secure().nextInt(256)),
  );
}

/// Keeps the package transport code separate from platform secure storage.
class GenericVaultRecoveryService {
  GenericVaultRecoveryService(
    this._keyStore, {
    VaultRecoveryPackageCodec? codec,
  }) : _codec = codec ?? VaultRecoveryPackageCodec();

  final VaultKeyStore _keyStore;
  final VaultRecoveryPackageCodec _codec;

  Future<String> export({
    required String rootKeyRef,
    required String passphrase,
  }) async {
    final rootKey = await _keyStore.readRootKey(rootKeyRef);
    if (rootKey == null) {
      throw StateError('Generic Vault root key is unavailable.');
    }
    return _codec.create(rootKey: rootKey, passphrase: passphrase);
  }

  Future<String> exportBundle({
    required String rootKeyRef,
    required String vaultId,
    required Map<String, Uint8List> trustedDevices,
    required String passphrase,
  }) async {
    final rootKey = await _keyStore.readRootKey(rootKeyRef);
    if (rootKey == null) {
      throw StateError('Generic Vault root key is unavailable.');
    }
    return _codec.createBundle(
      rootKey: rootKey,
      vaultId: vaultId,
      trustedDevices: trustedDevices,
      passphrase: passphrase,
    );
  }

  Future<String> import({
    required String recoveryPackage,
    required String passphrase,
  }) async {
    final rootKey = await _codec.restore(
      recoveryPackage: recoveryPackage,
      passphrase: passphrase,
    );
    return _keyStore.writeRootKey(rootKey);
  }

  Future<GenericVaultRecoveredMaterial> importBundle({
    required String recoveryPackage,
    required String passphrase,
    required String expectedVaultId,
  }) async {
    final bundle = await _codec.restoreBundle(
      recoveryPackage: recoveryPackage,
      passphrase: passphrase,
    );
    if (bundle.vaultId != expectedVaultId || bundle.trustedDevices.isEmpty) {
      throw const VaultRecoveryPackageException();
    }
    return GenericVaultRecoveredMaterial(
      rootKeyRef: await _keyStore.writeRootKey(bundle.rootKey),
      vaultId: bundle.vaultId!,
      trustedDevices: bundle.trustedDevices,
    );
  }
}

class VaultRecoveryBundle {
  VaultRecoveryBundle({
    required Uint8List rootKey,
    this.vaultId,
    Map<String, Uint8List> trustedDevices = const {},
  }) : rootKey = Uint8List.fromList(rootKey),
       trustedDevices = Map.unmodifiable(
         trustedDevices.map(
           (deviceId, key) => MapEntry(deviceId, Uint8List.fromList(key)),
         ),
       );

  final Uint8List rootKey;
  final String? vaultId;
  final Map<String, Uint8List> trustedDevices;
}

class GenericVaultRecoveredMaterial {
  const GenericVaultRecoveredMaterial({
    required this.rootKeyRef,
    required this.vaultId,
    required this.trustedDevices,
  });

  final String rootKeyRef;
  final String vaultId;
  final Map<String, Uint8List> trustedDevices;
}

class _RecoveryPackage {
  const _RecoveryPackage({
    required this.version,
    required this.iterations,
    required this.salt,
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  final int version;
  final int iterations;
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List cipherText;
  final Mac mac;
}

class VaultRecoveryPackageException implements Exception {
  const VaultRecoveryPackageException();
}
