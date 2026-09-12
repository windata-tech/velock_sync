import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/engine/join_approval_applier.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

const _vaultId = '374d09fc-0375-4a6f-8284-26bf29ac276d';
const _localProducer = '6b71c91c-1604-45dc-91c4-fe54ae27d432';
const _joinedProducer = 'a202a0b1-f5f1-4b15-9e61-f932ab019e02';

VelockSyncProfile _profile() => VelockSyncProfile(
  profileId: 'profile-1',
  datasetId: _vaultId,
  vaultId: _vaultId,
  deviceId: '8c4dead2-81f1-4c4b-9cc6-66dcf7a50c11',
  displayName: 'velock profile',
  connectionId: 'connection-1',
  pairedProducerId: _localProducer,
  pairedProducerPublicKeyId: 'key-1',
  exchangeBindingId: 'binding-1',
  trustedProducerIds: const [_localProducer],
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  state: SyncProfileState.active,
  createdAt: DateTime.utc(2026, 9, 11),
);

Future<Uint8List> _signedApproval(List<String> trusted, SimpleKeyPair key) async {
  const unsigned = <String, Object?>{
    'version': 1,
    'vaultId': _vaultId,
    'deviceId': _joinedProducer,
    'signingPublicKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'approvedBy': _localProducer,
    'trustedProducerIds': <String>[],
    'approvedAt': '2026-09-11T02:00:00.000Z',
    'signatureAlgorithm': 'Ed25519',
  };
  final payload = <String, Object?>{...unsigned, 'trustedProducerIds': trusted};
  final sorted = <String, Object?>{
    for (final key in payload.keys.toList()..sort()) key: payload[key],
  };
  final signature = await Ed25519().sign(
    utf8.encode(jsonEncode(sorted)),
    keyPair: key,
  );
  return Uint8List.fromList(
    utf8.encode(jsonEncode({...payload, 'signature': base64UrlEncode(signature.bytes)})),
  );
}

void main() {
  test('merges a verified approval into the profile allow-list', () async {
    final database = await SyncStateDatabase.inMemory();
    final profiles = SyncProfileRepository(database);
    final profile = _profile();
    await profiles.save(profile.toEnvelope());
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();

    final root = await Directory.systemTemp.createTemp('velock-approval-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final approvals = Directory('${root.path}/Control/JoinApprovals');
    await approvals.create(recursive: true);
    await File('${approvals.path}/$_joinedProducer.json').writeAsBytes(
      await _signedApproval([_localProducer, _joinedProducer], keyPair),
    );

    final expectedKey = Uint8List.fromList(
      base64Url.decode('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='),
    );
    final merged = await JoinApprovalApplier(profiles: profiles, database: database).apply(
      profile: profile,
      exchangeRoot: root,
      velockSigningPublicKey: base64UrlEncode(publicKey.bytes),
    );
    expect(merged, containsAll([_localProducer, _joinedProducer]));
    // The approved device key must be stored so batch signatures verify.
    final trusted = await database.readTrustedDevicePublicKeys(
      vaultId: _vaultId,
    );
    expect(trusted[_joinedProducer], expectedKey);
    final persisted = await profiles.read('profile-1');
    expect(persisted, isNotNull);
    final reloaded = VelockSyncProfile.fromEnvelope(persisted!);
    expect(reloaded.trustedProducerIds, contains(_joinedProducer));
  });

  test('rejects approvals signed by another key or for another vault', () async {
    final database = await SyncStateDatabase.inMemory();
    final profiles = SyncProfileRepository(database);
    final profile = _profile();
    await profiles.save(profile.toEnvelope());
    final keyPair = await Ed25519().newKeyPair();
    final otherKeyPair = await Ed25519().newKeyPair();
    final otherPublicKey = await otherKeyPair.extractPublicKey();

    final root = await Directory.systemTemp.createTemp('velock-approval-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final approvals = Directory('${root.path}/Control/JoinApprovals');
    await approvals.create(recursive: true);
    await File('${approvals.path}/$_joinedProducer.json').writeAsBytes(
      await _signedApproval([_localProducer, _joinedProducer], keyPair),
    );

    // Wrong verifying key: nothing is merged.
    final rejected = await JoinApprovalApplier(profiles: profiles, database: database).apply(
      profile: profile,
      exchangeRoot: root,
      velockSigningPublicKey: base64UrlEncode(otherPublicKey.bytes),
    );
    expect(rejected, [_localProducer]);

    // A different vault id in the approval is ignored even with a valid key.
    final publicKey = await keyPair.extractPublicKey();
    final otherVault = jsonDecode(
      utf8.decode(
        await File('${approvals.path}/$_joinedProducer.json').readAsBytes(),
      ),
    ) as Map<String, dynamic>;
    otherVault['vaultId'] = '314c1fdb-3e04-41eb-a7c1-17904d767062';
    await File('${approvals.path}/$_joinedProducer.json').writeAsString(
      jsonEncode(otherVault),
    );
    final stillRejected = await JoinApprovalApplier(profiles: profiles, database: database).apply(
      profile: profile,
      exchangeRoot: root,
      velockSigningPublicKey: base64UrlEncode(publicKey.bytes),
    );
    expect(stillRejected, [_localProducer]);
  });

  test('keeps the profile unchanged when no approval exists', () async {
    final database = await SyncStateDatabase.inMemory();
    final profiles = SyncProfileRepository(database);
    final profile = _profile();
    await profiles.save(
      SyncProfileEnvelope(
        kind: SyncDatasetKind.velockManaged,
        profileId: profile.profileId,
        datasetId: profile.datasetId,
        vaultId: profile.vaultId,
        deviceId: profile.deviceId,
        displayName: profile.displayName,
        connectionId: profile.connectionId,
        state: profile.state,
        backgroundPolicy: profile.backgroundPolicy,
        dataset: const {
          'pairedProducerId': _localProducer,
          'pairedProducerPublicKeyId': 'key-1',
          'exchangeBindingId': 'binding-1',
          'trustedProducerIds': [_localProducer],
        },
        createdAt: profile.createdAt,
      ),
    );
    final root = await Directory.systemTemp.createTemp('velock-approval-');
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final merged = await JoinApprovalApplier(profiles: profiles, database: database).apply(
      profile: VelockSyncProfile.fromEnvelope(
        (await profiles.read('profile-1'))!,
      ),
      exchangeRoot: root,
      velockSigningPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    expect(merged, [_localProducer]);
  });
}
