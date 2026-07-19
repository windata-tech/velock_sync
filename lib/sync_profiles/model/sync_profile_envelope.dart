import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

const syncProfileSchemaVersion = 1;

/// The only persisted common profile shape used by new V1 profiles.
///
/// Credential/key fields must be references owned by secure storage. Payload
/// material never belongs in this envelope or in SyncStateDatabase.
class SyncProfileEnvelope {
  const SyncProfileEnvelope({
    this.schemaVersion = syncProfileSchemaVersion,
    required this.kind,
    required this.profileId,
    required this.datasetId,
    required this.vaultId,
    required this.deviceId,
    required this.displayName,
    required this.connectionId,
    required this.state,
    required this.backgroundPolicy,
    required this.dataset,
    required this.createdAt,
  });

  final int schemaVersion;
  final SyncDatasetKind kind;
  final String profileId;
  final String datasetId;
  final String vaultId;
  final String deviceId;
  final String displayName;
  final String connectionId;
  final SyncProfileState state;
  final SyncProfileBackgroundPolicy backgroundPolicy;
  final Map<String, Object?> dataset;
  final DateTime createdAt;

  SyncProfileEnvelope copyWith({
    SyncProfileState? state,
    SyncProfileBackgroundPolicy? backgroundPolicy,
  }) => SyncProfileEnvelope(
    schemaVersion: schemaVersion,
    kind: kind,
    profileId: profileId,
    datasetId: datasetId,
    vaultId: vaultId,
    deviceId: deviceId,
    displayName: displayName,
    connectionId: connectionId,
    state: state ?? this.state,
    backgroundPolicy: backgroundPolicy ?? this.backgroundPolicy,
    dataset: dataset,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'kind': kind.persistedValue,
    'profileId': profileId,
    'datasetId': datasetId,
    'vaultId': vaultId,
    'deviceId': deviceId,
    'displayName': displayName,
    'connectionId': connectionId,
    'state': state.name,
    'background': backgroundPolicy.toJson(),
    'dataset': dataset,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory SyncProfileEnvelope.fromJson(Map<String, dynamic> value) {
    final version = value['schemaVersion'];
    if (version is! int || version != syncProfileSchemaVersion) {
      throw UnsupportedSyncProfileEnvelopeException(
        'Unsupported sync profile schema version.',
      );
    }
    final kind = SyncDatasetKind.tryParse(value['kind']);
    if (kind == null) {
      throw UnsupportedSyncProfileEnvelopeException(
        'Unsupported sync profile kind.',
      );
    }
    final dataset = value['dataset'];
    if (dataset is! Map<String, dynamic>) {
      throw const FormatException('Sync profile dataset payload is invalid.');
    }
    final state = SyncProfileState.tryParse(value['state']);
    if (state == null) {
      throw const FormatException('Sync profile lifecycle state is invalid.');
    }
    final background = value['background'];
    if (background != null && background is! Map<String, dynamic>) {
      throw const FormatException('Sync profile background policy is invalid.');
    }
    final result = SyncProfileEnvelope(
      schemaVersion: version,
      kind: kind,
      profileId: _requiredString(value, 'profileId'),
      datasetId: _requiredString(value, 'datasetId'),
      vaultId: _requiredString(value, 'vaultId'),
      deviceId: _requiredString(value, 'deviceId'),
      displayName: _requiredString(value, 'displayName'),
      connectionId: _requiredString(value, 'connectionId'),
      state: state,
      backgroundPolicy: SyncProfileBackgroundPolicy.fromJson(
        background as Map<String, dynamic>?,
      ),
      dataset: _jsonObject(dataset),
      createdAt: DateTime.parse(_requiredString(value, 'createdAt')).toUtc(),
    );
    _ensureNoSecretValues(result.dataset);
    return result;
  }

  static String _requiredString(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw FormatException('Sync profile $key is invalid.');
    }
    return field;
  }

  static Map<String, Object?> _jsonObject(Map<String, dynamic> value) =>
      Map<String, Object?>.unmodifiable(
        value.map((key, entry) => MapEntry(key, _jsonValue(entry))),
      );

  static Object? _jsonValue(Object? value) => switch (value) {
    String() || num() || bool() || null => value,
    Map<String, dynamic>() => _jsonObject(value),
    List<dynamic>() => List<Object?>.unmodifiable(value.map(_jsonValue)),
    _ => throw const FormatException('Sync profile contains a non-JSON value.'),
  };

  static void _ensureNoSecretValues(Map<String, Object?> value) {
    for (final entry in value.entries) {
      final lowerKey = entry.key.toLowerCase();
      final hasSecretName = RegExp(
        r'(password|token|secret|seed|privatekey|masterkey|synckey)',
      ).hasMatch(lowerKey);
      if (hasSecretName && !lowerKey.endsWith('ref')) {
        throw const FormatException(
          'Sync profile dataset payload must store only secure-storage references.',
        );
      }
      if (entry.value case final Map<String, Object?> nested) {
        _ensureNoSecretValues(nested);
      }
    }
  }
}

class UnsupportedSyncProfileEnvelopeException implements Exception {
  const UnsupportedSyncProfileEnvelopeException(this.message);

  final String message;

  @override
  String toString() => message;
}
