import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_current_snapshot_transport.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_location_guard.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_applied_receipt.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control_files.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_trust.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

/// Bounded discovery works with flat object stores and WebDAV Depth:1 folders.
/// A discovered ID is not evidence of signature, content or successful restore.
Future<List<String>> listVelockSnapshotIds(
  RemoteObjectStore remote,
  String vaultId, {
  RemoteOperationCancellation? cancellation,
}) async {
  snapshotIdentifier(vaultId);
  final prefix = 'vaults/$vaultId/current-snapshots/';
  final ids = <String>{}, cursors = <String>{};
  String? cursor;
  var seen = 0;
  for (var page = 0; page < 100; page++) {
    final RemoteObjectPage result;
    try {
      result = await remote.list(
        prefix: prefix,
        cursor: cursor,
        limit: 1000,
        cancellation: cancellation,
      );
    } on RemoteObjectNotFoundException {
      if (page == 0) return const [];
      rethrow;
    }
    seen += result.items.length;
    if (result.items.length > 1000 || seen > 10000) {
      throw const FormatException('Snapshot discovery limit.');
    }
    for (final item in result.items) {
      if (!item.logicalKey.startsWith(prefix)) continue;
      final id = item.logicalKey.substring(prefix.length).split('/').first;
      try {
        snapshotIdentifier(id);
      } on FormatException {
        continue;
      }
      ids.add(id);
      if (ids.length > 64) {
        throw const FormatException('Too many snapshots in this folder.');
      }
    }
    cursor = result.nextCursor;
    if (cursor == null) return ids.toList()..sort();
    if (cursor.isEmpty || !cursors.add(cursor)) {
      throw const FormatException('Invalid snapshot listing cursor.');
    }
  }
  throw const FormatException('Snapshot discovery limit.');
}

/// Setup discovery only: commit+manifest structure and account/producer scope.
/// The restore service subsequently verifies local trust, signatures and bytes.
Future<bool> hasVelockSnapshotCandidate({
  required RemoteObjectStore remote,
  required String vaultId,
  required Iterable<String> allowedProducers,
  RemoteOperationCancellation? cancellation,
}) async {
  for (final id in await listVelockSnapshotIds(
    remote,
    vaultId,
    cancellation: cancellation,
  )) {
    try {
      final prefix = 'vaults/$vaultId/current-snapshots/$id/';
      final manifest = await readSnapshotObject(
        remote.read('${prefix}manifest.json', cancellation: cancellation),
        VelockSnapshotInventory.maxManifestBytes,
      );
      final commit = jsonDecode(
        utf8.decode(
          await readSnapshotObject(
            remote.read('${prefix}commit.json', cancellation: cancellation),
            4096,
          ),
        ),
      );
      final m = jsonDecode(utf8.decode(manifest));
      if (m is Map &&
          commit is Map &&
          m['kind'] == VelockSnapshotInventory.kind &&
          m['version'] == 2 &&
          m['snapshotId'] == id &&
          m['vaultId'] == vaultId &&
          allowedProducers.contains(m['producerId']) &&
          commit['kind'] == VelockSnapshotInventory.kind &&
          commit['version'] == 2 &&
          commit['snapshotId'] == id &&
          commit['vaultId'] == vaultId &&
          commit['manifestSha256'] == sha256.convert(manifest).toString()) {
        return true;
      }
    } on RemoteObjectNotFoundException {
      /* Incomplete upload is not a candidate. */
    } on FormatException {
      /* Malformed candidates cannot authorize restoration. */
    }
  }
  return false;
}

Future<Map<String, PublicKey>> trustedVelockSnapshotKeys({
  required SyncStateDatabase database,
  required VelockSyncProfile profile,
  required Directory exchangeRoot,
}) async {
  final pinned = (await database.readTrustedDevicePublicKeys(
    vaultId: profile.vaultId,
  ))[profile.pairedProducerId];
  if (pinned == null) throw StateError('Paired Velock key is unavailable.');
  final actor = SimplePublicKey(pinned, type: KeyPairType.ed25519);
  final file = File('${exchangeRoot.path}/Control/SnapshotTrust.json');
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError('Open Velock to refresh snapshot trust.');
  }
  final keys = await VelockSnapshotTrust.verify(
    bytes: await readSnapshotObject(
      file.openRead(),
      VelockSnapshotTrust.maxBytes,
    ),
    vaultId: profile.vaultId,
    keyId: profile.pairedProducerPublicKeyId,
    actorDeviceId: profile.pairedProducerId,
    exchangeBindingId: profile.exchangeBindingId,
    trustedActorKey: actor,
  );
  return {
    for (final id in profile.trustedProducerIds)
      if (keys[id] != null) id: keys[id]!,
    profile.pairedProducerId: actor,
  };
}

class VelockSnapshotApplicationRequired implements SyncFailureException {
  const VelockSnapshotApplicationRequired();
  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'local.velock_snapshot_application_required',
    category: SyncErrorCategory.userActionRequired,
    retryable: false,
    suggestedAction: '完整备份已下载。请打开格间，解锁并确认恢复；返回 Sync 后继续。',
  );
  @override
  String toString() => 'Velock must apply the downloaded full snapshot.';
}

/// Explicit restore setup plus deferred owner-signed reconciliation. Download
/// never advances a cursor; only the matching AppliedVelockSnapshot can do so.
class VelockSnapshotRecoveryService {
  VelockSnapshotRecoveryService({
    required this.database,
    required this.profiles,
    required this.adapterFactory,
    required this.openRemote,
    required this.launchVelock,
    DateTime Function()? now,
    String Function()? nextId,
  }) : now = now ?? DateTime.now,
       nextId = nextId ?? const Uuid().v4;
  final SyncStateDatabase database;
  final SyncProfileRepository profiles;
  final VelockDatasetAdapterFactory adapterFactory;
  final Future<RemoteObjectStore> Function(String, List<String>) openRemote;
  final Future<bool> Function(Uri) launchVelock;
  final DateTime Function() now;
  final String Function() nextId;

  /// A local receipt only schedules continuation. The ordinary runner must
  /// still verify its signature and materialized snapshot before advancing.
  Future<bool> hasAppliedReceipt(String profileId) async {
    final saved = await profiles.read(profileId);
    if (saved == null || saved.state != SyncProfileState.active) return false;
    final profile = VelockSyncProfile.fromEnvelope(saved);
    if (profile.snapshotRestoreRequestId == null) return false;
    final adapter = await _adapter(profile);
    return await SnapshotControlFiles(
          adapter.exchangeRoot,
        ).read('SnapshotApplied', profile.currentSnapshotId!) !=
        null;
  }

  Future<VelockExchangeDatasetAdapter> _adapter(
    VelockSyncProfile profile,
  ) async {
    final adapter = await adapterFactory.create(profile);
    if (adapter is! VelockExchangeDatasetAdapter) {
      throw UnsupportedError('Snapshot restore requires Apple exchange.');
    }
    return adapter;
  }

  Future<void> _current(SyncProfileEnvelope expected) async {
    final current = await profiles.read(expected.profileId);
    if (current == null ||
        current.state != SyncProfileState.active ||
        sha256.convert(snapshotJson(current.toJson())) !=
            sha256.convert(snapshotJson(expected.toJson())) ||
        await database.hasRunningSyncRun(expected.profileId)) {
      throw StateError('Restore profile changed or is running.');
    }
  }

  SnapshotControlRequest _request(
    VelockSyncProfile profile,
    String snapshotId,
    String producerId,
    String label,
  ) {
    final created = now().toUtc();
    return SnapshotControlRequest(
      requestId: nextId(),
      challenge: nextId(),
      operation: 'apply',
      snapshotId: snapshotId,
      vaultId: profile.vaultId,
      producerId: producerId,
      actorDeviceId: profile.pairedProducerId,
      actorPublicKeyId: profile.pairedProducerPublicKeyId,
      exchangeBindingId: profile.exchangeBindingId,
      syncAppInstanceId: profile.deviceId,
      destinationLabel: label,
      destinationHash: sha256
          .convert(
            snapshotJson({
              'connectionId': profile.connectionId,
              'segments': profile.remoteRootSegments,
            }),
          )
          .toString(),
      createdAt: created,
      expiresAt: created.add(const Duration(minutes: 5)),
    );
  }

  /// Returns false for a legacy V1-only folder; caller uses the existing runner.
  /// A committed but invalid snapshot fails, rather than pretending an empty
  /// incremental listing can restore all business data.
  Future<bool> prepare({
    required SyncProfileEnvelope expected,
    required String locationLabel,
  }) => withVelockLocationGuard(
    database,
    expected.profileId,
    () => prepareUnderLocationLease(
      expected: expected,
      locationLabel: locationLabel,
    ),
  );

  /// Internal runner entry: its destination lease spans preparation, receipt
  /// reconciliation and the ordinary run. Call [prepare] from other callers.
  Future<bool> prepareUnderLocationLease({
    required SyncProfileEnvelope expected,
    required String locationLabel,
  }) async {
    await _current(expected);
    final profile = VelockSyncProfile.fromEnvelope(expected);
    if (profile.currentSnapshotId != null) {
      return profile.snapshotRestoreRequestId != null;
    }
    final authorizedAdapter = await adapterFactory.create(profile);
    final remote = await openRemote(
      profile.connectionId,
      profile.remoteRootSegments,
    );
    final ids = await listVelockSnapshotIds(remote, profile.vaultId);
    if (ids.isEmpty) {
      await profiles.saveIfUnchanged(
        expected: expected,
        updated: profile.copyWith(snapshotDiscoveryPending: false).toEnvelope(),
      );
      return false;
    }
    if (authorizedAdapter is! VelockExchangeDatasetAdapter) {
      throw UnsupportedError('Snapshot restore requires Apple exchange.');
    }
    final adapter = authorizedAdapter;
    final keys = await trustedVelockSnapshotKeys(
      database: database,
      profile: profile,
      exchangeRoot: adapter.exchangeRoot,
    );
    final candidates = <VelockSnapshotInventory>[];
    for (final id in ids) {
      final prefix = 'vaults/${profile.vaultId}/current-snapshots/$id/';
      Uint8List commit;
      try {
        commit = await readSnapshotObject(
          remote.read('${prefix}commit.json'),
          4096,
        );
      } on RemoteObjectNotFoundException {
        continue;
      }
      final manifest = await readSnapshotObject(
        remote.read('${prefix}manifest.json'),
        VelockSnapshotInventory.maxManifestBytes,
      );
      final m = jsonDecode(utf8.decode(manifest));
      if (m is! Map || m['producerId'] is! String) {
        throw const FormatException('Invalid snapshot manifest.');
      }
      final producer = m['producerId'] as String;
      if (producer == profile.pairedProducerId || keys[producer] == null) {
        continue;
      }
      candidates.add(
        await VelockSnapshotInventory.verify(
          manifest: manifest,
          commit: commit,
          snapshotId: id,
          vaultId: profile.vaultId,
          producerId: producer,
          keyId: profile.pairedProducerPublicKeyId,
          trustedSigningKey: keys[producer]!,
        ),
      );
    }
    if (candidates.isEmpty) {
      throw StateError('No locally trusted full snapshot was found.');
    }
    candidates.sort((a, b) {
      DateTime created(VelockSnapshotInventory i) => DateTime.parse(
        (jsonDecode(utf8.decode(i.manifest)) as Map)['createdAt'] as String,
      );
      final order = created(b).compareTo(created(a));
      return order == 0 ? b.snapshotId.compareTo(a.snapshotId) : order;
    });
    final chosen = candidates.first;
    await const VelockCurrentSnapshotTransport().download(
      destinationRoot: Directory(
        '${adapter.exchangeRoot.path}/Snapshots/Incoming',
      ),
      inventory: chosen,
      remote: remote,
    );
    await _adapter(profile);
    await _current(expected);
    final request = _request(
      profile,
      chosen.snapshotId,
      chosen.producerId,
      locationLabel,
    );
    await SnapshotControlFiles(
      adapter.exchangeRoot,
    ).publish('SnapshotRequests', request.requestId, request.encode());
    final updated = profile
        .copyWith(
          snapshotDiscoveryPending: false,
          currentSnapshotId: chosen.snapshotId,
          currentSnapshotProducerId: chosen.producerId,
          snapshotRestoreRequestId: request.requestId,
        )
        .toEnvelope();
    await profiles.saveIfUnchanged(expected: expected, updated: updated);
    return true;
  }

  Future<void> open(String profileId) =>
      withVelockLocationGuard(database, profileId, () async {
        final envelope = await profiles.read(profileId);
        if (envelope == null) throw StateError('Restore profile was removed.');
        await _current(envelope);
        final profile = VelockSyncProfile.fromEnvelope(envelope);
        final requestId = profile.snapshotRestoreRequestId;
        if (requestId == null) {
          throw StateError('No snapshot restore is pending.');
        }
        final adapter = await _adapter(profile);
        final files = SnapshotControlFiles(adapter.exchangeRoot);
        final bytes = await files.read('SnapshotRequests', requestId);
        if (bytes == null) throw StateError('Restore request is unavailable.');
        var request = SnapshotControlRequest.parse(bytes);
        if (request.requestId != requestId ||
            request.actorPublicKeyId != profile.pairedProducerPublicKeyId ||
            request.exchangeBindingId != profile.exchangeBindingId ||
            request.syncAppInstanceId != profile.deviceId ||
            request.destinationHash !=
                sha256
                    .convert(
                      snapshotJson({
                        'connectionId': profile.connectionId,
                        'segments': profile.remoteRootSegments,
                      }),
                    )
                    .toString() ||
            request.snapshotId != profile.currentSnapshotId ||
            request.producerId != profile.currentSnapshotProducerId ||
            request.vaultId != profile.vaultId ||
            request.actorDeviceId != profile.pairedProducerId ||
            request.operation != 'apply') {
          throw const FormatException('Restore request mismatch.');
        }
        if (!now().toUtc().isBefore(request.expiresAt)) {
          request = _request(
            profile,
            request.snapshotId,
            request.producerId,
            request.destinationLabel,
          );
          await files.publish(
            'SnapshotRequests',
            request.requestId,
            request.encode(),
          );
          await profiles.saveIfUnchanged(
            expected: envelope,
            updated: profile
                .copyWith(snapshotRestoreRequestId: request.requestId)
                .toEnvelope(),
          );
        }
        if (!await launchVelock(
          Uri(
            scheme: 'velock',
            host: 'sync-snapshot',
            queryParameters: {'requestId': request.requestId},
          ),
        )) {
          throw StateError('Could not open Velock.');
        }
      });

  /// Called by the run service under its existing destination lease, before
  /// remote writes or incremental imports. No success state is synthesized.
  static Future<VelockSyncProfile> reconcile({
    required SyncStateDatabase database,
    required SyncProfileRepository profiles,
    required VelockSyncProfile profile,
    required VelockExchangeDatasetAdapter adapter,
  }) async {
    if (profile.snapshotRestoreRequestId == null) return profile;
    final id = profile.currentSnapshotId!,
        producer = profile.currentSnapshotProducerId!;
    final receipt = await SnapshotControlFiles(
      adapter.exchangeRoot,
    ).read('SnapshotApplied', id);
    if (receipt == null) throw const VelockSnapshotApplicationRequired();
    final keys = await trustedVelockSnapshotKeys(
      database: database,
      profile: profile,
      exchangeRoot: adapter.exchangeRoot,
    );
    final producerKey = keys[producer];
    if (producerKey == null) throw StateError('Snapshot producer was revoked.');
    final dir = Directory(
      '${adapter.exchangeRoot.path}/Snapshots/Incoming/$id',
    );
    Future<Uint8List> read(String name, int limit) async {
      final f = File('${dir.path}/$name');
      if (await FileSystemEntity.type(f.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('Invalid incoming snapshot.');
      }
      return readSnapshotObject(f.openRead(), limit);
    }

    final inventory = await VelockSnapshotInventory.verify(
      manifest: await read(
        'manifest.json',
        VelockSnapshotInventory.maxManifestBytes,
      ),
      commit: await read('commit.json', 4096),
      snapshotId: id,
      vaultId: profile.vaultId,
      producerId: producer,
      keyId: profile.pairedProducerPublicKeyId,
      trustedSigningKey: producerKey,
    );
    final proof = await AppliedVelockSnapshot.verify(
      receipt: receipt,
      inventory: inventory,
      consumerId: profile.pairedProducerId,
      trustedConsumerKey: keys[profile.pairedProducerId]!,
    );
    // Idempotent: a crash before the profile update repeats this signed receipt.
    await database.advanceAppliedSequencesFromCheckpoint(
      profileId: profile.profileId,
      coveredSequences: proof.coveredSequences,
    );
    final updated = profile.copyWith(clearSnapshotRestoreRequest: true);
    await profiles.saveIfUnchanged(
      expected: profile.toEnvelope(),
      updated: updated.toEnvelope(),
    );
    return updated;
  }
}
