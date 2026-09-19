/// Trusted device membership: public keys and revocation.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

final class DeviceQueries {
  const DeviceQueries(this.db);

  final Database db;

  /// Records a device only after an explicit local pairing/approval flow. This
  /// API intentionally never reads a remote member object or auto-enrolls it.
  Future<void> trustDevice({
    required String vaultId,
    required String deviceId,
    required Uint8List signingPublicKey,
  }) async {
    if (vaultId.isEmpty || deviceId.isEmpty || signingPublicKey.length != 32) {
      throw ArgumentError('Invalid trusted device identity.');
    }
    db.execute(
      'INSERT INTO devices (device_id, vault_id, payload_json, updated_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(device_id) DO UPDATE SET vault_id = excluded.vault_id, payload_json = excluded.payload_json, updated_at = excluded.updated_at',
      [
        deviceId,
        vaultId,
        jsonEncode({
          'status': 'active',
          'signingPublicKey': base64UrlEncode(
            signingPublicKey,
          ).replaceAll('=', ''),
        }),
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  Future<void> revokeTrustedDevice({
    required String vaultId,
    required String deviceId,
  }) async {
    db.execute(
      'UPDATE devices SET payload_json = ?, updated_at = ? WHERE device_id = ? AND vault_id = ?',
      [
        jsonEncode({'status': 'revoked'}),
        DateTime.now().toUtc().millisecondsSinceEpoch,
        deviceId,
        vaultId,
      ],
    );
  }

  Future<Map<String, Uint8List>> readTrustedDevicePublicKeys({
    required String vaultId,
  }) async {
    final rows = db.select(
      'SELECT device_id, payload_json FROM devices WHERE vault_id = ?',
      [vaultId],
    );
    final trusted = <String, Uint8List>{};
    for (final row in rows) {
      final payload = jsonDecode(row['payload_json']! as String);
      if (payload is! Map<String, dynamic> || payload['status'] != 'active') {
        continue;
      }
      final encoded = payload['signingPublicKey'];
      if (encoded is! String) continue;
      try {
        final padding = '=' * ((4 - encoded.length % 4) % 4);
        final key = Uint8List.fromList(base64Url.decode('$encoded$padding'));
        if (key.length == 32) trusted[row['device_id']! as String] = key;
      } on FormatException {
        // Corrupt local records are not trusted; pairing must repair them.
      }
    }
    return Map.unmodifiable(trusted);
  }
}
