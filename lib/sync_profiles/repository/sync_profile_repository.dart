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

  Future<void> save(SyncProfileEnvelope profile) =>
      _database.upsertSyncProfilePayload(
        profileId: profile.profileId,
        datasetId: profile.datasetId,
        targetId: profile.connectionId,
        vaultId: profile.vaultId,
        state: profile.state.name,
        payload: jsonEncode(profile.toJson()),
      );

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

  Future<void> remove(String profileId) async {
    if (await _database.hasRunningSyncRun(profileId)) {
      throw SyncProfileRemovalWhileRunningException(profileId);
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
