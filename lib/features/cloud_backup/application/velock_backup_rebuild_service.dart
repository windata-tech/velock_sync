import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_companion_capabilities.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_current_snapshot_transport.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_location_guard.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_recovery_transport.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control_files.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

/// Durable draft; never updates the active profile just to remember a choice.
class VelockBackupRebuildJob {
  VelockBackupRebuildJob({
    required this.original,
    required List<String> destination,
    required this.request,
  }) : destination = VelockSyncProfile.canonicalRemoteRootSegments(
         destination,
       ) {
    final p = VelockSyncProfile.fromEnvelope(original);
    if (request.operation != 'build' ||
        request.requestId != request.snapshotId ||
        request.vaultId != p.vaultId ||
        request.producerId != p.pairedProducerId ||
        request.actorDeviceId != p.pairedProducerId ||
        request.actorPublicKeyId != p.pairedProducerPublicKeyId ||
        request.exchangeBindingId != p.exchangeBindingId ||
        request.syncAppInstanceId != p.deviceId ||
        request.destinationHash !=
            destinationDigest(p.connectionId, this.destination)) {
      throw const FormatException('Rebuild job does not match request.');
    }
  }
  final SyncProfileEnvelope original;
  final List<String> destination;
  final SnapshotControlRequest request;
  Uint8List encode() => snapshotJson({
    'version': 2,
    'original': original.toJson(),
    'destination': destination,
    'request': utf8.decode(request.encode()),
  });
  static VelockBackupRebuildJob parse(List<int> bytes) {
    if (bytes.length > 65536) {
      throw const FormatException('Rebuild job too large.');
    }
    final m = jsonDecode(utf8.decode(bytes));
    if (m is! Map<String, dynamic> ||
        m.length != 4 ||
        m['version'] != 2 ||
        m['original'] is! Map<String, dynamic> ||
        m['destination'] is! List ||
        m['request'] is! String) {
      throw const FormatException('Invalid rebuild job.');
    }
    return VelockBackupRebuildJob(
      original: SyncProfileEnvelope.fromJson(
        m['original'] as Map<String, dynamic>,
      ),
      destination: (m['destination'] as List).cast<String>(),
      request: SnapshotControlRequest.parse(
        utf8.encode(m['request'] as String),
      ),
    );
  }

  static String destinationDigest(String connectionId, List<String> segments) =>
      sha256
          .convert(
            snapshotJson({'connectionId': connectionId, 'segments': segments}),
          )
          .toString();
}

/// Stores public job metadata only in Sync's private application directory.
class VelockBackupRebuildJobs {
  VelockBackupRebuildJobs(this.root);
  final Directory root;
  Future<File> _file(String profileId) async {
    snapshotIdentifier(profileId);
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('Invalid rebuild directory.');
    }
    return File('${root.path}/$profileId.json');
  }

  Future<VelockBackupRebuildJob?> read(String profileId) async {
    final file = await _file(profileId);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const FormatException('Invalid rebuild job file.');
    }
    final job = VelockBackupRebuildJob.parse(
      await readSnapshotObject(file.openRead(), 65536),
    );
    if (job.original.profileId != profileId) {
      throw const FormatException('Wrong rebuild profile.');
    }
    return job;
  }

  /// Forgets a rebuild the user abandoned. Only this local job record goes;
  /// the original location, the new folder and anything already uploaded
  /// there are untouched, so a later attempt chooses its folder afresh.
  Future<void> discard(String profileId) async {
    final file = await _file(profileId);
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await file.delete();
    }
  }

  Future<void> save(VelockBackupRebuildJob job) async {
    final file = await _file(job.original.profileId);
    final temp = await root.createTemp('.job-');
    try {
      final staged = await File(
        '${temp.path}/job.json',
      ).writeAsBytes(job.encode(), flush: true);
      await staged.rename(file.path);
    } finally {
      await temp.delete(recursive: true);
    }
  }
}

/// New-location upload transaction. Original configuration survives failed
/// consent, native staging, network, validation and late/stale results. No
/// cursor, history, account identity or old remote object is reset or removed.
class VelockBackupRebuildService {
  VelockBackupRebuildService({
    required this.database,
    required this.profiles,
    required this.adapterFactory,
    required this.jobs,
    required this.openRemote,
    required this.launchVelock,
    DateTime Function()? now,
    String Function()? nextId,
  }) : now = now ?? DateTime.now,
       nextId = nextId ?? const Uuid().v4;
  final SyncStateDatabase database;
  final SyncProfileRepository profiles;
  final VelockDatasetAdapterFactory adapterFactory;
  final VelockBackupRebuildJobs jobs;
  final Future<RemoteObjectStore> Function(
    String connectionId,
    List<String> segments,
  )
  openRemote;
  final Future<bool> Function(Uri) launchVelock;
  final DateTime Function() now;
  final String Function() nextId;

  Future<void> _unchanged(SyncProfileEnvelope expected) async {
    final current = await profiles.read(expected.profileId);
    if (current == null ||
        current.state != SyncProfileState.active ||
        sha256.convert(snapshotJson(current.toJson())) !=
            sha256.convert(snapshotJson(expected.toJson())) ||
        await database.hasRunningSyncRun(expected.profileId)) {
      throw StateError('Backup changed or is running.');
    }
  }

  Future<VelockExchangeDatasetAdapter> _adapter(
    SyncProfileEnvelope envelope,
  ) async {
    final adapter = await adapterFactory.create(
      VelockSyncProfile.fromEnvelope(envelope),
    );
    if (adapter is! VelockExchangeDatasetAdapter) {
      throw UnsupportedError('Snapshot rebuild requires the Apple exchange.');
    }
    return adapter;
  }

  Future<PublicKey> _key(VelockSyncProfile p) async {
    final keys = await database.readTrustedDevicePublicKeys(vaultId: p.vaultId);
    final bytes = keys[p.pairedProducerId];
    if (bytes == null) throw StateError('Paired signing key is unavailable.');
    return SimplePublicKey(bytes, type: KeyPairType.ed25519);
  }

  Future<VelockBackupRebuildJob> start({
    required SyncProfileEnvelope expected,
    required List<String> destination,
    required String destinationLabel,
  }) => withVelockLocationGuard(database, expected.profileId, () async {
    await _unchanged(expected);
    final p = VelockSyncProfile.fromEnvelope(expected);
    if (p.snapshotRestoreRequestId != null || p.snapshotDiscoveryPending) {
      throw StateError('Finish restoring before creating a new backup.');
    }
    final segments = VelockSyncProfile.canonicalRemoteRootSegments(destination);
    if (jsonEncode(segments) == jsonEncode(p.remoteRootSegments)) {
      throw StateError('Choose a new empty backup folder.');
    }
    final adapter = await _adapter(expected);
    // An older Velock would never answer the snapshot request.
    await VelockCompanionCapabilities.requireSupported(adapter.exchangeRoot);
    await _key(p);
    final remote = await openRemote(p.connectionId, segments);
    final page = await remote.list(limit: 1);
    if (page.items.isNotEmpty || page.nextCursor != null) {
      throw StateError('New backup folder is not empty.');
    }
    final id = nextId();
    final created = now().toUtc();
    final request = SnapshotControlRequest(
      requestId: id,
      challenge: nextId(),
      operation: 'build',
      snapshotId: id,
      vaultId: p.vaultId,
      producerId: p.pairedProducerId,
      actorDeviceId: p.pairedProducerId,
      actorPublicKeyId: p.pairedProducerPublicKeyId,
      exchangeBindingId: p.exchangeBindingId,
      syncAppInstanceId: p.deviceId,
      destinationLabel: destinationLabel,
      destinationHash: VelockBackupRebuildJob.destinationDigest(
        p.connectionId,
        segments,
      ),
      createdAt: created,
      expiresAt: created.add(const Duration(minutes: 5)),
    );
    final job = VelockBackupRebuildJob(
      original: expected,
      destination: segments,
      request: request,
    );
    await _unchanged(expected);
    await jobs.save(job);
    await SnapshotControlFiles(
      adapter.exchangeRoot,
    ).publish('SnapshotRequests', id, request.encode());
    return job;
  });

  Future<void> open(VelockBackupRebuildJob job) async {
    await _unchanged(job.original);
    await _adapter(job.original);
    job.request.assertFresh(now().toUtc());
    if (!await launchVelock(
      Uri(
        scheme: 'velock',
        host: 'sync-snapshot',
        queryParameters: {'requestId': job.request.requestId},
      ),
    )) {
      throw StateError('Could not open Velock.');
    }
  }

  Future<bool> isReady(VelockBackupRebuildJob job) async {
    await _unchanged(job.original);
    final adapter = await _adapter(job.original);
    final bytes = await SnapshotControlFiles(
      adapter.exchangeRoot,
    ).read('SnapshotReceipts', job.request.requestId);
    if (bytes == null) return false;
    await SnapshotControlReceipt.verify(
      bytes: bytes,
      request: job.request,
      trustedActorKey: await _key(VelockSyncProfile.fromEnvelope(job.original)),
    );
    return true;
  }

  Future<SyncProfileEnvelope> finish(
    VelockBackupRebuildJob job, {
    void Function(int, int)? onProgress,
  }) => withVelockLocationGuard(database, job.original.profileId, () async {
    final p = VelockSyncProfile.fromEnvelope(job.original);
    final current = await profiles.read(p.profileId);
    // A crash after saving the profile is idempotent, without repeating an old
    // request against some later configuration or changing its status.
    if (current != null) {
      final saved = VelockSyncProfile.fromEnvelope(current);
      if (saved.state == SyncProfileState.active &&
          saved.currentSnapshotId == job.request.snapshotId &&
          saved.currentSnapshotProducerId == p.pairedProducerId &&
          saved.connectionId == p.connectionId &&
          jsonEncode(saved.remoteRootSegments) == jsonEncode(job.destination)) {
        return current;
      }
    }
    await _unchanged(job.original);
    final adapter = await _adapter(job.original);
    final (inventory, source) = await _approvedInventory(job, adapter);
    final remote = await openRemote(p.connectionId, job.destination);
    await _claimNewDestination(remote, job);
    await VelockRecoveryTransport.upload(
      root: adapter.exchangeRoot,
      vaultId: p.vaultId,
      remote: remote,
    );
    await const VelockCurrentSnapshotTransport().upload(
      source: source,
      inventory: inventory,
      remote: remote,
      onProgress: onProgress,
    );
    // upload() already reads back and hashes every remote part/blob, manifest
    // and final commit against the signed inventory verified above. Do not
    // reread the same full snapshot here. A later independent sync still
    // constructs its own remote-bound baseline from fresh remote reads.
    await _adapter(
      job.original,
    ); // Revoke during a long upload must not finalize.
    await _unchanged(job.original);
    final updated = p
        .copyWith(
          remoteRootSegments: job.destination,
          locationChangedAt: now().toUtc(),
          currentSnapshotId: inventory.snapshotId,
          currentSnapshotProducerId: p.pairedProducerId,
        )
        .toEnvelope();
    await profiles.saveIfUnchanged(
      expected: job.original,
      updated: updated,
      rebuild: _completion(
        job,
        inventory,
        VelockSyncProfile.fromEnvelope(updated).locationChangedAt!,
      ),
    );
    return updated;
  });

  Future<(VelockSnapshotInventory, Directory)> _approvedInventory(
    VelockBackupRebuildJob job,
    VelockExchangeDatasetAdapter adapter,
  ) async {
    final p = VelockSyncProfile.fromEnvelope(job.original);
    final key = await _key(p);
    final files = SnapshotControlFiles(adapter.exchangeRoot);
    final bytes = await files.read('SnapshotReceipts', job.request.requestId);
    if (bytes == null) {
      throw StateError('Velock has not prepared this backup yet.');
    }
    final receipt = await SnapshotControlReceipt.verify(
      bytes: bytes,
      request: job.request,
      trustedActorKey: key,
    );
    final source = Directory(
      '${adapter.exchangeRoot.path}/Snapshots/Local/${job.request.snapshotId}',
    );
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('Missing snapshot directory.');
    }
    Future<Uint8List> local(String name, int limit) async {
      final file = File('${source.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('Invalid snapshot artifact.');
      }
      return readSnapshotObject(file.openRead(), limit);
    }

    final inventory = await VelockSnapshotInventory.verify(
      manifest: await local(
        'manifest.json',
        VelockSnapshotInventory.maxManifestBytes,
      ),
      commit: await local('commit.json', 4096),
      snapshotId: job.request.snapshotId,
      vaultId: p.vaultId,
      producerId: p.pairedProducerId,
      keyId: p.pairedProducerPublicKeyId,
      trustedSigningKey: key,
    );
    if (receipt.manifestHash != sha256.convert(inventory.manifest).toString()) {
      throw const FormatException('Snapshot differs from approved result.');
    }
    return (inventory, source);
  }

  BackupRebuildCompletion _completion(
    VelockBackupRebuildJob job,
    VelockSnapshotInventory inventory,
    DateTime completedAt, {
    bool recovered = false,
  }) => BackupRebuildCompletion(
    runId:
        'snapshot-rebuild:${job.original.profileId}:${job.request.snapshotId}',
    startedAt: job.request.createdAt,
    completedAt: completedAt,
    destination: job.request.destinationLabel,
    objectCount: inventory.objects.length + 2,
    totalBytes: inventory.totalBytes,
    recovered: recovered,
  );

  /// Repair only the old recording omission. The persisted CAS result is
  /// evidence that upload/readback succeeded; a native preparation receipt by
  /// itself is insufficient. No network call or backup mutation is performed.
  Future<void> recoverCompletedHistory(String profileId) =>
      withVelockLocationGuard(database, profileId, () async {
        final current = await profiles.read(profileId);
        final job = await jobs.read(profileId);
        if (current == null || job == null) return;
        final saved = VelockSyncProfile.fromEnvelope(current);
        final original = VelockSyncProfile.fromEnvelope(job.original);
        final completedAt = saved.locationChangedAt;
        if (completedAt == null ||
            completedAt.isBefore(job.request.createdAt) ||
            saved.state != SyncProfileState.active ||
            saved.currentSnapshotId != job.request.snapshotId ||
            saved.currentSnapshotProducerId != original.pairedProducerId) {
          return;
        }
        final expected = original
            .copyWith(
              remoteRootSegments: job.destination,
              locationChangedAt: completedAt,
              currentSnapshotId: job.request.snapshotId,
              currentSnapshotProducerId: original.pairedProducerId,
            )
            .toEnvelope();
        if (sha256.convert(snapshotJson(current.toJson())) !=
            sha256.convert(snapshotJson(expected.toJson()))) {
          return;
        }
        final runId = 'snapshot-rebuild:$profileId:${job.request.snapshotId}';
        if (await database.hasSyncRun(runId)) return;
        final adapter = await _adapter(job.original);
        final (inventory, _) = await _approvedInventory(job, adapter);
        await profiles.saveIfUnchanged(
          expected: current,
          updated: current,
          rebuild: _completion(job, inventory, completedAt, recovered: true),
        );
      });

  Future<void> _claimNewDestination(
    RemoteObjectStore remote,
    VelockBackupRebuildJob job,
  ) async {
    const key = 'velock-rebuild.json';
    final bytes = snapshotJson({
      'kind': 'velock-backup-rebuild',
      'version': 2,
      'requestSha256': job.request.digest,
    });
    if (await remote.stat(key) == null) {
      final page = await remote.list(limit: 1);
      if (page.items.isNotEmpty || page.nextCursor != null) {
        throw StateError('New backup folder changed.');
      }
      try {
        await remote.put(
          key,
          Stream.value(bytes),
          contentLength: bytes.length,
          ifAbsent: true,
        );
      } on RemoteObjectAlreadyExistsException {
        /* Verify the winner below. */
      }
    }
    final stored = await readSnapshotObject(remote.read(key), 4096);
    if (sha256.convert(stored) != sha256.convert(bytes)) {
      throw StateError('New folder belongs to another backup request.');
    }
  }
}
