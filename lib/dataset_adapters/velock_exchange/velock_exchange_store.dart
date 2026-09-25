import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';

/// File-system implementation of the untrusted App Group exchange boundary.
/// It only moves opaque protocol artifacts; it never opens a Velock database,
/// reads a Vault key, or interprets business payloads.
class VelockExchangeStore {
  VelockExchangeStore(
    this.root, {
    DateTime Function()? now,
    this.leaseDuration = const Duration(minutes: 10),
  }) : _now = now ?? DateTime.now;

  final Directory root;
  final DateTime Function() _now;
  final Duration leaseDuration;

  /// Opens the dedicated Apple App Group exchange boundary. The returned store
  /// still requires callers to use protocol artifacts only; this factory never
  /// grants access to any other Velock container.
  static Future<VelockExchangeStore> fromAppleAppGroup({
    AppleExchangeRootLocator? rootLocator,
    DateTime Function()? now,
    Duration leaseDuration = const Duration(minutes: 10),
  }) async => VelockExchangeStore(
    await (rootLocator ?? AppleExchangeRootLocator()).locate(),
    now: now,
    leaseDuration: leaseDuration,
  );

  Directory get _outboxReady => Directory('${root.path}/Outbox/Ready');
  Directory get _outboxClaimed => Directory('${root.path}/Outbox/Claimed');
  Directory get _outboxReceipts => Directory('${root.path}/Outbox/Receipts');
  Directory get _inboxStaging => Directory('${root.path}/Inbox/Staging');
  Directory get _inboxReady => Directory('${root.path}/Inbox/Ready');
  Directory get _inboxReceipts => Directory('${root.path}/Inbox/Receipts');
  Directory get quarantine => Directory('${root.path}/Quarantine');

  Future<void> initialize() async {
    for (final directory in [
      _outboxReady,
      _outboxClaimed,
      _outboxReceipts,
      _inboxStaging,
      _inboxReady,
      _inboxReceipts,
      quarantine,
    ]) {
      await directory.create(recursive: true);
    }
  }

  Future<List<String>> readyOutboxIds() => _directoryIds(_outboxReady);

  /// Atomically claims the first ready package. A crash-safe lease is written
  /// only after the rename, so a concurrent sync process cannot consume it.
  ///
  /// Only packages whose envelope belongs to the requested vault and source
  /// device are claimed. The shared App Group exchange can hold packages from
  /// several Velock vaults; claiming one for another vault would fail identity
  /// validation and abort the run.
  Future<VelockClaimedOutbox?> claimNextOutbox({
    required String leaseId,
    required String vaultId,
    required String sourceDeviceId,
  }) async {
    _id(leaseId, 'leaseId');
    await initialize();
    for (final batchId in await readyOutboxIds()) {
      final ready = Directory('${_outboxReady.path}/$batchId');
      if (!await _matchesClaimIdentity(batchId, vaultId, sourceDeviceId)) {
        continue;
      }
      final claimed = Directory('${_outboxClaimed.path}/$batchId');
      try {
        await ready.rename(claimed.path);
      } on FileSystemException {
        continue; // Another process won the atomic rename race.
      }
      final expiresAt = _now().toUtc().add(leaseDuration);
      await _writeAtomic(
        File('${claimed.path}/lease.json'),
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'expiresAt': expiresAt.toIso8601String(),
              'leaseId': leaseId,
            }),
          ),
        ),
      );
      return VelockClaimedOutbox(batchId: batchId, directory: claimed);
    }
    return null;
  }

  Future<bool> _matchesClaimIdentity(
    String batchId,
    String vaultId,
    String sourceDeviceId,
  ) async {
    final envelope = File('${_outboxReady.path}/$batchId/envelope.json');
    try {
      final json = jsonDecode(await envelope.readAsString());
      return json is Map<String, dynamic> &&
          json['vaultId'] == vaultId &&
          json['sourceDeviceId'] == sourceDeviceId;
    } on Object {
      return false;
    }
  }

  /// Removes a claimed package after its receipt has been durably written.
  /// Without this cleanup the package would return to Ready after its lease
  /// expires and be re-uploaded on every later run.
  Future<void> removeClaimedOutbox(String batchId) async {
    _id(batchId, 'batchId');
    final claimed = Directory('${_outboxClaimed.path}/$batchId');
    if (await claimed.exists()) {
      await claimed.delete(recursive: true);
    }
  }

  /// Returns only expired claimed packages to Ready. A malformed or missing
  /// lease is quarantined rather than treated as safe input.
  Future<void> reclaimExpiredClaims() async {
    await initialize();
    for (final batchId in await _directoryIds(_outboxClaimed)) {
      final claimed = Directory('${_outboxClaimed.path}/$batchId');
      final lease = File('${claimed.path}/lease.json');
      try {
        final json = jsonDecode(await lease.readAsString());
        final expiresAt = DateTime.parse(
          (json as Map<String, dynamic>)['expiresAt'] as String,
        ).toUtc();
        if (_now().toUtc().isBefore(expiresAt)) continue;
        await claimed.rename('${_outboxReady.path}/$batchId');
      } on Object {
        await _quarantine(claimed, batchId);
      }
    }
  }

  Future<void> writeOutboxReceipt({
    required String batchId,
    required Uint8List receipt,
  }) async {
    _id(batchId, 'batchId');
    await initialize();
    await _writeAtomic(File('${_outboxReceipts.path}/$batchId.json'), receipt);
  }

  /// Builds an inbox package in Staging then atomically exposes it in Ready.
  /// All names are fixed protocol artifacts, never cleartext business paths.
  Future<Directory> publishInboxPackage({
    required String batchId,
    required Map<String, ImmutableArtifact> artifacts,
  }) async {
    _id(batchId, 'batchId');
    final envelope = artifacts['envelope.json'];
    if (envelope == null) {
      throw ArgumentError.value(
        artifacts,
        'artifacts',
        'must contain envelope.json',
      );
    }
    await initialize();
    final staging = Directory('${_inboxStaging.path}/$batchId.tmp');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    try {
      for (final entry in artifacts.entries) {
        _artifactName(entry.key);
        await _writeAtomicArtifact(
          File('${staging.path}/${entry.key}'),
          entry.value,
        );
      }
      // Hash the bytes actually staged, not a second opening of a source
      // that may fail or change. READY must exist before the directory becomes
      // visible to the peer, so a marker failure cannot strand a partial inbox.
      final marker = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'batchId': batchId,
            'envelopeSha256': await _sha256File(
              File('${staging.path}/envelope.json'),
            ),
            'exchangeVersion': VelockExchangeV1Contract.exchangeVersion,
            'publishedAt': _now().toUtc().toIso8601String(),
          }),
        ),
      );
      await _writeAtomic(File('${staging.path}/READY'), marker);
      final ready = Directory('${_inboxReady.path}/$batchId');
      if (await ready.exists()) {
        // A duplicate ID is idempotent only if the delivered artifacts match.
        // Keep peer-created ACKs/receipts and the original READY unchanged.
        for (final name in artifacts.keys) {
          final existing = await _inboxFile('Ready/$batchId/$name');
          if (existing == null ||
              await _sha256File(existing) !=
                  await _sha256File(File('${staging.path}/$name'))) {
            throw const FormatException('Inbox batch ID content mismatch.');
          }
        }
        // Recover an orphan produced by older versions that renamed before
        // writing READY. Only a byte-matching replay may repair that marker.
        if (!await File('${ready.path}/READY').exists()) {
          await _writeAtomic(File('${ready.path}/READY'), marker);
        }
        await staging.delete(recursive: true);
        return ready;
      }
      await staging.rename(ready.path);
      return ready;
    } on Object {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> writeInboxReceipt({
    required String batchId,
    required Uint8List receipt,
  }) async {
    _id(batchId, 'batchId');
    await initialize();
    await _writeAtomic(File('${_inboxReceipts.path}/$batchId.json'), receipt);
  }

  Future<Uint8List?> readGcCandidateManifest() async {
    final file = File('${root.path}/gc-candidates.json');
    if (!await file.exists()) return null;
    return Uint8List.fromList(await file.readAsBytes());
  }

  Future<Uint8List?> readInboxReceipt(String batchId) async {
    _id(batchId, 'batchId');
    final receipt = await _inboxFile('Receipts/$batchId.json');
    return receipt == null
        ? null
        : Uint8List.fromList(await receipt.readAsBytes());
  }

  Future<Uint8List> readInboxArtifact({
    required String batchId,
    required String relativePath,
  }) async {
    _id(batchId, 'batchId');
    _artifactName(relativePath);
    final file = await _inboxFile('Ready/$batchId/$relativePath');
    if (file == null) {
      throw StateError('Inbox artifact is missing or not a regular file.');
    }
    return Uint8List.fromList(await file.readAsBytes());
  }

  Future<List<String>> _directoryIds(Directory parent) async {
    if (!await parent.exists()) return const [];
    final ids = <String>[];
    await for (final entity in parent.list(followLinks: false)) {
      if (entity is Directory && !entity.path.endsWith('.tmp')) {
        ids.add(entity.uri.pathSegments.where((part) => part.isNotEmpty).last);
      }
    }
    ids.sort();
    return ids;
  }

  Future<void> _quarantine(Directory source, String batchId) async {
    final target = Directory(
      '${quarantine.path}/$batchId-${_now().microsecondsSinceEpoch}',
    );
    await source.rename(target.path);
  }

  Future<void> _writeAtomic(File destination, Uint8List bytes) async {
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(destination.path);
  }

  Future<void> _writeAtomicArtifact(
    File destination,
    ImmutableArtifact artifact,
  ) async {
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.tmp');
    final sink = temporary.openWrite();
    var written = 0;
    var sinkClosed = false;
    try {
      await for (final chunk in await artifact.openRead()) {
        written += chunk.length;
        if (written > artifact.length) {
          throw StateError('Exchange artifact exceeds its declared length.');
        }
        sink.add(chunk);
      }
      await sink.close();
      sinkClosed = true;
      if (written != artifact.length) {
        throw StateError('Exchange artifact length is invalid.');
      }
      await temporary.rename(destination.path);
    } on Object {
      if (!sinkClosed) await sink.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<String> _sha256File(File file) async =>
      (await sha256.bind(file.openRead()).single).toString();

  /// Checking only the final file would still follow a symlinked ACK directory
  /// (or batch/Receipts directory) outside the exchange boundary.
  Future<File?> _inboxFile(String relativePath) async {
    final parts = ['Inbox', ...relativePath.split('/')];
    var path = root.path;
    for (var index = 0; index < parts.length; index++) {
      path = '$path/${parts[index]}';
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      final expected = index == parts.length - 1
          ? FileSystemEntityType.file
          : FileSystemEntityType.directory;
      if (type != expected) {
        throw StateError('Inbox path is not a regular file or directory.');
      }
    }
    return File(path);
  }

  void _id(String value, String name) {
    if (value.isEmpty ||
        value.contains('/') ||
        value.contains('..') ||
        value.contains('\\')) {
      throw ArgumentError.value(value, name, 'must be an opaque identifier');
    }
  }

  void _artifactName(String value) {
    if (value.isEmpty ||
        value.startsWith('/') ||
        value
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(
        value,
        'artifact name',
        'must be a relative protocol path',
      );
    }
  }
}

class VelockClaimedOutbox {
  const VelockClaimedOutbox({required this.batchId, required this.directory});

  final String batchId;
  final Directory directory;
}
