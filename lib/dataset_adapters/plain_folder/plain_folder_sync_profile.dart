import 'dart:convert';

import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart'
    show defaultBackgroundCellularMaxTransferBytes;
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_location_guard.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/remote_root_segments.dart'
    as remote_root_segments;
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

enum PlainFolderProfileState { active, paused }

/// Non-secret configuration of one plain folder sync location.
///
/// A location binds one user-authorized local folder to one remote folder on
/// one connection. Nothing here is encrypted and no key material is involved:
/// the remote folder holds the user's real files under their real names.
class PlainFolderSyncProfile {
  const PlainFolderSyncProfile({
    required this.profileId,
    required this.datasetId,
    required this.deviceId,
    required this.displayName,
    required this.localRootReference,
    required this.localDisplayName,
    this.accessKind = FolderAccessKind.localPath,
    required this.connectionId,
    this.remoteRootSegments = const [],
    this.direction = MirrorDirection.bidirectional,
    this.conflictPolicy = MirrorConflictPolicy.keepBoth,
    this.initialSyncPolicy = MirrorInitialSyncPolicy.merge,
    this.backgroundEnabled = false,
    this.backgroundAllowCellular = false,
    this.backgroundRequiresCharging = false,
    this.backgroundCellularMaxTransferBytes =
        defaultBackgroundCellularMaxTransferBytes,
    this.state = PlainFolderProfileState.active,
    required this.createdAt,
  });

  final String profileId;
  final String datasetId;
  final String deviceId;
  final String displayName;

  /// Filesystem path, Android SAF tree URI, or Apple security-scoped bookmark.
  final String localRootReference;

  /// Human-readable local folder name captured when the user picked it.
  final String localDisplayName;

  final FolderAccessKind accessKind;
  final String connectionId;

  /// Decoded relative remote path segments below the connection root; empty
  /// keeps the connection root itself.
  final List<String> remoteRootSegments;

  final MirrorDirection direction;
  final MirrorConflictPolicy conflictPolicy;
  final MirrorInitialSyncPolicy initialSyncPolicy;

  final bool backgroundEnabled;
  final bool backgroundAllowCellular;
  final bool backgroundRequiresCharging;
  final int backgroundCellularMaxTransferBytes;
  final PlainFolderProfileState state;
  final DateTime createdAt;

  bool get isActive => state == PlainFolderProfileState.active;

  SyncProfileEnvelope toEnvelope() => SyncProfileEnvelope(
    kind: SyncDatasetKind.plainFolder,
    profileId: profileId,
    datasetId: datasetId,
    // Plain folder sync has no vault; the envelope keeps the field empty.
    vaultId: '',
    deviceId: deviceId,
    displayName: displayName,
    connectionId: connectionId,
    state: isActive ? SyncProfileState.active : SyncProfileState.paused,
    backgroundPolicy: SyncProfileBackgroundPolicy(
      enabled: backgroundEnabled,
      allowCellular: backgroundAllowCellular,
      requiresCharging: backgroundRequiresCharging,
      cellularMaxTransferBytes: backgroundCellularMaxTransferBytes,
    ),
    dataset: {
      'accessKind': accessKind.name,
      'localRootReference': localRootReference,
      'localDisplayName': localDisplayName,
      'remoteRootSegments': canonicalPlainRemoteRootSegments(
        remoteRootSegments,
      ),
      'direction': direction.name,
      'conflictPolicy': conflictPolicy.name,
      'initialSyncPolicy': initialSyncPolicy.name,
    },
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => toEnvelope().toJson();

  factory PlainFolderSyncProfile.fromEnvelope(SyncProfileEnvelope envelope) {
    if (envelope.kind != SyncDatasetKind.plainFolder) {
      throw const FormatException('Unsupported sync profile kind.');
    }
    final dataset = envelope.dataset;
    return PlainFolderSyncProfile(
      profileId: envelope.profileId,
      datasetId: envelope.datasetId,
      deviceId: envelope.deviceId,
      displayName: envelope.displayName,
      localRootReference: _requiredString(dataset, 'localRootReference'),
      localDisplayName:
          _optionalString(dataset, 'localDisplayName') ?? envelope.displayName,
      accessKind: _accessKind(dataset['accessKind']),
      connectionId: envelope.connectionId,
      remoteRootSegments: _remoteRootSegments(dataset),
      direction: _direction(dataset['direction']),
      conflictPolicy: _conflictPolicy(dataset['conflictPolicy']),
      initialSyncPolicy: _initialSyncPolicy(dataset['initialSyncPolicy']),
      backgroundEnabled: envelope.backgroundPolicy.enabled,
      backgroundAllowCellular: envelope.backgroundPolicy.allowCellular,
      backgroundRequiresCharging: envelope.backgroundPolicy.requiresCharging,
      backgroundCellularMaxTransferBytes:
          envelope.backgroundPolicy.cellularMaxTransferBytes,
      state: envelope.state == SyncProfileState.active
          ? PlainFolderProfileState.active
          : PlainFolderProfileState.paused,
      createdAt: envelope.createdAt,
    );
  }

  factory PlainFolderSyncProfile.fromJson(Map<String, dynamic> value) =>
      PlainFolderSyncProfile.fromEnvelope(SyncProfileEnvelope.fromJson(value));

  /// Validates and defensively copies the user-confirmed remote folder.
  static List<String> canonicalPlainRemoteRootSegments(
    Iterable<String> segments,
  ) => remote_root_segments.canonicalRemoteRootSegments(segments);

  PlainFolderSyncProfile copyWith({
    String? displayName,
    String? localRootReference,
    String? localDisplayName,
    FolderAccessKind? accessKind,
    List<String>? remoteRootSegments,
    MirrorDirection? direction,
    MirrorConflictPolicy? conflictPolicy,
    MirrorInitialSyncPolicy? initialSyncPolicy,
    bool? backgroundEnabled,
    bool? backgroundAllowCellular,
    bool? backgroundRequiresCharging,
    int? backgroundCellularMaxTransferBytes,
    PlainFolderProfileState? state,
  }) => PlainFolderSyncProfile(
    profileId: profileId,
    datasetId: datasetId,
    deviceId: deviceId,
    displayName: displayName ?? this.displayName,
    localRootReference: localRootReference ?? this.localRootReference,
    localDisplayName: localDisplayName ?? this.localDisplayName,
    accessKind: accessKind ?? this.accessKind,
    connectionId: connectionId,
    remoteRootSegments: remoteRootSegments ?? this.remoteRootSegments,
    direction: direction ?? this.direction,
    conflictPolicy: conflictPolicy ?? this.conflictPolicy,
    initialSyncPolicy: initialSyncPolicy ?? this.initialSyncPolicy,
    backgroundEnabled: backgroundEnabled ?? this.backgroundEnabled,
    backgroundAllowCellular:
        backgroundAllowCellular ?? this.backgroundAllowCellular,
    backgroundRequiresCharging:
        backgroundRequiresCharging ?? this.backgroundRequiresCharging,
    backgroundCellularMaxTransferBytes:
        backgroundCellularMaxTransferBytes ??
        this.backgroundCellularMaxTransferBytes,
    state: state ?? this.state,
    createdAt: createdAt,
  );

  /// Path label shown in the UI, e.g. `远程：NAS · /photos/phone`.
  static String remoteLocationLabel(
    String connectionName,
    List<String> segments,
  ) => segments.isEmpty
      ? connectionName
      : '$connectionName · /${segments.join('/')}';

  static String _requiredString(Map<String, Object?> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw FormatException('Sync profile $key is invalid.');
    }
    return field;
  }

  static String? _optionalString(Map<String, Object?> value, String key) {
    final field = value[key];
    if (field == null) return null;
    if (field is! String) {
      throw FormatException('Sync profile $key is invalid.');
    }
    return field;
  }

  static FolderAccessKind _accessKind(Object? value) {
    if (value == null) return FolderAccessKind.localPath;
    if (value is! String) {
      throw const FormatException('Sync profile accessKind is invalid.');
    }
    return FolderAccessKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () =>
          throw const FormatException('Sync profile accessKind is invalid.'),
    );
  }

  static MirrorDirection _direction(Object? value) {
    if (value == null) return MirrorDirection.bidirectional;
    if (value is! String) {
      throw const FormatException('Sync profile direction is invalid.');
    }
    return MirrorDirection.values.firstWhere(
      (direction) => direction.name == value,
      orElse: () =>
          throw const FormatException('Sync profile direction is invalid.'),
    );
  }

  static MirrorConflictPolicy _conflictPolicy(Object? value) {
    if (value == null) return MirrorConflictPolicy.keepBoth;
    if (value is! String) {
      throw const FormatException('Sync profile conflict policy is invalid.');
    }
    return MirrorConflictPolicy.values.firstWhere(
      (policy) => policy.name == value,
      orElse: () => throw const FormatException(
        'Sync profile conflict policy is invalid.',
      ),
    );
  }

  static MirrorInitialSyncPolicy _initialSyncPolicy(Object? value) {
    if (value == null) return MirrorInitialSyncPolicy.merge;
    if (value is! String) {
      throw const FormatException(
        'Sync profile initial sync policy is invalid.',
      );
    }
    return MirrorInitialSyncPolicy.values.firstWhere(
      (policy) => policy.name == value,
      orElse: () => throw const FormatException(
        'Sync profile initial sync policy is invalid.',
      ),
    );
  }

  static List<String> _remoteRootSegments(Map<String, Object?> value) {
    final field = value['remoteRootSegments'];
    if (field == null) return const [];
    if (field is! List || field.any((item) => item is! String)) {
      throw const FormatException(
        'Sync profile remote root segments are invalid.',
      );
    }
    return canonicalPlainRemoteRootSegments(field.cast<String>());
  }
}

class PlainFolderSyncProfileRepository {
  PlainFolderSyncProfileRepository(this._database);

  final SyncStateDatabase _database;

  Future<void> save(PlainFolderSyncProfile profile) =>
      _database.upsertSyncProfilePayload(
        profileId: profile.profileId,
        datasetId: profile.datasetId,
        targetId: profile.connectionId,
        vaultId: '',
        state: profile.state.name,
        payload: jsonEncode(profile.toJson()),
      );

  Future<PlainFolderSyncProfile?> read(String profileId) async {
    final record = await _database.readVisibleSyncProfilePayload(profileId);
    if (record == null) return null;
    return _decode(record);
  }

  Future<List<PlainFolderSyncProfile>> list() async {
    final profiles = <PlainFolderSyncProfile>[];
    for (final record in await _database.readVisibleSyncProfilePayloads()) {
      final profile = _decode(record);
      if (profile != null) profiles.add(profile);
    }
    return profiles;
  }

  Future<void> pause(String profileId) => _database.setSyncProfileState(
    profileId: profileId,
    state: PlainFolderProfileState.paused.name,
  );

  Future<void> resume(String profileId) => _database.setSyncProfileState(
    profileId: profileId,
    state: PlainFolderProfileState.active.name,
  );

  /// Removal is refused while a run is in flight or starting.
  ///
  /// The per-location guard makes "check for a running run" and "mark removed"
  /// one operation, so a run cannot slip in between the two.
  Future<void> remove(String profileId) =>
      withVelockLocationGuard(_database, profileId, () async {
        if (await _database.hasRunningSyncRun(profileId)) {
          throw StateError('Sync location is still running.');
        }
        await _database.setSyncProfileState(
          profileId: profileId,
          state: 'removed',
        );
      });

  /// Applies one explicitly confirmed edit to this location only.
  ///
  /// Keeps every other field, refuses a stale page, a running task and a
  /// removed/paused profile, and never edits the shared connection.
  Future<PlainFolderSyncProfile> update(
    PlainFolderSyncProfile expected,
    PlainFolderSyncProfile Function(PlainFolderSyncProfile current) change,
  ) => withVelockLocationGuard(_database, expected.profileId, () async {
    // A paused location stays editable: pausing stops transfers, it does not
    // freeze the settings the user may still want to correct.
    final current = await read(expected.profileId);
    if (current == null ||
        jsonEncode(current.toJson()) != jsonEncode(expected.toJson()) ||
        await _database.hasRunningSyncRun(expected.profileId)) {
      throw StateError(
        'Sync location changed or is running. Reopen and retry.',
      );
    }
    final updated = change(current);
    await save(updated);
    return updated;
  });

  /// Moves this location to a new local or remote folder, as one operation.
  ///
  /// The new binding and the removal of everything the OLD folders taught this
  /// location (baseline rows, conflict log, run history) are written in a single
  /// transaction inside the location lease. Saving the folder first and clearing
  /// the baseline afterwards leaves a window in which the profile points at a new
  /// folder while the old baseline still describes the old one: the next run then
  /// reads every baselined path as "gone" and, below the fraction guard, deletes
  /// the copies that are still there.
  ///
  /// [confirmRemoteWrite] runs before anything is written, so a remote folder
  /// that cannot be written to fails the relocation instead of being saved. The
  /// caller passes the existing probe, e.g.
  /// `(updated) => service.checkRemoteWritableFor(
  ///      connectionId: updated.connectionId,
  ///      remoteRootSegments: updated.remoteRootSegments)`.
  Future<PlainFolderSyncProfile> relocate(
    PlainFolderSyncProfile expected,
    PlainFolderSyncProfile Function(PlainFolderSyncProfile current) change, {
    Future<void> Function(PlainFolderSyncProfile updated)? confirmRemoteWrite,
    bool resetBaseline = true,
  }) => withVelockLocationGuard(_database, expected.profileId, () async {
    // A paused location stays relocatable: pausing stops transfers, it does not
    // freeze the folders the user still wants to correct.
    final current = await read(expected.profileId);
    if (current == null ||
        jsonEncode(current.toJson()) != jsonEncode(expected.toJson()) ||
        await _database.hasRunningSyncRun(expected.profileId)) {
      throw StateError(
        'Sync location changed or is running. Reopen and retry.',
      );
    }
    final updated = change(current);
    // Still inside the lease and before the transaction: a failed probe leaves
    // the old binding and its baseline exactly as they were.
    await confirmRemoteWrite?.call(updated);
    await _database.relocateMirrorProfile(
      profileId: updated.profileId,
      datasetId: updated.datasetId,
      targetId: updated.connectionId,
      state: updated.state.name,
      payload: jsonEncode(updated.toJson()),
      resetBaseline: resetBaseline,
    );
    return updated;
  });

  PlainFolderSyncProfile? _decode(SyncProfilePayloadRecord record) {
    try {
      final decoded = jsonDecode(record.payload);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Sync profile payload is invalid.');
      }
      final envelope = SyncProfileEnvelope.fromJson(decoded);
      if (envelope.kind != SyncDatasetKind.plainFolder ||
          envelope.profileId != record.profileId) {
        return null;
      }
      return PlainFolderSyncProfile.fromEnvelope(envelope).copyWith(
        state: record.state == PlainFolderProfileState.active.name
            ? PlainFolderProfileState.active
            : PlainFolderProfileState.paused,
      );
    } on Object catch (error, stackTrace) {
      // A malformed or future payload must not break the whole list, but a
      // location that silently disappears is worse: the failure is logged with
      // the profile id only (never the payload, which holds user paths).
      loge(
        'Plain folder sync profile ${record.profileId} could not be read '
        '(${error.runtimeType}); it is skipped.',
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}
