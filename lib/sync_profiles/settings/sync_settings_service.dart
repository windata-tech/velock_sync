import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:velock_sync/background/background_sync.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';

class SyncSettingsSnapshot {
  const SyncSettingsSnapshot({
    required this.settings,
    required this.backgroundSupported,
    required this.backgroundEligibleProfileCount,
    required this.staging,
  });

  final SyncGlobalSettings settings;
  final bool backgroundSupported;
  final int backgroundEligibleProfileCount;
  final StagingSpaceSummary staging;
}

class SyncSettingsCleanupSummary {
  const SyncSettingsCleanupSummary({
    this.freedBytes = 0,
    this.removedBatchCount = 0,
    this.removedTemporaryFileCount = 0,
    this.preservedRecoverableBatchCount = 0,
    this.busyProfileCount = 0,
  });

  final int freedBytes;
  final int removedBatchCount;
  final int removedTemporaryFileCount;
  final int preservedRecoverableBatchCount;
  final int busyProfileCount;
}

abstract interface class SyncSettingsService {
  Future<SyncSettingsSnapshot> load();
  Future<SyncSettingsSnapshot> save(SyncGlobalSettings settings);
  Future<SyncSettingsCleanupSummary> cleanupStaging();
  Future<String> exportSanitizedDiagnostics();
}

class DurableSyncSettingsService implements SyncSettingsService {
  DurableSyncSettingsService({
    required SyncGlobalSettingsStore settings,
    required SyncProfileRepository profiles,
    required SyncStateDatabase database,
    required Future<Directory> Function() supportDirectory,
    BackgroundSyncScheduler? scheduler,
    bool? backgroundSupported,
    DateTime Function()? now,
  }) : _settings = settings,
       _profiles = profiles,
       _database = database,
       _supportDirectory = supportDirectory,
       _scheduler = scheduler ?? BackgroundSyncScheduler(),
       _backgroundSupported =
           backgroundSupported ?? BackgroundSyncScheduler.isSupported,
       _now = now ?? DateTime.now;

  final SyncGlobalSettingsStore _settings;
  final SyncProfileRepository _profiles;
  final SyncStateDatabase _database;
  final Future<Directory> Function() _supportDirectory;
  final BackgroundSyncScheduler _scheduler;
  final bool _backgroundSupported;
  final DateTime Function() _now;

  @override
  Future<SyncSettingsSnapshot> load() async {
    final values = await Future.wait<Object>([
      _settings.read(),
      _profiles.listSummaries(),
      _inspectStaging(),
    ]);
    final profiles = values[1] as List<SyncProfileSummary>;
    return SyncSettingsSnapshot(
      settings: values[0] as SyncGlobalSettings,
      backgroundSupported: _backgroundSupported,
      backgroundEligibleProfileCount: profiles
          .where((profile) => profile.isBackgroundEligible)
          .length,
      staging: values[2] as StagingSpaceSummary,
    );
  }

  @override
  Future<SyncSettingsSnapshot> save(SyncGlobalSettings settings) async {
    await _settings.save(settings);
    await _refreshScheduler(settings);
    return load();
  }

  Future<void> _refreshScheduler(SyncGlobalSettings settings) async {
    if (!_backgroundSupported) return;
    final eligible = await _profiles.listBackgroundEligible();
    if (!settings.backgroundEnabled || eligible.isEmpty) {
      await _scheduler.disable();
      return;
    }
    await _scheduler.enable(
      allowCellular: eligible.any(
        (profile) => profile.backgroundPolicy.allowCellular,
      ),
      requiresCharging: eligible.every(
        (profile) => profile.backgroundPolicy.requiresCharging,
      ),
    );
  }

  @override
  Future<SyncSettingsCleanupSummary> cleanupStaging() async {
    final manager = StagingSpaceManager(_database);
    var freedBytes = 0;
    var removedBatchCount = 0;
    var removedTemporaryFileCount = 0;
    var preservedRecoverableBatchCount = 0;
    var busyProfileCount = 0;
    for (final entry in await _profileStagingRoots()) {
      try {
        final result = await manager.safelyCleanup(
          profileId: entry.profileId,
          profileStagingRoot: entry.directory,
        );
        freedBytes += result.freedBytes;
        removedBatchCount += result.removedBatchCount;
        removedTemporaryFileCount += result.removedTemporaryFileCount;
        preservedRecoverableBatchCount += result.preservedRecoverableBatchCount;
      } on StagingMaintenanceBusyException {
        busyProfileCount++;
      }
    }
    return SyncSettingsCleanupSummary(
      freedBytes: freedBytes,
      removedBatchCount: removedBatchCount,
      removedTemporaryFileCount: removedTemporaryFileCount,
      preservedRecoverableBatchCount: preservedRecoverableBatchCount,
      busyProfileCount: busyProfileCount,
    );
  }

  @override
  Future<String> exportSanitizedDiagnostics() async {
    final settings = await _settings.read();
    final profiles = await _profiles.listSummaries();
    final runs = await _database.listRecentSyncRuns();
    final transfers = await _database.listTransferJobs();
    final conflicts = await _database.listUnresolvedConflicts();
    final staging = await _inspectStaging();

    return const JsonEncoder.withIndent('  ').convert({
      'formatVersion': 1,
      'generatedAt': _now().toUtc().toIso8601String(),
      'appVersion': syncAppDisplayVersion,
      'protocolVersion': syncProtocolDisplayVersion,
      'platform': Platform.operatingSystem,
      'globalBackground': {
        'enabled': settings.backgroundEnabled,
        'defaultAllowCellular': settings.defaultAllowCellular,
        'defaultRequiresCharging': settings.defaultRequiresCharging,
        'defaultCellularMaxTransferBytes':
            settings.defaultCellularMaxTransferBytes,
        'systemSupported': _backgroundSupported,
      },
      'profiles': {
        'total': profiles.length,
        'isolated': profiles.where((profile) => profile.isIsolated).length,
        'byDataset': _counts(
          profiles.map(
            (profile) => switch (profile.kind) {
              SyncDatasetKind.selectedFolder => 'selectedFolder',
              SyncDatasetKind.velockManaged => 'velockManaged',
              null => 'unavailable',
            },
          ),
        ),
        'byState': _counts(profiles.map((profile) => profile.state.name)),
      },
      'runs': {
        'total': runs.length,
        'byState': _counts(runs.map((run) => run.state)),
        'byErrorCode': _counts(
          runs
              .map((run) => run.errorCode)
              .whereType<String>()
              .map(_sanitizeErrorCode),
        ),
      },
      'transfers': {
        'total': transfers.length,
        'byDirection': _counts(
          transfers.map((transfer) => transfer.direction.name),
        ),
        'byState': _counts(transfers.map((transfer) => transfer.state.name)),
      },
      'unresolvedConflictCount': conflicts.length,
      'staging': {
        'bytes': staging.totalBytes,
        'files': staging.fileCount,
        'batches': staging.batchCount,
      },
      'privacy': {
        'containsCredentials': false,
        'containsKeys': false,
        'containsProfileIdentifiers': false,
        'containsPaths': false,
        'containsBusinessContent': false,
        'containsProtectedConflictDetails': false,
      },
    });
  }

  Future<StagingSpaceSummary> _inspectStaging() async {
    final manager = StagingSpaceManager(_database);
    var totalBytes = 0;
    var fileCount = 0;
    var batchCount = 0;
    for (final entry in await _profileStagingRoots(requireSafeId: false)) {
      final summary = await manager.inspect(entry.directory);
      totalBytes += summary.totalBytes;
      fileCount += summary.fileCount;
      batchCount += summary.batchCount;
    }
    return StagingSpaceSummary(
      totalBytes: totalBytes,
      fileCount: fileCount,
      batchCount: batchCount,
    );
  }

  Future<Directory> _stagingRoot() async =>
      Directory(p.join((await _supportDirectory()).path, 'staging'));

  Future<List<({String profileId, Directory directory})>> _profileStagingRoots({
    bool requireSafeId = true,
  }) async {
    final root = await _stagingRoot();
    if (!await root.exists()) return const [];
    final entries = <({String profileId, Directory directory})>[];
    await for (final child in root.list(followLinks: false)) {
      if (child is! Directory) continue;
      final profileId = p.basename(child.path);
      if (requireSafeId &&
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(profileId)) {
        continue;
      }
      entries.add((profileId: profileId, directory: child));
    }
    entries.sort((left, right) => left.profileId.compareTo(right.profileId));
    return entries;
  }

  static Map<String, int> _counts(Iterable<String> values) {
    final result = <String, int>{};
    for (final value in values) {
      result[value] = (result[value] ?? 0) + 1;
    }
    return Map.fromEntries(
      result.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key)),
    );
  }

  static String _sanitizeErrorCode(String value) {
    const allowedPrefixes = [
      'auth.',
      'dataset.',
      'oauth.',
      'provider.',
      'remote.',
      'selected_folder.',
      'staging.',
      'sync.',
      'velock.',
    ];
    if (RegExp(r'^[a-z0-9._-]{1,96}$').hasMatch(value) &&
        allowedPrefixes.any(value.startsWith)) {
      return value;
    }
    return 'redacted.invalid_error_code';
  }
}
