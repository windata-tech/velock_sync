import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_exchange_root.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/apple_velock_conflict_gateway.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_conflict_control_plane.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_service.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';

void main() {
  group('AppleVelockConflictGateway', () {
    late Directory root;
    late SyncStateDatabase database;
    late SimpleKeyPair signingKey;
    late DateTime now;
    late List<Uri> launches;
    late AppleVelockConflictGateway gateway;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('velock-conflict-control-');
      database = await SyncStateDatabase.inMemory();
      signingKey = await Ed25519().newKeyPairFromSeed(
        List<int>.generate(32, (index) => index + 1),
      );
      await database.trustDevice(
        vaultId: 'vault-1',
        deviceId: 'producer-1',
        signingPublicKey: Uint8List.fromList(
          (await signingKey.extractPublicKey()).bytes,
        ),
      );
      now = DateTime.utc(2026, 7, 18, 8);
      launches = [];
      gateway = AppleVelockConflictGateway(
        database: database,
        rootLocator: AppleExchangeRootLocator(
          channel: _RootChannel(root.path),
          isApplePlatform: () => true,
        ),
        launchVelock: (uri) async {
          launches.add(uri);
          return true;
        },
        nextChallenge: () => 'challenge-1',
        now: () => now,
      );
    });

    tearDown(() async {
      await database.close();
      await root.delete(recursive: true);
    });

    test(
      'writes an opaque request before opening the Velock deep link',
      () async {
        await expectLater(
          gateway.open(profile: _profile(), conflict: _conflict()),
          throwsA(
            isA<ConflictResolutionFailure>().having(
              (error) => error.code,
              'code',
              'velock-resolution-pending',
            ),
          ),
        );

        expect(launches, hasLength(1));
        expect(launches.single.scheme, 'velock');
        expect(launches.single.host, 'sync-conflict');
        final request = await _storedRequest(root);
        expect(launches.single.queryParameters['requestId'], request.requestId);
        expect(request.conflictId, 'conflict-1');
        expect(request.vaultId, 'vault-1');
        final raw = await File(
          '${root.path}/Control/ConflictRequests/${request.requestId}.json',
        ).readAsString();
        expect(raw, isNot(contains('protected')));
        expect(raw, isNot(contains('plaintext')));
      },
    );

    test(
      'verifies only an exact receipt signed by the paired producer',
      () async {
        await _beginPending(gateway);
        final request = await _storedRequest(root);
        final receipt = await _signedReceipt(request, signingKey, now);
        final receiptFile = File(
          '${root.path}/Control/ConflictReceipts/${request.requestId}.json',
        );
        await receiptFile.parent.create(recursive: true);
        await receiptFile.writeAsBytes(receipt.encode(), flush: true);

        final opened = await gateway.open(
          profile: _profile(),
          conflict: _conflict(),
        );
        expect(
          await gateway.verify(
            profile: _profile(),
            conflict: _conflict(),
            receipt: opened,
          ),
          isTrue,
        );

        final tampered = VelockConflictResolutionReceipt(
          '${opened.artifact.substring(0, opened.artifact.length - 1)}'
          '${opened.artifact.endsWith('A') ? 'B' : 'A'}',
        );
        expect(
          await gateway.verify(
            profile: _profile(),
            conflict: _conflict(),
            receipt: tampered,
          ),
          isFalse,
        );
      },
    );

    test(
      'acknowledges only after verification and removes live artifacts',
      () async {
        await _beginPending(gateway);
        final request = await _storedRequest(root);
        final receipt = await _signedReceipt(request, signingKey, now);
        final receiptFile = File(
          '${root.path}/Control/ConflictReceipts/${request.requestId}.json',
        );
        await receiptFile.parent.create(recursive: true);
        await receiptFile.writeAsBytes(receipt.encode(), flush: true);
        final opened = await gateway.open(
          profile: _profile(),
          conflict: _conflict(),
        );

        await gateway.acknowledge(
          profile: _profile(),
          conflict: _conflict(),
          receipt: opened,
        );

        expect(
          await File(
            '${root.path}/Control/ConflictConsumed/${request.requestId}.json',
          ).exists(),
          isTrue,
        );
        expect(
          await File(
            '${root.path}/Control/ConflictRequests/${request.requestId}.json',
          ).exists(),
          isFalse,
        );
        expect(await receiptFile.exists(), isFalse);
      },
    );
  });
}

Future<void> _beginPending(AppleVelockConflictGateway gateway) async {
  try {
    await gateway.open(profile: _profile(), conflict: _conflict());
  } on ConflictResolutionFailure catch (error) {
    expect(error.code, 'velock-resolution-pending');
  }
}

Future<VelockConflictControlRequest> _storedRequest(Directory root) async {
  final directory = Directory('${root.path}/Control/ConflictRequests');
  final files = await directory
      .list()
      .where((entity) => entity is File)
      .cast<File>()
      .toList();
  expect(files, hasLength(1));
  return VelockConflictControlRequest.parse(await files.single.readAsBytes());
}

Future<VelockConflictControlReceipt> _signedReceipt(
  VelockConflictControlRequest request,
  SimpleKeyPair signingKey,
  DateTime now,
) async {
  final draft = VelockConflictControlReceipt(
    requestId: request.requestId,
    challenge: request.challenge,
    conflictId: request.conflictId,
    vaultId: request.vaultId,
    producerId: request.producerId,
    producerPublicKeyId: request.producerPublicKeyId,
    exchangeBindingId: request.exchangeBindingId,
    syncAppInstanceId: request.syncAppInstanceId,
    resolutionArtifactId: 'resolution-1',
    resolvedAt: now.add(const Duration(minutes: 1)),
    expiresAt: request.expiresAt,
    signature: Uint8List(64),
  );
  final signature = await Ed25519().sign(
    draft.signaturePayload(),
    keyPair: signingKey,
  );
  return VelockConflictControlReceipt(
    requestId: draft.requestId,
    challenge: draft.challenge,
    conflictId: draft.conflictId,
    vaultId: draft.vaultId,
    producerId: draft.producerId,
    producerPublicKeyId: draft.producerPublicKeyId,
    exchangeBindingId: draft.exchangeBindingId,
    syncAppInstanceId: draft.syncAppInstanceId,
    resolutionArtifactId: draft.resolutionArtifactId,
    resolvedAt: draft.resolvedAt,
    expiresAt: draft.expiresAt,
    signature: Uint8List.fromList(signature.bytes),
  );
}

SyncProfileEnvelope _profile() => SyncProfileEnvelope(
  kind: SyncDatasetKind.velockManaged,
  profileId: 'profile-1',
  datasetId: 'vault-1',
  vaultId: 'vault-1',
  deviceId: 'sync-instance-1',
  displayName: 'Velock',
  connectionId: 'connection-1',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: const {
    'pairedProducerId': 'producer-1',
    'pairedProducerPublicKeyId': 'key-1',
    'exchangeBindingId': 'binding-1',
  },
  createdAt: DateTime.utc(2026, 7, 18),
);

SyncConflictRecord _conflict() => SyncConflictRecord(
  conflictId: 'conflict-1',
  profileId: 'profile-1',
  entityId: 'entity-1',
  sourceDeviceId: 'remote-1',
  type: 'concurrent',
  protectedDetails: null,
  createdAt: DateTime.utc(2026, 7, 18),
);

class _RootChannel implements AppleExchangeRootChannel {
  const _RootChannel(this.path);

  final String path;

  @override
  Future<String?> readExchangeRoot() async => path;
}
