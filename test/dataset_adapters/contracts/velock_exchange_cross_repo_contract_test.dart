import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';

void main() {
  test('frozen Exchange V1 contract covers every SPEC interface surface', () {
    final contract = _contract();
    expect(contract['contractId'], 'velock-exchange-v1');
    expect(
      contract['exchangeVersion'],
      VelockExchangeV1Contract.exchangeVersion,
    );
    final artifacts = contract['artifacts']! as Map<String, dynamic>;
    expect(
      artifacts['maxEnvelopeBytes'],
      VelockExchangeV1Contract.maxEnvelopeBytes,
    );
    expect(
      artifacts['maxOperationsCipherBytes'],
      VelockExchangeV1Contract.maxOperationsCipherBytes,
    );
    expect(
      artifacts['maxOperationsPerBatch'],
      VelockExchangeV1Contract.maxOperationsPerBatch,
    );
    expect(
      artifacts['maxBlobsPerBatch'],
      VelockExchangeV1Contract.maxBlobsPerBatch,
    );
    expect(artifacts['maxBlobCipherBytes'], isNull);
    expect(artifacts['blobRequirement'], 'unbounded-replayable-stream');

    for (final requiredSection in const [
      'protocol',
      'artifacts',
      'envelope',
      'identity',
      'pairingControlPlane',
      'sequence',
      'states',
      'readyMarker',
      'receipts',
      'errors',
      'platform',
      'conflictResolution',
    ]) {
      expect(contract, contains(requiredSection));
    }
    final conflict = contract['conflictResolution']! as Map<String, dynamic>;
    expect(
      conflict['controlVersion'],
      VelockExchangeV1Contract.conflictControlVersion,
    );
    expect(
      conflict['requestTtlSeconds'],
      VelockExchangeV1Contract.conflictRequestTtl.inSeconds,
    );
    expect(
      conflict['businessProof'],
      'receipt-may-be-signed-only-after-velock-durably-resolves-the-matching-local-conflict',
    );
    expect(conflict['syncMayResolveVelockBusinessData'], isFalse);
    final pairing = contract['pairingControlPlane']! as Map<String, dynamic>;
    expect(
      pairing['controlVersion'],
      VelockExchangeV1Contract.pairingControlVersion,
    );
    expect(pairing['signatureAlgorithm'], 'Ed25519');
    expect(pairing['userAuthorization'], 'required-in-unlocked-velock-app');
    expect(pairing['syncMayCreateProducerIdentityOrKey'], isFalse);
    expect(pairing['remoteMembersAutoTrusted'], isFalse);
  });

  test('Sync runtime and native configuration match the frozen contract', () {
    final platform = _contract()['platform']! as Map<String, dynamic>;
    final android = platform['android']! as Map<String, dynamic>;
    final apple = platform['apple']! as Map<String, dynamic>;
    expect(android['authority'], VelockExchangeV1Contract.androidAuthority);
    expect(
      android['companionPackage'],
      VelockExchangeV1Contract.androidCompanionPackage,
    );
    expect(android['syncPackage'], VelockExchangeV1Contract.androidSyncPackage);
    expect(android['permission'], VelockExchangeV1Contract.androidPermission);
    expect(
      android['flutterChannel'],
      VelockExchangeV1Contract.androidFlutterChannel,
    );
    expect(
      android['inboundArtifactTransport'],
      'content-provider-staging-file-descriptor',
    );
    expect(apple['appGroup'], VelockExchangeV1Contract.appleAppGroup);
    expect(
      apple['syncFlutterChannel'],
      VelockExchangeV1Contract.appleSyncFlutterChannel,
    );
    expect(
      apple['syncRootMethod'],
      VelockExchangeV1Contract.appleSyncRootMethod,
    );

    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/tech/windata/velock/sync/velock_sync/MainActivity.kt',
    ).readAsStringSync();
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    for (final value in [
      VelockExchangeV1Contract.androidSyncPackage,
      ...((android['releaseConfigKeys']! as List).cast<String>()),
    ]) {
      expect(gradle, contains(value));
    }
    expect(manifest, contains(VelockExchangeV1Contract.androidPermission));
    expect(activity, contains(VelockExchangeV1Contract.androidFlutterChannel));
    expect(activity, contains('writeInboxArtifactFromPath'));
    for (final method in [
      VelockExchangeV1Contract.androidPairingDescriptorMethod,
      VelockExchangeV1Contract.androidSubmitPairingRequestMethod,
      VelockExchangeV1Contract.androidQueryPairingResponseMethod,
      VelockExchangeV1Contract.androidAcknowledgePairingMethod,
    ]) {
      expect(activity, contains('"$method"'));
    }
    expect(activity, isNot(contains('putByteArray("bytes"')));
    for (final code in (_contract()['errors']! as List).cast<String>()) {
      expect(activity, contains('"$code"'));
    }
    expect(ios, contains(VelockExchangeV1Contract.appleSyncFlutterChannel));
    expect(ios, contains(VelockExchangeV1Contract.appleAppGroup));
  });

  test('strict structural parser accepts zero-chunk streamed blobs', () {
    final operations = Uint8List.fromList([1, 2, 3]);
    final blobId = 'ab-blob';
    final envelope = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'batchId': 'batch-1',
          'batchKind': 'incremental',
          'blobs': [
            {
              'blobId': blobId,
              'chunkSize': 0,
              'cipherSha256': sha256.convert([4, 5]).toString(),
              'cipherSize': 2,
              'logicalKey': 'velock-sync/v1/vault-1/blobs/ab/$blobId.blob',
              'protection': 'source-opaque',
            },
          ],
          'createdAt': '2026-07-18T00:00:00.000Z',
          'keyId': 'key-1',
          'operations': {
            'cipherSha256': sha256.convert(operations).toString(),
            'cipherSize': operations.length,
            'compression': 'none',
            'logicalName': 'operations.enc',
            'operationCount': 1,
          },
          'previousBatchId': null,
          'previousSequence': null,
          'protocol': 'velock-sync',
          'protocolVersion': 1,
          'sequence': 1,
          'signature': 'opaque-signature',
          'signatureAlgorithm': 'Ed25519',
          'sourceDeviceId': 'device-1',
          'vaultId': 'vault-1',
        }),
      ),
    );

    final parsed = VelockExchangeV1Contract.parseEnvelope(envelope);
    expect(parsed.batchId, 'batch-1');
    expect(parsed.blobs.single.chunkSize, 0);

    final unsupported = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(envelope)) as Map,
    )..['protocolVersion'] = 2;
    expect(
      () => VelockExchangeV1Contract.parseEnvelope(
        Uint8List.fromList(utf8.encode(jsonEncode(unsupported))),
      ),
      throwsFormatException,
    );
  });
}

Map<String, dynamic> _contract() =>
    jsonDecode(
          File(
            'test_vectors/velock_exchange_v1/interface_contract.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
