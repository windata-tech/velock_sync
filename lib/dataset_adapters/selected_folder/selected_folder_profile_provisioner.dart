import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/device_signing_key_store.dart';
import 'package:velock_sync/infrastructure/secure_storage/vault_key_store.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

/// Creates a Generic Vault profile after the OS grants a directory. Only
/// opaque secure-storage references are persisted in the resulting profile.
class SelectedFolderProfileProvisioner {
  SelectedFolderProfileProvisioner({
    required FolderAccessAuthorizer authorizer,
    required SelectedFolderSyncProfileRepository profiles,
    required SyncStateDatabase database,
    required VaultKeyStore vaultKeys,
    required DeviceSigningKeyStore signingKeys,
    Uuid? uuid,
    Random? random,
    DateTime Function()? now,
    Ed25519? ed25519,
  }) : _authorizer = authorizer,
       _profiles = profiles,
       _database = database,
       _vaultKeys = vaultKeys,
       _signingKeys = signingKeys,
       _uuid = uuid ?? const Uuid(),
       _random = random ?? Random.secure(),
       _now = now ?? DateTime.now,
       _ed25519 = ed25519 ?? Ed25519();

  final FolderAccessAuthorizer _authorizer;
  final SelectedFolderSyncProfileRepository _profiles;
  final SyncStateDatabase _database;
  final VaultKeyStore _vaultKeys;
  final DeviceSigningKeyStore _signingKeys;
  final Uuid _uuid;
  final Random _random;
  final DateTime Function() _now;
  final Ed25519 _ed25519;

  Future<SelectedFolderSyncProfile?> create({
    required String displayName,
    required String connectionId,
    required String deviceId,
    SyncProfileBackgroundPolicy backgroundPolicy =
        const SyncProfileBackgroundPolicy(),
    String keyId = 'key-1',
  }) async {
    _validateIdentifiers(
      displayName: displayName,
      connectionId: connectionId,
      deviceId: deviceId,
      keyId: keyId,
    );
    final access = await _authorizer.authorizeDirectory();
    if (access == null) return null;
    final rootKey = Uint8List.fromList(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    final rootKeyRef = await _vaultKeys.writeRootKey(rootKey);
    return _createForAuthorizedFolder(
      access: access,
      displayName: displayName,
      connectionId: connectionId,
      deviceId: deviceId,
      backgroundPolicy: backgroundPolicy,
      keyId: keyId,
      vaultId: _uuid.v4(),
      rootKeyRef: rootKeyRef,
    );
  }

  /// Adds a new local dataset to an existing Generic Vault after its root key
  /// was recovered through an explicit user-approved flow. This creates a new
  /// device signing identity; it never reuses another device's private key.
  Future<SelectedFolderSyncProfile?> createRecovered({
    required String displayName,
    required String connectionId,
    required String deviceId,
    required String vaultId,
    required String rootKeyRef,
    SyncProfileBackgroundPolicy backgroundPolicy =
        const SyncProfileBackgroundPolicy(),
    String keyId = 'key-1',
  }) async {
    _validateIdentifiers(
      displayName: displayName,
      connectionId: connectionId,
      deviceId: deviceId,
      keyId: keyId,
    );
    if (vaultId.isEmpty || rootKeyRef.isEmpty) {
      throw ArgumentError('Recovered Vault identifiers must not be empty.');
    }
    if (await _vaultKeys.readRootKey(rootKeyRef) == null) {
      throw StateError('Recovered Generic Vault root key is unavailable.');
    }
    final access = await _authorizer.authorizeDirectory();
    if (access == null) return null;
    return _createForAuthorizedFolder(
      access: access,
      displayName: displayName,
      connectionId: connectionId,
      deviceId: deviceId,
      backgroundPolicy: backgroundPolicy,
      keyId: keyId,
      vaultId: vaultId,
      rootKeyRef: rootKeyRef,
    );
  }

  Future<SelectedFolderSyncProfile> _createForAuthorizedFolder({
    required FolderAccessGrant access,
    required String displayName,
    required String connectionId,
    required String deviceId,
    required SyncProfileBackgroundPolicy backgroundPolicy,
    required String keyId,
    required String vaultId,
    required String rootKeyRef,
  }) async {
    String? signingKeyRef;
    var deviceTrusted = false;
    try {
      final signingKey = await _ed25519.newKeyPair();
      signingKeyRef = await _signingKeys.writeEd25519Key(signingKey);
      final profile = SelectedFolderSyncProfile(
        profileId: _uuid.v4(),
        datasetId: _uuid.v4(),
        vaultId: vaultId,
        deviceId: deviceId,
        displayName: displayName,
        rootPath: access.rootReference,
        accessKind: access.kind,
        backgroundEnabled: backgroundPolicy.enabled,
        backgroundAllowCellular: backgroundPolicy.allowCellular,
        backgroundRequiresCharging: backgroundPolicy.requiresCharging,
        backgroundCellularMaxTransferBytes:
            backgroundPolicy.cellularMaxTransferBytes,
        connectionId: connectionId,
        keyId: keyId,
        rootKeyRef: rootKeyRef,
        signingKeyRef: signingKeyRef,
        createdAt: _now().toUtc(),
      );
      final publicKey = await signingKey.extractPublicKey();
      await _database.trustDevice(
        vaultId: profile.vaultId,
        deviceId: deviceId,
        signingPublicKey: Uint8List.fromList(publicKey.bytes),
      );
      deviceTrusted = true;
      await _profiles.save(profile);
      return profile;
    } on Object {
      if (deviceTrusted) {
        await _database.revokeTrustedDevice(
          vaultId: vaultId,
          deviceId: deviceId,
        );
      }
      if (signingKeyRef != null) await _signingKeys.delete(signingKeyRef);
      await _vaultKeys.delete(rootKeyRef);
      rethrow;
    }
  }

  static void _validateIdentifiers({
    required String displayName,
    required String connectionId,
    required String deviceId,
    required String keyId,
  }) {
    if (displayName.isEmpty ||
        connectionId.isEmpty ||
        deviceId.isEmpty ||
        keyId.isEmpty) {
      throw ArgumentError('Profile identifiers must not be empty.');
    }
  }
}
