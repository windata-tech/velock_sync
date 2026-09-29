import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_current_snapshot_transport.dart';

/// Remembers which snapshot inventories had every remote object read back.
///
/// Only an exact match counts: the key binds the backup location, snapshot ID
/// and the SHA-256 of the signed manifest and commit, so a changed or replaced
/// snapshot, or another folder, is verified in full again. Entries expire after
/// [maxAge] so objects the server loses later are still noticed.
abstract interface class VelockSnapshotVerificationRecord {
  Future<bool> isFresh(String locationScope, VelockSnapshotInventory inventory);
  Future<void> remember(
    String locationScope,
    VelockSnapshotInventory inventory,
  );
}

String velockSnapshotVerificationKey(
  String locationScope,
  VelockSnapshotInventory inventory,
) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          locationScope,
          inventory.vaultId,
          inventory.snapshotId,
          sha256.convert(inventory.manifest).toString(),
          sha256.convert(inventory.commit).toString(),
        ]),
      ),
    )
    .toString();

/// A small JSON file in Sync's private support directory.
final class FileVelockSnapshotVerificationRecord
    implements VelockSnapshotVerificationRecord {
  FileVelockSnapshotVerificationRecord(
    File file, {
    this.maxAge = const Duration(days: 30),
    DateTime Function()? now,
  }) : _locate = (() async => file),
       _now = now ?? DateTime.now;

  /// The record kept in the app's own support directory.
  FileVelockSnapshotVerificationRecord.inSupportDirectory({
    this.maxAge = const Duration(days: 30),
  }) : _locate = (() async => File(
         '${(await getApplicationSupportDirectory()).path}'
         '/velock-sync/snapshot-verified.json',
       )),
       _now = DateTime.now;

  final Future<File> Function() _locate;
  final Duration maxAge;
  final DateTime Function() _now;

  static const _maxEntries = 64;

  @override
  Future<bool> isFresh(
    String locationScope,
    VelockSnapshotInventory inventory,
  ) async {
    final verifiedAt =
        (await _read())[velockSnapshotVerificationKey(
          locationScope,
          inventory,
        )];
    if (verifiedAt == null) return false;
    final age = _now().toUtc().difference(verifiedAt);
    return !age.isNegative && age < maxAge;
  }

  @override
  Future<void> remember(
    String locationScope,
    VelockSnapshotInventory inventory,
  ) async {
    final entries = await _read();
    entries[velockSnapshotVerificationKey(locationScope, inventory)] = _now()
        .toUtc();
    final newest = entries.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final kept = {
      for (final entry in newest.take(_maxEntries))
        entry.key: entry.value.toIso8601String(),
    };
    final file = await _locate();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(kept), flush: true);
    await temporary.rename(file.path);
  }

  Future<Map<String, DateTime>> _read() async {
    try {
      final file = await _locate();
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is String &&
              DateTime.tryParse(entry.value as String) != null)
            entry.key: DateTime.parse(entry.value as String).toUtc(),
      };
    } on Object {
      // A damaged record only costs one full verification.
      return {};
    }
  }
}
