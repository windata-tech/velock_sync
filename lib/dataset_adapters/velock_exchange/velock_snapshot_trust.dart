import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Public producer keys attested by the locally paired Velock owner. Remote
/// membership files never establish trust. Kept identical in both apps.
class VelockSnapshotTrust {
  static const maxBytes = 256 * 1024;
  static Future<Uint8List> sign({
    required String vaultId,
    required String keyId,
    required String actorDeviceId,
    required String exchangeBindingId,
    required Map<String, String> activeProducerKeys,
    required DateTime now,
    required KeyPair signingKey,
  }) async {
    _members(activeProducerKeys);
    final body = <String, Object>{
      'kind': 'velock-snapshot-trust',
      'version': 2,
      'vaultId': vaultId,
      'keyId': keyId,
      'actorDeviceId': actorDeviceId,
      'exchangeBindingId': exchangeBindingId,
      'publishedAt': now.toUtc().toIso8601String(),
      'members': activeProducerKeys,
    };
    final sig = await Ed25519().sign(_payload(body), keyPair: signingKey);
    final encoded = _encode({...body, 'signature': base64UrlEncode(sig.bytes)});
    if (encoded.length > maxBytes) {
      throw const FormatException('Snapshot trust size limit.');
    }
    return encoded;
  }

  static Future<Map<String, PublicKey>> verify({
    required List<int> bytes,
    required String vaultId,
    required String keyId,
    required String actorDeviceId,
    required String exchangeBindingId,
    required PublicKey trustedActorKey,
  }) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Snapshot trust size limit.');
    }
    final m = jsonDecode(utf8.decode(bytes));
    const keys = {
      'kind',
      'version',
      'vaultId',
      'keyId',
      'actorDeviceId',
      'exchangeBindingId',
      'publishedAt',
      'members',
      'signature',
    };
    // Other keys are extensions: signed and canonical like the rest.
    if (m is! Map<String, dynamic> ||
        !m.keys.toSet().containsAll(keys) ||
        m['kind'] != 'velock-snapshot-trust' ||
        m['version'] != 2 ||
        m['vaultId'] != vaultId ||
        m['keyId'] != keyId ||
        m['actorDeviceId'] != actorDeviceId ||
        m['exchangeBindingId'] != exchangeBindingId ||
        m['signature'] is! String ||
        m['publishedAt'] is! String ||
        DateTime.tryParse(m['publishedAt'] as String)?.isUtc != true) {
      throw const FormatException('Snapshot trust binding mismatch.');
    }
    final members = _members(m['members']);
    final canonical = _encode(m);
    if (canonical.length != bytes.length) {
      throw const FormatException('Noncanonical snapshot trust.');
    }
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != canonical[i]) {
        throw const FormatException('Noncanonical snapshot trust.');
      }
    }
    final body = Map<String, Object?>.from(m)..remove('signature');
    final signature = base64Url.decode(m['signature'] as String);
    if (signature.length != 64 ||
        !await Ed25519().verify(
          _payload(body),
          signature: Signature(signature, publicKey: trustedActorKey),
        )) {
      throw const FormatException('Snapshot trust signature invalid.');
    }
    return Map.unmodifiable(members);
  }

  static Map<String, PublicKey> _members(Object? value) {
    if (value is! Map || value.isEmpty || value.length > 1000) {
      throw const FormatException('Invalid snapshot member list.');
    }
    final result = <String, PublicKey>{};
    for (final e in value.entries) {
      if (e.key is! String ||
          !RegExp(
            r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
          ).hasMatch(e.key as String) ||
          (e.key as String).contains('..') ||
          e.value is! String) {
        throw const FormatException('Invalid snapshot member.');
      }
      final key = base64Url.decode(e.value as String);
      if (key.length != 32 || base64UrlEncode(key) != e.value) {
        throw const FormatException('Invalid snapshot member key.');
      }
      result[e.key as String] = SimplePublicKey(key, type: KeyPairType.ed25519);
    }
    return result;
  }

  static List<int> _payload(Map<String, Object?> body) => [
    ...utf8.encode('VelockSnapshotTrust/2\n'),
    ..._encode(body),
  ];
  static Uint8List _encode(Map<String, Object?> body) {
    final keys = body.keys.toList()..sort();
    final members = body['members'] as Map;
    final ids = members.keys.cast<String>().toList()..sort();
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          for (final k in keys)
            k: k == 'members'
                ? {for (final id in ids) id: members[id]}
                : body[k],
        }),
      ),
    );
  }
}
