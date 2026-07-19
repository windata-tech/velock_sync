import 'dart:convert';
import 'dart:typed_data';

import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';

class VaultProtocolDocument {
  const VaultProtocolDocument({
    required this.vaultId,
    required this.createdAt,
    this.minimumReaderVersion = 1,
    this.minimumWriterVersion = 1,
    this.cryptoSuite = 'VLS1-A256GCM-HKDFSHA256-ED25519',
  });

  final String vaultId;
  final DateTime createdAt;
  final int minimumReaderVersion;
  final int minimumWriterVersion;
  final String cryptoSuite;

  Uint8List encode() {
    _validate();
    return Uint8List.fromList(
      utf8.encode(
        '{'
        '"createdAt":${jsonEncode(createdAt.toUtc().toIso8601String())},'
        '"cryptoSuite":${jsonEncode(cryptoSuite)},'
        '"minimumReaderVersion":$minimumReaderVersion,'
        '"minimumWriterVersion":$minimumWriterVersion,'
        '"protocol":"velock-sync",'
        '"protocolVersion":1,'
        '"vaultId":${jsonEncode(vaultId)}'
        '}',
      ),
    );
  }

  static VaultProtocolDocument parse(Uint8List bytes) {
    final source = utf8.decode(bytes, allowMalformed: false);
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic> ||
        value['protocol'] != 'velock-sync' ||
        value['protocolVersion'] != 1) {
      throw const FormatException('Unsupported vault protocol document.');
    }
    try {
      final document = VaultProtocolDocument(
        vaultId: _string(value, 'vaultId'),
        createdAt: DateTime.parse(_string(value, 'createdAt')).toUtc(),
        minimumReaderVersion: _positiveInt(value, 'minimumReaderVersion'),
        minimumWriterVersion: _positiveInt(value, 'minimumWriterVersion'),
        cryptoSuite: _string(value, 'cryptoSuite'),
      );
      if (source != utf8.decode(document.encode())) {
        throw const FormatException(
          'Vault protocol document is not canonical.',
        );
      }
      return document;
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Vault protocol document is invalid.');
    }
  }

  void _validate() {
    if (vaultId.isEmpty ||
        minimumReaderVersion < 1 ||
        minimumWriterVersion < 1 ||
        cryptoSuite.isEmpty) {
      throw ArgumentError('Invalid vault protocol document.');
    }
  }

  static String _string(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw FormatException('Invalid $key');
    }
    return field;
  }

  static int _positiveInt(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! int || field < 1) {
      throw FormatException('Invalid $key');
    }
    return field;
  }
}

/// Creates a V1 discovery object exactly once or validates the existing one
/// against the locally pinned vault identity. It intentionally establishes no
/// device trust: membership is a separate pairing concern.
class VaultProtocolBootstrapper {
  Future<void> ensure({
    required RemoteObjectStore remote,
    required VaultProtocolDocument expected,
  }) async {
    final key = LogicalKeys.protocol(expected.vaultId);
    final current = await remote.stat(key);
    if (current == null) {
      final bytes = expected.encode();
      try {
        await remote.put(
          key,
          Stream.value(bytes),
          contentLength: bytes.length,
          ifAbsent: true,
        );
        return;
      } on RemoteObjectAlreadyExistsException {
        // A concurrent initializer won the immutable create race; validate it.
      }
    }
    final bytes = await _read(remote, key);
    final found = VaultProtocolDocument.parse(bytes);
    if (found.vaultId != expected.vaultId ||
        found.minimumReaderVersion > 1 ||
        found.minimumWriterVersion > 1 ||
        found.cryptoSuite != expected.cryptoSuite) {
      throw StateError(
        'Remote vault protocol is incompatible with this vault.',
      );
    }
  }

  Future<Uint8List> _read(RemoteObjectStore remote, String key) async {
    final data = BytesBuilder(copy: false);
    await for (final chunk in remote.read(key)) {
      data.add(chunk);
    }
    return data.takeBytes();
  }
}
