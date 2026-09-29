import 'package:velock_sync/dataset_adapters/velock_exchange/velock_location_guard.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'dart:convert';

import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

class SyncProfileRemovalWhileRunningException implements Exception {
  const SyncProfileRemovalWhileRunningException(this.profileId);

  final String profileId;
}

/// Reads every V1 profile from the existing durable profile table.
///
/// Decode failures are deliberately isolated: a profile written by a newer app
/// remains durable and visible as unavailable, while profiles it does not
/// affect continue to start normally.
class SyncProfileRepository {
  SyncProfileRepository(this._database);

  final SyncStateDatabase _database;

  Object get executionScopeKey => _database.executionScopeKey;

  Future<void> save(SyncProfileEnvelope profile) =>
      _database.upsertSyncProfilePayload(
        profileId: profile.profileId,
        datasetId: profile.datasetId,
        targetId: profile.connectionId,
        vaultId: profile.vaultId,
        state: profile.state.name,
        payload: jsonEncode(profile.toJson()),
      );

  Future<void> saveIfUnchanged({
    BackupRebuildCompletion? rebuild,
    required SyncProfileEnvelope expected,
    required SyncProfileEnvelope updated,
  }) async {
    if (expected.profileId != updated.profileId ||
        !await _database.replaceSyncProfilePayloadIfCurrent(
          rebuild: rebuild,
          profileId: expected.profileId,
          expectedPayload: jsonEncode(expected.toJson()),
          datasetId: updated.datasetId,
          targetId: updated.connectionId,
          vaultId: updated.vaultId,
          state: updated.state.name,
          payload: jsonEncode(updated.toJson()),
        )) {
      throw StateError('Backup changed before the update could be saved.');
    }
  }

  /// Explicit user-confirmed relocation only. Keeps all trust/cursors/history;
  /// never edits the shared connection or claims that the new folder is valid.
  Future<SyncProfileEnvelope> selectOriginalVelockFolder({
    required SyncProfileEnvelope expected,
    required List<String> segments,
  }) => withVelockLocationGuard(_database, expected.profileId, () async {
    final current = await read(expected.profileId);
    if (current == null ||
        current.state != SyncProfileState.active ||
        jsonEncode(current.toJson()) != jsonEncode(expected.toJson()) ||
        await _database.hasRunningSyncRun(expected.profileId)) {
      throw StateError('Backup changed or is running. Reopen and try again.');
    }
    final updated = VelockSyncProfile.fromEnvelope(current)
        .copyWith(
          remoteRootSegments: segments,
          locationChangedAt: DateTime.now().toUtc(),
        )
        .toEnvelope();
    await saveIfUnchanged(expected: current, updated: updated);
    return updated;
  });

  Future<SyncProfileEnvelope?> read(String profileId) async {
    final record = await _database.readVisibleSyncProfilePayload(profileId);
    if (record == null) return null;
    return _decode(record);
  }

  Future<List<SyncProfileSummary>> listSummaries({
    SyncDatasetKind? kind,
    SyncProfileState? state,
    bool? backgroundEnabled,
  }) async {
    final summaries = <SyncProfileSummary>[];
    for (final record in await _database.readVisibleSyncProfilePayloads()) {
      final summary = await _summaryFor(record);
      if (kind != null && summary.kind != kind) continue;
      if (state != null && summary.state != state) continue;
      if (backgroundEnabled != null &&
          summary.backgroundPolicy.enabled != backgroundEnabled) {
        continue;
      }
      summaries.add(summary);
    }
    return summaries;
  }

  Future<List<SyncProfileSummary>> listBackgroundEligible() async =>
      (await listSummaries())
          .where((summary) => summary.isBackgroundEligible)
          .toList(growable: false);

  Future<void> setState(String profileId, SyncProfileState state) =>
      _database.setSyncProfileState(profileId: profileId, state: state.name);

  /// [forceRunning] is reserved for an explicit local removal after the
  /// profile's dataset capability has been confirmed unavailable. It closes
  /// interrupted runs so a removed profile cannot remain permanently locked.
  Future<void> remove(String profileId, {bool forceRunning = false}) async {
    if (!forceRunning && await _database.hasRunningSyncRun(profileId)) {
      throw SyncProfileRemovalWhileRunningException(profileId);
    }
    if (forceRunning) {
      await _database.failRunningSyncRunsForProfile(
        profileId: profileId,
        errorCode: 'profile_removed',
      );
    }
    await _database.setSyncProfileState(profileId: profileId, state: 'removed');
  }

  Future<SyncProfileEnvelope> _decode(SyncProfilePayloadRecord record) async {
    final decoded = jsonDecode(record.payload);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Sync profile payload is invalid.');
    }
    final envelope = SyncProfileEnvelope.fromJson(decoded);
    if (envelope.profileId != record.profileId) {
      throw const FormatException('Sync profile identity is invalid.');
    }
    final persistedState = SyncProfileState.tryParse(record.state);
    if (persistedState == null) {
      throw const FormatException('Sync profile state is invalid.');
    }
    return envelope.copyWith(state: persistedState);
  }

  Future<SyncProfileSummary> _summaryFor(
    SyncProfilePayloadRecord record,
  ) async {
    try {
      final profile = await _decode(record);
      return SyncProfileSummary(
        profileId: profile.profileId,
        kind: profile.kind,
        state: profile.state,
        datasetId: profile.datasetId,
        vaultId: profile.vaultId,
        deviceId: profile.deviceId,
        displayName: profile.displayName,
        connectionId: profile.connectionId,
        backgroundPolicy: profile.backgroundPolicy,
        locationChangedAt: profile.kind == SyncDatasetKind.velockManaged
            ? VelockSyncProfile.locationChangedAtFromEnvelope(profile)
            : null,
        activity: await _database.readSyncProfileActivity(profile.profileId),
      );
    } on Object catch (error) {
      return SyncProfileSummary(
        profileId: record.profileId,
        state:
            SyncProfileState.tryParse(record.state) ?? SyncProfileState.error,
        backgroundPolicy: const SyncProfileBackgroundPolicy(),
        isolationReason: _isolationReason(error),
      );
    }
  }

  String _isolationReason(Object error) => switch (error) {
    UnsupportedSyncProfileEnvelopeException() => 'unsupported',
    FormatException() => 'invalid',
    _ => 'unavailable',
  };
}
