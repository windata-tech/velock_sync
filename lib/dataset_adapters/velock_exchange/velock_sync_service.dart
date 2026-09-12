import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_discovery.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/storage/available_space_probe.dart';
import 'package:velock_sync/infrastructure/storage/staging_disk_preflight.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/sync_core/engine/join_approval_applier.dart';
import 'package:velock_sync/sync_core/engine/join_request_transport.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/sync_core/engine/sync_root_readme.dart';
import 'package:velock_sync/sync_core/engine/vault_protocol.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

typedef VelockRemoteFactory =
    RemoteObjectStore Function({
      required WebDavProtocolModel protocol,
      required String? password,
    });

/// Resolves an OAuth-backed provider through the same connection-owned remote
/// factory used by other datasets. The opaque credential reference remains
/// inside [ConnectionRepository]; this seam exists solely for provider-neutral
/// integration coverage.
typedef VelockOAuthRemoteFactory =
    RemoteObjectStore Function(OAuthProtocolModel protocol);

/// Narrow execution boundary used by the common profile dispatcher.
///
/// It intentionally exposes only profile IDs and transport limits; callers
/// cannot obtain a dataset adapter, a remote client, credentials, or Velock
/// data through this interface.
abstract interface class VelockSyncRunner {
  Future<SyncProfileRunResult> run(
    String profileId, {
    BatchLimits uploadLimits = const BatchLimits(),
    DownloadLimits downloadLimits = const DownloadLimits(),
  });
}

/// Reconstructs a Velock-managed sync run without crossing the Velock
/// zero-knowledge boundary. The service only passes opaque Exchange artifacts
/// between the trusted platform adapter and the standard Protocol V1 object
/// store; it never reads Velock key material or business data.
class VelockSyncService implements VelockSyncRunner {
  VelockSyncService({
    required SyncStateDatabase database,
    required SyncProfileRepository profiles,
    required ConnectionRepository connections,
    required VelockDatasetAdapterFactory adapterFactory,
    required Directory stagingRoot,
    SyncProfileRunner? runner,
    VelockRemoteFactory? remoteFactory,
    VelockOAuthRemoteFactory? oauthRemoteFactory,
    AvailableSpaceProbe? availableSpace,
    int minimumFreeStagingBytes = 64 * 1024 * 1024,
    DateTime Function()? now,
    String Function()? nextRunId,
  }) : _database = database,
       _profiles = profiles,
       _connections = connections,
       _adapterFactory = adapterFactory,
       _stagingRoot = stagingRoot,
       _runner = runner ?? SyncProfileRunner(database),
       _remoteFactory = remoteFactory ?? _defaultRemoteFactory,
       _oauthRemoteFactory =
           oauthRemoteFactory ?? connections.createOAuthRemote,
       _diskPreflight = StagingDiskPreflight(
         availableSpace ?? const PlatformAvailableSpaceProbe(),
         minimumFreeBytes: minimumFreeStagingBytes,
       ),
       _now = now ?? DateTime.now,
       _nextRunId = nextRunId ?? const Uuid().v4;

  final SyncStateDatabase _database;
  final SyncProfileRepository _profiles;
  final ConnectionRepository _connections;
  final VelockDatasetAdapterFactory _adapterFactory;
  final Directory _stagingRoot;
  final SyncProfileRunner _runner;
  final VelockRemoteFactory _remoteFactory;
  final VelockOAuthRemoteFactory _oauthRemoteFactory;
  final StagingDiskPreflight _diskPreflight;
  final DateTime Function() _now;
  final String Function() _nextRunId;

  @override
  Future<SyncProfileRunResult> run(
    String profileId, {
    BatchLimits uploadLimits = const BatchLimits(),
    DownloadLimits downloadLimits = const DownloadLimits(),
  }) async {
    // Failures raised while preparing the run (missing connection, revoked
    // pairing, unreachable remote during the root README write, …) happen
    // before the runner opens its own run row. Without this guard the attempt
    // would leave no trace in the run history while the overview kept showing
    // the previous successful run, which violates “status must be truthful”.
    var runnerStarted = false;
    try {
      final result = await _runPrepared(
        profileId,
        uploadLimits: uploadLimits,
        downloadLimits: downloadLimits,
        onRunnerStarted: () => runnerStarted = true,
      );
      return result;
    } on Object catch (error) {
      if (!runnerStarted) {
        await _recordPreRunFailure(profileId, error);
      }
      rethrow;
    }
  }

  Future<void> _recordPreRunFailure(String profileId, Object error) async {
    try {
      final runId = _nextRunId();
      await _database.startSyncRun(
        runId: runId,
        profileId: profileId,
        startedAt: _now(),
      );
      await _database.finishSyncRun(
        runId: runId,
        state: 'failed',
        completedAt: _now(),
        failure: SyncFailureClassifier.classify(error),
      );
    } on Object {
      // Recording history must never hide the original failure.
    }
  }

  Future<SyncProfileRunResult> _runPrepared(
    String profileId, {
    required BatchLimits uploadLimits,
    required DownloadLimits downloadLimits,
    required void Function() onRunnerStarted,
  }) async {
    final envelope = await _profiles.read(profileId);
    if (envelope == null) {
      throw StateError('Velock sync profile not found.');
    }
    final profile = VelockSyncProfile.fromEnvelope(envelope);
    if (profile.state != SyncProfileState.active) {
      throw StateError('Velock sync profile is not active.');
    }
    final connection = await _connections.getConnectionById(
      profile.connectionId,
    );
    if (connection == null) {
      throw StateError('Velock profile has no remote connection.');
    }

    // This must happen before any remote operation. Factory construction
    // revalidates package/App Group authorization and the locally paired
    // producer binding, failing closed after a revoke or configuration change.
    SyncDatasetAdapter dataset;
    try {
      dataset = await _adapterFactory.create(profile);
    } on VelockDatasetAdapterUnavailableException catch (error) {
      if (error.availability == VelockExchangeAvailability.accessRevoked ||
          error.availability ==
              VelockExchangeAvailability.authorizationRequired) {
        await _profiles.setState(profileId, SyncProfileState.accessRequired);
      }
      rethrow;
    }

    // The runner repeats this preflight after the sync run is recorded. This
    // early check deliberately comes before resolving credentials or creating
    // a remote client, so an insufficient local staging volume cannot cause
    // even protocol bootstrap traffic.
    await _diskPreflight.ensureAvailable(_stagingRoot);
    final remote = await _remoteForConnection(connection.protocol);
    await _publishRootReadme(remote: remote, profile: profile);
    // Best-effort exchange of signed join requests: peers surface new devices
    // for user approval, and this device publishes its own request. A failure
    // here must never block the sync run itself.
    var trustedProducerIds = profile.trustedProducerIds;
    if (dataset is VelockExchangeDatasetAdapter) {
      try {
        final exchangeRoot = dataset.exchangeRoot;
        final transport = JoinRequestTransport(exchangeRoot);
        await transport.uploadLocal(
          vaultId: profile.vaultId,
          remote: remote,
        );
        await transport.downloadRemote(
          vaultId: profile.vaultId,
          remote: remote,
        );
        // Apply user-approved decisions: the Velock app signs the updated
        // allow-list, and this machine merges it into the profile so the new
        // device's batches become downloadable here.
        final descriptorFile = File(
          '${exchangeRoot.path}/Control/descriptor.json',
        );
        if (await descriptorFile.exists()) {
          final descriptor = VelockPairingDescriptor.parse(
            await descriptorFile.readAsBytes(),
          );
          if (descriptor.exchangeBindingId == profile.exchangeBindingId) {
            trustedProducerIds = await JoinApprovalApplier(
              profiles: _profiles,
              database: _database,
            ).apply(
              profile: profile,
              exchangeRoot: exchangeRoot,
              velockSigningPublicKey: descriptor.producerSigningPublicKey,
            );
          }
        }
      } on Object {
        // Ignored on purpose.
      }
    }
    // The paired producer is the local Velock device. Its batches leave
    // through the outbox upload path; importing those same commits back into
    // the local inbox would create a self-download loop and a false recovery
    // prompt. Only historical/remote producers belong in the download list.
    final remoteProducerIds = trustedProducerIds
        .where((id) => id != profile.pairedProducerId)
        .toList(growable: false);
    onRunnerStarted();
    return _runner.run(
      profileId: profile.profileId,
      vaultId: profile.vaultId,
      deviceId: profile.deviceId,
      protocol: VaultProtocolDocument(
        vaultId: profile.vaultId,
        createdAt: profile.createdAt,
      ),
      dataset: dataset,
      remote: remote,
      uploadLimits: uploadLimits,
      downloadLimits: downloadLimits,
      preflight: () => _diskPreflight.ensureAvailable(_stagingRoot),
      // Pairing is the only local source of a Velock producer allow-list.
      trustedProducerDeviceIds: remoteProducerIds,
      enableGarbageCollection: true,
    );
  }

  Future<void> _publishRootReadme({
    required RemoteObjectStore remote,
    required VelockSyncProfile profile,
  }) async {
    final content = buildSyncRootReadme(
      vaultId: profile.vaultId,
      datasetId: profile.datasetId,
      displayName: profile.displayName,
      producerDeviceId: profile.pairedProducerId,
      consumerDeviceId: profile.deviceId,
      generatedAt: _now(),
    );
    final bytes = utf8.encode(content);
    await remote.put(
      LogicalKeys.readme(),
      Stream<List<int>>.value(bytes),
      contentLength: bytes.length,
    );
  }

  Future<RemoteObjectStore> _remoteForConnection(
    ProtocolModel protocol,
  ) async => switch (protocol) {
    WebDavProtocolModel(:final credentialRef) => _remoteFactory(
      protocol: protocol,
      password: await _connections.readWebDavPassword(credentialRef),
    ),
    OAuthProtocolModel() => _oauthRemoteFactory(protocol),
  };

  static RemoteObjectStore _defaultRemoteFactory({
    required WebDavProtocolModel protocol,
    required String? password,
  }) => WebDavObjectStore(
    dio: Dio(),
    baseUri: _webDavUri(protocol),
    username: protocol.username,
    password: password,
  );

  static Uri _webDavUri(WebDavProtocolModel protocol) {
    final address = Uri.tryParse(protocol.address);
    final port = int.tryParse(protocol.port);
    if (address == null || !address.hasAuthority || port == null || port < 1) {
      throw ArgumentError.value(protocol.address, 'protocol', 'is invalid');
    }
    final providerPath = Uri.tryParse(protocol.path ?? '');
    final segments = <String>[
      ...address.pathSegments.where((segment) => segment.isNotEmpty),
      ...?providerPath?.pathSegments.where(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      ),
    ];
    final expectedSegmentCount =
        address.pathSegments.where((segment) => segment.isNotEmpty).length +
        (providerPath?.pathSegments.length ?? 0);
    if (segments.length != expectedSegmentCount) {
      throw ArgumentError.value(protocol.path, 'protocol.path', 'is invalid');
    }
    return address.replace(
      scheme: protocol.protocolType.name,
      port: port,
      pathSegments: segments,
      query: null,
      fragment: null,
    );
  }
}
