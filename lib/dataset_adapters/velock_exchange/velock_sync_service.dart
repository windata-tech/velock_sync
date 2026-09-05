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
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
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
  }) : _profiles = profiles,
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
       );

  final SyncProfileRepository _profiles;
  final ConnectionRepository _connections;
  final VelockDatasetAdapterFactory _adapterFactory;
  final Directory _stagingRoot;
  final SyncProfileRunner _runner;
  final VelockRemoteFactory _remoteFactory;
  final VelockOAuthRemoteFactory _oauthRemoteFactory;
  final StagingDiskPreflight _diskPreflight;

  @override
  Future<SyncProfileRunResult> run(
    String profileId, {
    BatchLimits uploadLimits = const BatchLimits(),
    DownloadLimits downloadLimits = const DownloadLimits(),
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
      trustedProducerDeviceIds: [profile.pairedProducerId],
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
