import 'package:velock_sync/core/local_data_manager.dart';

const syncProtocolDisplayVersion = 'Velock Sync Protocol V1';
const syncAppDisplayVersion = String.fromEnvironment(
  'VELOCK_SYNC_APP_VERSION',
  defaultValue: '1.0.0+1',
);

class SyncGlobalSettings {
  const SyncGlobalSettings({
    this.backgroundEnabled = true,
    this.defaultAllowCellular = false,
    this.defaultRequiresCharging = false,
    this.defaultCellularMaxTransferBytes = 50 * 1024 * 1024,
  }) : assert(defaultCellularMaxTransferBytes > 0);

  final bool backgroundEnabled;
  final bool defaultAllowCellular;
  final bool defaultRequiresCharging;
  final int defaultCellularMaxTransferBytes;

  SyncGlobalSettings copyWith({
    bool? backgroundEnabled,
    bool? defaultAllowCellular,
    bool? defaultRequiresCharging,
    int? defaultCellularMaxTransferBytes,
  }) => SyncGlobalSettings(
    backgroundEnabled: backgroundEnabled ?? this.backgroundEnabled,
    defaultAllowCellular: defaultAllowCellular ?? this.defaultAllowCellular,
    defaultRequiresCharging:
        defaultRequiresCharging ?? this.defaultRequiresCharging,
    defaultCellularMaxTransferBytes:
        defaultCellularMaxTransferBytes ?? this.defaultCellularMaxTransferBytes,
  );
}

abstract interface class SyncGlobalSettingsStore {
  Future<SyncGlobalSettings> read();
  Future<void> save(SyncGlobalSettings settings);
}

class LocalSyncGlobalSettingsStore implements SyncGlobalSettingsStore {
  LocalSyncGlobalSettingsStore(this._localData);

  static const _backgroundEnabledKey =
      'sync.settings.global_background_enabled';
  static const _defaultAllowCellularKey =
      'sync.settings.default_allow_cellular';
  static const _defaultRequiresChargingKey =
      'sync.settings.default_requires_charging';
  static const _defaultCellularMaxBytesKey =
      'sync.settings.default_cellular_max_bytes';

  final LocalDataManager _localData;

  @override
  Future<SyncGlobalSettings> read() async {
    final maximumBytes = await _localData.getIntAsync(
      _defaultCellularMaxBytesKey,
      defaultValue: 50 * 1024 * 1024,
    );
    return SyncGlobalSettings(
      backgroundEnabled:
          await _localData.getBoolAsync(
            _backgroundEnabledKey,
            defaultValue: true,
          ) ??
          true,
      defaultAllowCellular:
          await _localData.getBoolAsync(
            _defaultAllowCellularKey,
            defaultValue: false,
          ) ??
          false,
      defaultRequiresCharging:
          await _localData.getBoolAsync(
            _defaultRequiresChargingKey,
            defaultValue: false,
          ) ??
          false,
      defaultCellularMaxTransferBytes: maximumBytes == null || maximumBytes < 1
          ? 50 * 1024 * 1024
          : maximumBytes,
    );
  }

  @override
  Future<void> save(SyncGlobalSettings settings) async {
    await _localData.setBoolAsync(
      _backgroundEnabledKey,
      settings.backgroundEnabled,
    );
    await _localData.setBoolAsync(
      _defaultAllowCellularKey,
      settings.defaultAllowCellular,
    );
    await _localData.setBoolAsync(
      _defaultRequiresChargingKey,
      settings.defaultRequiresCharging,
    );
    await _localData.setIntAsync(
      _defaultCellularMaxBytesKey,
      settings.defaultCellularMaxTransferBytes,
    );
  }
}
