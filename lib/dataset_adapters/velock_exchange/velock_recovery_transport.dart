import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

/// Opaque, bounded recovery-file transport. No account secret or decrypt API.
/// Root-level names make bootstrap possible before a vault has been paired.
class VelockRecoveryTransport {
  static const prefix = 'velock-recovery-';
  static const maxBytes = 16384;
  static const maxCandidates = 32;
  static int _downloadGeneration = 0;

  static Map<String, dynamic> validate(String raw) {
    if (utf8.encode(raw).length > maxBytes) {
      throw const FormatException('Recovery file too large.');
    }
    final value = jsonDecode(raw);
    final hex = RegExp(r'^[0-9a-f]{64}$');
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    );
    if (value is! Map<String, dynamic> ||
        value['format'] != 'velock-cloud-recovery' ||
        value['version'] != 1 ||
        value['lookup'] is! String ||
        !hex.hasMatch(value['lookup'] as String) ||
        value['vaultId'] is! String ||
        !uuid.hasMatch(value['vaultId'] as String) ||
        value['keyId'] is! String ||
        !uuid.hasMatch(value['keyId'] as String) ||
        value['code'] is! String ||
        !(value['code'] as String).startsWith('VSR1-')) {
      throw const FormatException('Invalid encrypted recovery file.');
    }
    return value;
  }

  static String objectName(String raw) {
    final value = validate(raw);
    return '$prefix${value['lookup']}-${sha256.convert(utf8.encode(raw))}.json';
  }

  static Future<String> readBounded(
    RemoteObjectStore remote,
    String key,
  ) async {
    final bytes = <int>[];
    await for (final chunk in remote.read(key)) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('Recovery file too large.');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  static Future<void> upload({
    required Directory root,
    required String vaultId,
    required RemoteObjectStore remote,
  }) async {
    final file = File('${root.path}/Recovery/Outgoing/$vaultId.json');
    if (!await file.exists()) {
      throw VelockRecoveryFileRequired();
    }
    if (await file.length() > maxBytes) {
      throw const FormatException('Recovery file too large.');
    }
    final raw = await file.readAsString();
    final map = validate(raw);
    if (map['vaultId'] != vaultId) {
      throw const FormatException('Recovery vault mismatch.');
    }
    final key = objectName(raw);
    if (await remote.stat(key) == null) {
      final bytes = utf8.encode(raw);
      try {
        await remote.put(
          key,
          Stream.value(bytes),
          contentLength: bytes.length,
          ifAbsent: true,
        );
      } on RemoteObjectAlreadyExistsException {
        /* Verify concurrent publication below. */
      }
    }
    if (await readBounded(remote, key) != raw) {
      throw StateError('Cloud recovery file verification failed.');
    }
  }

  /// Commits one complete selection. Failed/empty downloads never leave a
  /// partial selection that Velock could mistake for the chosen backup.
  static Future<int> download({
    required Directory root,
    required RemoteObjectStore remote,
    bool Function()? isCurrent,
  }) async {
    final generation = ++_downloadGeneration;
    final directory = Directory('${root.path}/Recovery/Incoming');
    await directory.create(recursive: true);
    final target = File('${directory.path}/selection.json');
    if (generation != _downloadGeneration ||
        (isCurrent != null && !isCurrent())) {
      throw StateError('Recovery selection superseded.');
    }
    // This tiny local operation must not yield between the generation fence
    // and removal, or a newer selection could be deleted by an older run.
    if (target.existsSync()) target.deleteSync();
    // Every password change and every restored device adds a file, and old
    // ones are never removed. Failing once there were more than
    // [maxCandidates] blocked recovery for good; keep the newest instead.
    final candidates = <RemoteObjectMetadata>[];
    String? cursor;
    var scanned = 0;
    final cursors = <String>{};
    do {
      final page = await remote.list(cursor: cursor, limit: 100);
      scanned += page.items.length;
      if (scanned > 4096) throw StateError('Recovery directory too large.');
      for (final item in page.items) {
        if (item.isDirectory) continue;
        if (!RegExp(
          r'^velock-recovery-[0-9a-f]{64}-[0-9a-f]{64}\.json$',
        ).hasMatch(item.logicalKey)) {
          continue;
        }
        if (item.size > maxBytes) continue;
        candidates.add(item);
      }
      cursor = page.nextCursor;
      if (cursor != null && !cursors.add(cursor)) {
        throw StateError('Repeated remote page.');
      }
    } while (cursor != null);
    candidates.sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : a.logicalKey.compareTo(b.logicalKey);
    });
    final raws = <String>[];
    for (final item in candidates.take(maxCandidates)) {
      final raw = await readBounded(remote, item.logicalKey);
      if (objectName(raw) != item.logicalKey) {
        throw const FormatException('Recovery file checksum mismatch.');
      }
      raws.add(raw);
    }
    if (raws.isEmpty) {
      throw StateError(
        'No cloud recovery file. Use the old complete recovery QR, or back up once more from the original device.',
      );
    }
    final temp = File('${target.path}.${const Uuid().v4()}.tmp');
    try {
      await temp.writeAsString(
        jsonEncode({'version': 1, 'files': raws}),
        flush: true,
      );
      if (generation != _downloadGeneration ||
          (isCurrent != null && !isCurrent())) {
        throw StateError('Recovery selection superseded.');
      }
      temp.renameSync(target.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    return raws.length;
  }
}

class VelockRecoveryFileRequired extends StateError
    implements SyncFailureException {
  VelockRecoveryFileRequired() : super('Velock recovery file is not ready.');
  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'local.velock_recovery_required',
    category: SyncErrorCategory.userActionRequired,
    retryable: true,
    suggestedAction: '请先打开并解锁格间，再回到 Sync 重新备份。',
  );
}
