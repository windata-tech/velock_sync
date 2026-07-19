import 'dart:convert';

import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

const defaultBackgroundCellularMaxTransferBytes = 50 * 1024 * 1024;

enum SelectedFolderProfileState { active, paused }

/// Non-secret configuration needed to reconstruct a Selected Folder sync run.
/// [rootKeyRef] and [signingKeyRef] point to platform secure storage.
class SelectedFolderSyncProfile {
  const SelectedFolderSyncProfile({
    required this.profileId,
    required this.datasetId,
    required this.vaultId,
    required this.deviceId,
    required this.displayName,
    required this.rootPath,
    this.accessKind = FolderAccessKind.localPath,
    this.backgroundEnabled = false,
    this.backgroundAllowCellular = false,
    this.backgroundRequiresCharging = false,
    this.backgroundCellularMaxTransferBytes =
        defaultBackgroundCellularMaxTransferBytes,
    this.state = SelectedFolderProfileState.active,
    required this.connectionId,
    required this.keyId,
    required this.rootKeyRef,
    required this.signingKeyRef,
    required this.createdAt,
  });

  final String profileId;
  final String datasetId;
  final String vaultId;
  final String deviceId;
  final String displayName;
  final String rootPath;
  final FolderAccessKind accessKind;
  final bool backgroundEnabled;
  final bool backgroundAllowCellular;
  final bool backgroundRequiresCharging;
  final int backgroundCellularMaxTransferBytes;
  final SelectedFolderProfileState state;
  final String connectionId;
  final String keyId;
  final String rootKeyRef;
  final String signingKeyRef;
  final DateTime createdAt;

  Map<String, Object?> toJson() => SyncProfileEnvelope(
    kind: SyncDatasetKind.selectedFolder,
    profileId: profileId,
    datasetId: datasetId,
    vaultId: vaultId,
    deviceId: deviceId,
    displayName: displayName,
    connectionId: connectionId,
    state: state == SelectedFolderProfileState.active
        ? SyncProfileState.active
        : SyncProfileState.paused,
    backgroundPolicy: SyncProfileBackgroundPolicy(
      enabled: backgroundEnabled,
      allowCellular: backgroundAllowCellular,
      requiresCharging: backgroundRequiresCharging,
      cellularMaxTransferBytes: backgroundCellularMaxTransferBytes,
    ),
    dataset: {
      'accessKind': accessKind.name,
      'keyId': keyId,
      'rootKeyRef': rootKeyRef,
      'rootPath': rootPath,
      'signingKeyRef': signingKeyRef,
    },
    createdAt: createdAt,
  ).toJson();

  factory SelectedFolderSyncProfile.fromJson(Map<String, dynamic> value) {
    if (value['schemaVersion'] != null) {
      final envelope = SyncProfileEnvelope.fromJson(value);
      if (envelope.kind != SyncDatasetKind.selectedFolder) {
        throw const FormatException('Unsupported sync profile kind.');
      }
      final dataset = envelope.dataset;
      return SelectedFolderSyncProfile(
        profileId: envelope.profileId,
        datasetId: envelope.datasetId,
        vaultId: envelope.vaultId,
        deviceId: envelope.deviceId,
        displayName: envelope.displayName,
        rootPath: _string(dataset, 'rootPath'),
        accessKind: _accessKind(dataset['accessKind']),
        backgroundEnabled: envelope.backgroundPolicy.enabled,
        backgroundAllowCellular: envelope.backgroundPolicy.allowCellular,
        backgroundRequiresCharging: envelope.backgroundPolicy.requiresCharging,
        backgroundCellularMaxTransferBytes:
            envelope.backgroundPolicy.cellularMaxTransferBytes,
        state: envelope.state == SyncProfileState.active
            ? SelectedFolderProfileState.active
            : SelectedFolderProfileState.paused,
        connectionId: envelope.connectionId,
        keyId: _string(dataset, 'keyId'),
        rootKeyRef: _string(dataset, 'rootKeyRef'),
        signingKeyRef: _string(dataset, 'signingKeyRef'),
        createdAt: envelope.createdAt,
      );
    }
    // Legacy Selected Folder profiles were flat. Continue decoding them so a
    // normal save transparently upgrades to the typed common envelope.
    if (value['kind'] != 'selected-folder') {
      throw const FormatException('Unsupported sync profile kind.');
    }
    return SelectedFolderSyncProfile(
      profileId: _string(value, 'profileId'),
      datasetId: _string(value, 'datasetId'),
      vaultId: _string(value, 'vaultId'),
      deviceId: _string(value, 'deviceId'),
      displayName: _string(value, 'displayName'),
      rootPath: _string(value, 'rootPath'),
      accessKind: _accessKind(value['accessKind']),
      backgroundEnabled: _bool(value['backgroundEnabled']),
      backgroundAllowCellular: _bool(value['backgroundAllowCellular']),
      backgroundRequiresCharging: _bool(value['backgroundRequiresCharging']),
      backgroundCellularMaxTransferBytes: _positiveInt(
        value['backgroundCellularMaxTransferBytes'],
        defaultValue: defaultBackgroundCellularMaxTransferBytes,
      ),
      connectionId: _string(value, 'connectionId'),
      keyId: _string(value, 'keyId'),
      rootKeyRef: _string(value, 'rootKeyRef'),
      signingKeyRef: _string(value, 'signingKeyRef'),
      createdAt: DateTime.parse(_string(value, 'createdAt')).toUtc(),
    );
  }

  static String _string(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
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

  static int _positiveInt(Object? value, {required int defaultValue}) {
    if (value == null) return defaultValue;
    if (value is! int || value < 1) {
      throw const FormatException('Sync profile transfer limit is invalid.');
    }
    return value;
  }

  SelectedFolderSyncProfile copyWith({
    bool? backgroundEnabled,
    bool? backgroundAllowCellular,
    bool? backgroundRequiresCharging,
    int? backgroundCellularMaxTransferBytes,
    SelectedFolderProfileState? state,
  }) => SelectedFolderSyncProfile(
    profileId: profileId,
    datasetId: datasetId,
    vaultId: vaultId,
    deviceId: deviceId,
    displayName: displayName,
    rootPath: rootPath,
    accessKind: accessKind,
    backgroundEnabled: backgroundEnabled ?? this.backgroundEnabled,
    backgroundAllowCellular:
        backgroundAllowCellular ?? this.backgroundAllowCellular,
    backgroundRequiresCharging:
        backgroundRequiresCharging ?? this.backgroundRequiresCharging,
    backgroundCellularMaxTransferBytes:
        backgroundCellularMaxTransferBytes ??
        this.backgroundCellularMaxTransferBytes,
    state: state ?? this.state,
    connectionId: connectionId,
    keyId: keyId,
    rootKeyRef: rootKeyRef,
    signingKeyRef: signingKeyRef,
    createdAt: createdAt,
  );

  static bool _bool(Object? value) {
    if (value == null) return false;
    if (value is! bool) {
      throw const FormatException('Sync profile backgroundEnabled is invalid.');
    }
    return value;
  }
}

class SelectedFolderSyncProfileRepository {
  SelectedFolderSyncProfileRepository(this._database);

  final SyncStateDatabase _database;

  Future<void> save(SelectedFolderSyncProfile profile) =>
      _database.upsertSyncProfilePayload(
        profileId: profile.profileId,
        datasetId: profile.datasetId,
        targetId: profile.connectionId,
        vaultId: profile.vaultId,
        state: profile.state.name,
        payload: jsonEncode(profile.toJson()),
      );

  Future<SelectedFolderSyncProfile?> read(String profileId) async {
    final record = await _database.readVisibleSyncProfilePayload(profileId);
    if (record == null) return null;
    return _decode(record);
  }

  Future<void> pause(String profileId) => _database.setSyncProfileState(
    profileId: profileId,
    state: SelectedFolderProfileState.paused.name,
  );

  Future<void> resume(String profileId) => _database.setSyncProfileState(
    profileId: profileId,
    state: SelectedFolderProfileState.active.name,
  );

  Future<void> remove(String profileId) async {
    if (await _database.hasRunningSyncRun(profileId)) {
      throw StateError('Sync profile is still running.');
    }
    await _database.setSyncProfileState(profileId: profileId, state: 'removed');
  }

  SelectedFolderSyncProfile? _decode(SyncProfilePayloadRecord record) {
    final decoded = jsonDecode(record.payload);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Sync profile payload is invalid.');
    }
    try {
      final profile = SelectedFolderSyncProfile.fromJson(decoded);
      if (profile.profileId != record.profileId) {
        throw const FormatException('Sync profile identity is invalid.');
      }
      return profile.copyWith(
        state: record.state == SelectedFolderProfileState.active.name
            ? SelectedFolderProfileState.active
            : SelectedFolderProfileState.paused,
      );
    } on FormatException {
      // A future profile kind/version must not make the Selected Folder screen
      // unusable. The common repository keeps its diagnostic summary intact.
      return null;
    }
  }

  Future<List<SelectedFolderSyncProfile>> list() async {
    final profiles = <SelectedFolderSyncProfile>[];
    for (final record in await _database.readVisibleSyncProfilePayloads()) {
      final profile = _decode(record);
      if (profile != null) profiles.add(profile);
    }
    return profiles;
  }
}
