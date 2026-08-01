import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_profile_provisioner.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_device_signing_key_store.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_vault_key_store.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

void main() {
  test(
    'provisions opaque key references only after folder authorization',
    () async {
      final root = await Directory.systemTemp.createTemp('velock-provision-');
      final database = await SyncStateDatabase.inMemory();
      addTearDown(() async {
        await root.delete(recursive: true);
        await database.close();
      });
      final provisioner = SelectedFolderProfileProvisioner(
        authorizer: _Authorizer(root),
        profiles: SelectedFolderSyncProfileRepository(database),
        database: database,
        vaultKeys: InMemoryVaultKeyStore(),
        signingKeys: InMemoryDeviceSigningKeyStore(),
        now: () => DateTime.utc(2026, 7, 15),
      );

      final profile = await provisioner.create(
        displayName: 'Documents',
        connectionId: 'connection-1',
        deviceId: 'device-1',
        backgroundPolicy: const SyncProfileBackgroundPolicy(
          allowCellular: true,
          requiresCharging: true,
          cellularMaxTransferBytes: 10 * 1024 * 1024,
        ),
      );

      expect(profile!.rootKeyRef, startsWith('velock-sync/vault-root/'));
      expect(profile.signingKeyRef, startsWith('velock-sync/device-signing/'));
      expect(profile.backgroundAllowCellular, isTrue);
      expect(profile.backgroundRequiresCharging, isTrue);
      expect(profile.backgroundCellularMaxTransferBytes, 10 * 1024 * 1024);
      expect(
        (await SelectedFolderSyncProfileRepository(
          database,
        ).read(profile.profileId))!.rootPath,
        root.path,
      );
      expect(
        (await database.readTrustedDevicePublicKeys(
          vaultId: profile.vaultId,
        )).keys,
        ['device-1'],
      );
    },
  );

  test(
    'provisions a new local signing identity for a recovered Generic Vault',
    () async {
      final root = await Directory.systemTemp.createTemp('velock-recover-');
      final database = await SyncStateDatabase.inMemory();
      final keys = InMemoryVaultKeyStore();
      addTearDown(() async {
        await root.delete(recursive: true);
        await database.close();
      });
      final rootKeyRef = await keys.writeRootKey(
        Uint8List.fromList(List<int>.filled(32, 7)),
      );
      final profile =
          await SelectedFolderProfileProvisioner(
            authorizer: _Authorizer(root),
            profiles: SelectedFolderSyncProfileRepository(database),
            database: database,
            vaultKeys: keys,
            signingKeys: InMemoryDeviceSigningKeyStore(),
          ).createRecovered(
            displayName: 'Recovered Documents',
            connectionId: 'connection-1',
            deviceId: 'new-device',
            vaultId: 'existing-vault',
            rootKeyRef: rootKeyRef,
            recoveredTrustedDevices: {
              'existing-device': Uint8List.fromList(List<int>.filled(32, 9)),
            },
          );

      expect(profile!.vaultId, 'existing-vault');
      expect(profile.rootKeyRef, rootKeyRef);
      expect(profile.signingKeyRef, startsWith('velock-sync/device-signing/'));
      expect(
        (await database.readTrustedDevicePublicKeys(
          vaultId: 'existing-vault',
        )).keys,
        ['existing-device', 'new-device'],
      );
    },
  );
}

class _Authorizer implements FolderAccessAuthorizer {
  const _Authorizer(this.root);
  final Directory root;
  @override
  Future<FolderAccessGrant?> authorizeDirectory() async =>
      FolderAccessGrant.localPath(root);
}
