import 'dart:io';

import 'package:dio/dio.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/android_document_tree_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_batch_preparer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_incoming_applier.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_scanner.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/repository/connection_repository.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/device_signing_key_store.dart';
import 'package:velock_sync/infrastructure/secure_storage/vault_key_store.dart';
import 'package:velock_sync/infrastructure/staging/batch_staging_store.dart';
import 'package:velock_sync/infrastructure/storage/available_space_probe.dart';
import 'package:velock_sync/infrastructure/storage/staging_disk_preflight.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_batch_envelope.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_blob_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_operations_cipher.dart';
import 'package:velock_sync/sync_core/engine/generic_vault_batch_compiler.dart';
import 'package:velock_sync/sync_core/engine/device_membership_publisher.dart';
import 'package:velock_sync/sync_core/engine/initial_sync_assessment.dart';
import 'package:velock_sync/sync_core/engine/sync_profile_runner.dart';
import 'package:velock_sync/sync_core/engine/sync_download_engine.dart';
import 'package:velock_sync/sync_core/engine/vault_protocol.dart';

typedef SelectedFolderRemoteFactory =
    RemoteObjectStore Function({
      required WebDavProtocolModel protocol,
      required String? password,
    });

/// Reconstructs a complete generic-dataset sync run from local configuration.
/// It never serializes a root key, signing key, WebDAV password, or OAuth
/// token; all provider credentials stay behind [ConnectionRepository].
class SelectedFolderSyncService {
  SelectedFolderSyncService({
    required SyncStateDatabase database,
    required SelectedFolderSyncProfileRepository profiles,
    required ConnectionRepository connections,
    required VaultKeyStore vaultKeys,
    required DeviceSigningKeyStore signingKeys,
    required Directory stagingRoot,
    SyncProfileRunner? runner,
    SelectedFolderRemoteFactory? remoteFactory,
    AndroidDocumentTreeAccess? androidDocumentTrees,
    AppleSecurityScopedFolderAccess? appleFolders,
    AvailableSpaceProbe? availableSpace,
    int minimumFreeStagingBytes = 64 * 1024 * 1024,
  }) : _database = database,
       _profiles = profiles,
       _connections = connections,
       _vaultKeys = vaultKeys,
       _signingKeys = signingKeys,
       _stagingRoot = stagingRoot,
       _runner = runner ?? SyncProfileRunner(database),
       _remoteFactory = remoteFactory ?? _defaultRemoteFactory,
       _androidDocumentTrees =
           androidDocumentTrees ?? MethodChannelAndroidDocumentTreeAccess(),
       _appleFolders =
           appleFolders ?? const MethodChannelAppleSecurityScopedFolderAccess(),
       _diskPreflight = StagingDiskPreflight(
         availableSpace ?? const PlatformAvailableSpaceProbe(),
         minimumFreeBytes: minimumFreeStagingBytes,
       );

  final SyncStateDatabase _database;
  final SelectedFolderSyncProfileRepository _profiles;
  final ConnectionRepository _connections;
  final VaultKeyStore _vaultKeys;
  final DeviceSigningKeyStore _signingKeys;
  final Directory _stagingRoot;
  final SyncProfileRunner _runner;
  final SelectedFolderRemoteFactory _remoteFactory;
  final AndroidDocumentTreeAccess _androidDocumentTrees;
  final AppleSecurityScopedFolderAccess _appleFolders;
  final StagingDiskPreflight _diskPreflight;

  /// Inspects only the remote root state needed for a first-sync confirmation.
  /// The result has no remote names, paths, credentials, or content.
  Future<InitialSyncAssessment> inspectInitialSync(String profileId) async {
    final profile = await _profiles.read(profileId);
    if (profile == null) {
      throw StateError('Selected Folder sync profile not found.');
    }
    if (profile.state == SelectedFolderProfileState.paused) {
      throw StateError('Selected Folder sync profile is paused.');
    }
    final connection = await _connections.getConnectionById(
      profile.connectionId,
    );
    if (connection == null) {
      throw StateError('Selected Folder profile has no remote connection.');
    }
    return InitialSyncAssessor().assess(
      vaultId: profile.vaultId,
      remote: await _remoteForConnection(connection.protocol),
    );
  }

  Future<SyncProfileRunResult> run(
    String profileId, {
    BatchLimits uploadLimits = const BatchLimits(),
    DownloadLimits downloadLimits = const DownloadLimits(),
  }) async {
    final profile = await _profiles.read(profileId);
    if (profile == null) {
      throw StateError('Selected Folder sync profile not found.');
    }
    if (profile.state == SelectedFolderProfileState.paused) {
      throw StateError('Selected Folder sync profile is paused.');
    }
    final storageSession = await _storageFor(profile);
    final storage = storageSession.storage;
    final connection = await _connections.getConnectionById(
      profile.connectionId,
    );
    if (connection == null) {
      throw StateError('Selected Folder profile has no remote connection.');
    }
    final rootKey = await _vaultKeys.readRootKey(profile.rootKeyRef);
    final signingKey = await _signingKeys.readEd25519Key(profile.signingKeyRef);
    if (rootKey == null || signingKey == null) {
      throw StateError('Selected Folder profile key material is unavailable.');
    }
    final remote = await _remoteForConnection(connection.protocol);
    final keyDeriver = GenericVaultKeyDeriver(rootKey);
    final blobCipher = GenericVaultBlobCipher(
      keyDeriver: keyDeriver,
      keyId: profile.keyId,
    );
    final operationsCipher = GenericVaultOperationsCipher(
      keyDeriver: keyDeriver,
    );
    final envelopeSigner = GenericVaultBatchEnvelopeSigner();
    final staging = BatchStagingStore(
      Directory('${_stagingRoot.path}/${profile.profileId}'),
    );
    final compiler = GenericVaultBatchCompiler(
      operationsCipher: operationsCipher,
      envelopeSigner: envelopeSigner,
    );
    final adapter = SelectedFolderDatasetAdapter(
      datasetId: profile.datasetId,
      profileId: profile.profileId,
      vaultId: profile.vaultId,
      sourceDeviceId: profile.deviceId,
      displayName: profile.displayName,
      storage: storage,
      keyId: profile.keyId,
      signingKey: signingKey,
      database: _database,
      scanner: SelectedFolderScanner(_database),
      batchPreparer: SelectedFolderBatchPreparer(
        blobCipher: blobCipher,
        compiler: compiler,
        staging: staging,
      ),
      staging: staging,
      envelopeSigner: envelopeSigner,
      operationsCipher: operationsCipher,
      incomingApplier: SelectedFolderIncomingApplier(
        storage: storage,
        datasetId: profile.datasetId,
        profileId: profile.profileId,
        database: _database,
        blobCipher: blobCipher,
      ),
    );
    try {
      return await _runner.run(
        profileId: profile.profileId,
        vaultId: profile.vaultId,
        deviceId: profile.deviceId,
        protocol: VaultProtocolDocument(
          vaultId: profile.vaultId,
          createdAt: profile.createdAt,
        ),
        dataset: adapter,
        remote: remote,
        uploadLimits: uploadLimits,
        downloadLimits: downloadLimits,
        preflight: () async {
          await _diskPreflight.ensureAvailable(_stagingRoot);
        },
        postProtocolPreflight: () async {
          await DeviceMembershipPublisher(_database).ensureActive(
            vaultId: profile.vaultId,
            deviceId: profile.deviceId,
            signingKey: signingKey,
            remote: remote,
          );
        },
      );
    } finally {
      await storageSession.release();
    }
  }

  Future<RemoteObjectStore> _remoteForConnection(
    ProtocolModel protocol,
  ) async => switch (protocol) {
    WebDavProtocolModel(:final credentialRef) => _remoteFactory(
      protocol: protocol,
      password: await _connections.readWebDavPassword(credentialRef),
    ),
    OAuthProtocolModel() => _connections.createOAuthRemote(protocol),
  };

  Future<_SelectedFolderStorageSession> _storageFor(
    SelectedFolderSyncProfile profile,
  ) async {
    switch (profile.accessKind) {
      case FolderAccessKind.localPath:
        return _SelectedFolderStorageSession(
          LocalSelectedFolderStorage(Directory(profile.rootPath)),
        );
      case FolderAccessKind.androidDocumentTree:
        return _SelectedFolderStorageSession(
          AndroidDocumentTreeStorage(
            treeUri: profile.rootPath,
            access: _androidDocumentTrees,
          ),
        );
      case FolderAccessKind.appleSecurityScopedBookmark:
        final session = await _appleFolders.acquire(profile.rootPath);
        return _SelectedFolderStorageSession(
          LocalSelectedFolderStorage(Directory(session.path)),
          onRelease: () => _appleFolders.release(session.token),
        );
    }
  }

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
    final segments = <String>[
      ...address.pathSegments.where((segment) => segment.isNotEmpty),
      ...?Uri.tryParse(protocol.path ?? '')?.pathSegments.where(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      ),
    ];
    if (segments.length !=
        address.pathSegments.where((segment) => segment.isNotEmpty).length +
            (Uri.tryParse(protocol.path ?? '')?.pathSegments.length ?? 0)) {
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

class _SelectedFolderStorageSession {
  _SelectedFolderStorageSession(
    this.storage, {
    Future<void> Function()? onRelease,
  }) : _onRelease = onRelease;

  final SelectedFolderStorage storage;
  final Future<void> Function()? _onRelease;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _onRelease?.call();
  }
}
