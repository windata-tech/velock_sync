import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';

/// Moves signed join requests between the shared control folder and the vault.
///
/// Velock (the trusting authority) writes `Control/JoinRequests/*.json` into
/// the shared exchange folder. Sync only transports those opaque, signed
/// artifacts: it uploads local requests so peers can approve them, and copies
/// remote requests back into the shared folder so the local Velock app can show
/// a pending approval. It never grants trust itself.
class JoinRequestTransport {
  const JoinRequestTransport(this.exchangeRoot);

  final Directory exchangeRoot;

  Directory get localRequests =>
      Directory('${exchangeRoot.path}/Control/JoinRequests');

  /// Uploads every locally published join request. Failures are ignored so a
  /// malformed artifact can never break an unrelated sync run.
  Future<int> uploadLocal({
    required String vaultId,
    required RemoteObjectStore remote,
  }) async {
    if (!await localRequests.exists()) return 0;
    var uploaded = 0;
    await for (final entity in localRequests.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final deviceId = _fileNameDeviceId(entity);
      if (deviceId == null) continue;
      try {
        final bytes = await entity.readAsBytes();
        if (bytes.isEmpty) continue;
        await remote.put(
          LogicalKeys.joinRequest(vaultId, deviceId),
          Stream.value(bytes),
          contentLength: bytes.length,
        );
        uploaded += 1;
      } on Object {
        continue;
      }
    }
    return uploaded;
  }

  /// Copies remote join requests into the shared control folder.
  Future<int> downloadRemote({
    required String vaultId,
    required RemoteObjectStore remote,
  }) async {
    final prefix = 'velock-sync/v1/$vaultId/join-requests/';
    var downloaded = 0;
    String? cursor;
    do {
      final page = await remote.list(prefix: prefix, cursor: cursor);
      for (final item in page.items) {
        final key = item.logicalKey;
        if (!key.startsWith(prefix) || !key.endsWith('.json')) continue;
        final deviceId = _deviceIdFromKey(key, prefix);
        if (deviceId == null) continue;
        try {
          final bytes = await _readAll(remote.read(key));
          if (bytes.isEmpty) continue;
          // Only transport well-formed JSON with a matching device id; the
          // signature itself is verified by the Velock app at approval time.
          if (!_looksLikeJoinRequest(bytes, deviceId)) continue;
          await _writeAtomic(localRequests, deviceId, bytes);
          downloaded += 1;
        } on Object {
          continue;
        }
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    return downloaded;
  }

  Future<void> _writeAtomic(
    Directory directory,
    String deviceId,
    Uint8List bytes,
  ) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/$deviceId.json');
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }

  String? _fileNameDeviceId(File file) {
    final name = file.uri.pathSegments.last;
    if (!name.endsWith('.json')) return null;
    final deviceId = name.substring(0, name.length - '.json'.length);
    return _canonicalId(deviceId) ? deviceId : null;
  }

  String? _deviceIdFromKey(String key, String prefix) {
    final remainder = key.substring(prefix.length);
    if (!remainder.endsWith('.json') || remainder.contains('/')) return null;
    final deviceId = remainder.substring(0, remainder.length - '.json'.length);
    return _canonicalId(deviceId) ? deviceId : null;
  }

  bool _looksLikeJoinRequest(Uint8List bytes, String deviceId) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map<String, dynamic>) return false;
      return decoded['deviceId'] == deviceId &&
          decoded['version'] is int &&
          decoded['signature'] is String &&
          decoded['signingPublicKey'] is String &&
          decoded['vaultId'] is String;
    } on Object {
      return false;
    }
  }

  bool _canonicalId(String value) => RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(value);

  Future<Uint8List> _readAll(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
