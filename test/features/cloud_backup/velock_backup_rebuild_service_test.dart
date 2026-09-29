import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_companion_capabilities.dart';
import '../../dataset_adapters/velock_exchange/velock_companion_capabilities_fixture.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_current_snapshot_transport.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_dataset_adapter_factory.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_store.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_snapshot_control_files.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/features/cloud_backup/application/velock_backup_rebuild_service.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/engine/sync_upload_engine.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  late Directory temp, exchange;
  late SyncStateDatabase db;
  late SyncProfileRepository profiles;
  late VelockBackupRebuildService service;
  late VelockBackupRebuildJobs jobs;
  late _Factory factory;
  late _Remote remote;
  late SimpleKeyPair signing;
  final now = DateTime.utc(2026, 9, 27);
  final profile = VelockSyncProfile(
    profileId: 'p',
    datasetId: 'dataset',
    vaultId: '00000000-0000-4000-8000-000000000001',
    deviceId: 'sync',
    displayName: 'Backup',
    connectionId: 'nas',
    pairedProducerId: 'producer',
    pairedProducerPublicKeyId: '00000000-0000-4000-8000-000000000002',
    exchangeBindingId: 'a' * 43,
    remoteRootSegments: ['old'],
    backgroundPolicy: const SyncProfileBackgroundPolicy(),
    state: SyncProfileState.active,
    createdAt: now,
  );
  late List<Uri> launches;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rebuild-service-');
    exchange = await Directory('${temp.path}/exchange').create();
    db = await SyncStateDatabase.inMemory();
    profiles = SyncProfileRepository(db);
    await profiles.save(profile.toEnvelope());
    signing = await Ed25519().newKeyPair();
    await db.trustDevice(
      vaultId: profile.vaultId,
      deviceId: 'producer',
      signingPublicKey: Uint8List.fromList(
        (await signing.extractPublicKey()).bytes,
      ),
    );
    remote = _Remote();
    launches = [];
    factory = _Factory(
      VelockExchangeDatasetAdapter(
        datasetId: profile.datasetId,
        vaultId: profile.vaultId,
        producerDeviceId: 'producer',
        displayName: 'Backup',
        exchange: VelockExchangeStore(exchange),
      ),
    );
    jobs = VelockBackupRebuildJobs(Directory('${temp.path}/jobs'));
    var serial = 0;
    service = VelockBackupRebuildService(
      database: db,
      profiles: profiles,
      adapterFactory: factory,
      jobs: jobs,
      openRemote: (connection, segments) async {
        expect(connection, 'nas');
        expect(segments, ['new']);
        return remote;
      },
      launchVelock: (uri) async {
        launches.add(uri);
        return true;
      },
      now: () => now,
      nextId: () => 'request-${++serial}',
    );
    final recovery = File(
      '${exchange.path}/Recovery/Outgoing/${profile.vaultId}.json',
    );
    await recovery.parent.create(recursive: true);
    await recovery.writeAsString(
      jsonEncode({
        'format': 'velock-cloud-recovery',
        'version': 1,
        'lookup': 'b' * 64,
        'vaultId': profile.vaultId,
        'keyId': profile.pairedProducerPublicKeyId,
        'code': 'VSR1-opaque-test-only',
      }),
    );
    await writeVelockCompanionCapabilities(exchange);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<VelockBackupRebuildJob> start() => service.start(
    expected: profile.toEnvelope(),
    destination: ['new'],
    destinationLabel: '/NAS/new',
  );
  Future<void> approve(VelockBackupRebuildJob job, {KeyPair? signer}) async {
    final payload = Uint8List.fromList([1, 2, 3, 4]);
    final body = {
      'kind': VelockSnapshotInventory.kind,
      'version': 2,
      'snapshotId': job.request.snapshotId,
      'vaultId': profile.vaultId,
      'producerId': 'producer',
      'keyId': profile.pairedProducerPublicKeyId,
      'createdAt': now.toIso8601String(),
      'recordCount': 1,
      'heads': {
        'producer': {'sequence': 8, 'batchId': 'old8'},
      },
      'parts': [
        {
          'number': 1,
          'size': payload.length,
          'sha256': sha256.convert(payload).toString(),
          'records': 1,
        },
      ],
      'blobs': [],
    };
    final sig = await Ed25519().sign([
      ...utf8.encode('VelockCurrentStateSnapshot/2\n'),
      ...snapshotJson(body),
    ], keyPair: signing);
    final manifest = snapshotJson({
      ...body,
      'signature': base64UrlEncode(sig.bytes),
    });
    final commit = snapshotJson({
      'kind': VelockSnapshotInventory.kind,
      'version': 2,
      'snapshotId': job.request.snapshotId,
      'vaultId': profile.vaultId,
      'manifestSha256': sha256.convert(manifest).toString(),
    });
    final dir = await Directory(
      '${exchange.path}/Snapshots/Local/${job.request.snapshotId}',
    ).create(recursive: true);
    for (final e in {
      'manifest.json': manifest,
      'commit.json': commit,
      'part-1.enc': payload,
    }.entries) {
      await File('${dir.path}/${e.key}').writeAsBytes(e.value);
    }
    final receipt = await SnapshotControlReceipt.sign(
      request: job.request,
      manifestHash: sha256.convert(manifest).toString(),
      approvedAt: now,
      completedAt: now,
      signingKey: signer ?? signing,
    );
    await SnapshotControlFiles(
      exchange,
    ).publish('SnapshotReceipts', job.request.requestId, receipt.encode());
  }

  Future<void> unchanged() async => expect(
    (await profiles.read('p'))!.toJson(),
    profile.toEnvelope().toJson(),
  );
  test(
    'an older Velock without the capability descriptor cannot start a rebuild',
    () async {
      await File('${exchange.path}/Control/Capabilities.json').delete();
      await expectLater(start(), throwsA(isA<VelockUpdateRequired>()));
      await unchanged();
      expect(remote.puts, isEmpty);
      expect(await jobs.read('p'), isNull);
      expect(Directory('${exchange.path}/Control/SnapshotRequests').existsSync(), isFalse);
    },
  );
  test(
    'choice is durable but does not change profile or write remote; opening is explicit',
    () async {
      final job = await start();
      await unchanged();
      expect(remote.puts, isEmpty);
      expect(launches, isEmpty);
      expect((await jobs.read('p'))!.encode(), job.encode());
      expect(await service.isReady(job), false);
      await service.open(job);
      expect(
        launches.single.toString(),
        'velock://sync-snapshot?requestId=${job.request.requestId}',
      );
      await expectLater(service.finish(job), throwsStateError);
      await unchanged();
      expect(remote.puts, isEmpty);
    },
  );
  test(
    'full upload/readback precedes profile switch; retains identity, cursors and original history',
    () async {
      for (var sequence = 1; sequence <= 8; sequence++) {
        await db.advanceAppliedSequence(
          profileId: 'p',
          producerDeviceId: 'producer',
          sequence: sequence,
        );
      }
      final job = await start();
      await approve(job);
      expect(await service.isReady(job), true);
      remote.onPut = (_) async => unchanged();
      final saved = await service.finish(job);
      final parsed = VelockSyncProfile.fromEnvelope(saved);
      expect(parsed.remoteRootSegments, ['new']);
      expect(parsed.currentSnapshotId, job.request.snapshotId);
      expect(parsed.currentSnapshotProducerId, 'producer');
      expect(parsed.vaultId, profile.vaultId);
      expect(parsed.trustedProducerIds, profile.trustedProducerIds);
      expect(
        await db.appliedSequence(profileId: 'p', producerDeviceId: 'producer'),
        8,
      );
      expect(remote.puts.last, endsWith('/commit.json'));
      final snapshotReads = remote.reads
          .where((key) => key.contains('/current-snapshots/'))
          .toList();
      expect(snapshotReads, hasLength(3));
      expect(snapshotReads.toSet(), hasLength(3));
      final run = (await db.listRecentSyncRuns(profileId: 'p')).single;
      expect(run.state, 'completed');
      expect(run.rebuild!.objectCount, 3);
      final artifacts = Directory(
        '${exchange.path}/Snapshots/Local/${job.request.snapshotId}',
      );
      var expectedBytes = 0;
      await for (final file in artifacts.list()) {
        expectedBytes += await (file as File).length();
      }
      expect(run.rebuild!.totalBytes, expectedBytes);
      expect(run.rebuild!.recovered, false);
      expect(run.completedAt, parsed.locationChangedAt);
      expect(
        (await db.latestSyncRun('p'))!.rebuild!.encode(),
        run.rebuild!.encode(),
      );
      await service.recoverCompletedHistory('p');
      expect(await db.listRecentSyncRuns(profileId: 'p'), hasLength(1));
      expect((await service.finish(job)).toJson(), saved.toJson());
      expect((await jobs.read('p'))!.request.digest, job.request.digest);
    },
  );
  test(
    'interrupted upload leaves original profile; fresh service job retries exact bytes',
    () async {
      final job = await start();
      await approve(job);
      remote.failPart = true;
      await expectLater(service.finish(job), throwsStateError);
      await unchanged();
      expect(
        (await remote.list()).items.any(
          (e) => e.logicalKey.endsWith('/commit.json'),
        ),
        false,
      );
      expect(await db.listRecentSyncRuns(profileId: 'p'), isEmpty);
      remote.failPart = false;
      final saved = await service.finish((await jobs.read('p'))!);
      expect(
        VelockSyncProfile.fromEnvelope(saved).currentSnapshotId,
        job.request.snapshotId,
      );
      expect(
        remote.puts.where((k) => k == 'velock-rebuild.json'),
        hasLength(1),
      );
    },
  );
  test(
    'nonempty destination, including arriving after consent, never receives backup writes',
    () async {
      final job = await start();
      await approve(job);
      await remote.put(
        'someone-elses-data',
        Stream.value([1]),
        contentLength: 1,
      );
      remote.puts.clear();
      await expectLater(service.finish(job), throwsStateError);
      await unchanged();
      expect(remote.puts, isEmpty);
      await expectLater(start(), throwsStateError);
    },
  );
  test(
    'old successful switch recovers signed history once without remote access',
    () async {
      final job = await start();
      await approve(job);
      await profiles.save(
        profile
            .copyWith(
              remoteRootSegments: job.destination,
              locationChangedAt: now,
              currentSnapshotId: job.request.snapshotId,
              currentSnapshotProducerId: 'producer',
            )
            .toEnvelope(),
      );
      expect(await db.listRecentSyncRuns(profileId: 'p'), isEmpty);
      await service.recoverCompletedHistory('p');
      final run = (await db.listRecentSyncRuns(profileId: 'p')).single;
      expect(run.rebuild!.recovered, true);
      expect(run.rebuild!.objectCount, 3);
      expect(run.completedAt, now);
      expect(remote.puts, isEmpty);
      await service.recoverCompletedHistory('p');
      expect(await db.listRecentSyncRuns(profileId: 'p'), hasLength(1));
    },
  );
  test(
    'preparation alone and a different destination cannot recover success',
    () async {
      final job = await start();
      await approve(job);
      await service.recoverCompletedHistory('p');
      expect(await db.listRecentSyncRuns(profileId: 'p'), isEmpty);
      await profiles.save(
        profile
            .copyWith(
              remoteRootSegments: ['different'],
              locationChangedAt: now,
              currentSnapshotId: job.request.snapshotId,
              currentSnapshotProducerId: 'producer',
            )
            .toEnvelope(),
      );
      await service.recoverCompletedHistory('p');
      expect(await db.listRecentSyncRuns(profileId: 'p'), isEmpty);
    },
  );
  test('forged old evidence cannot recover a successful record', () async {
    final job = await start();
    await approve(job, signer: await Ed25519().newKeyPair());
    await profiles.save(
      profile
          .copyWith(
            remoteRootSegments: job.destination,
            locationChangedAt: now,
            currentSnapshotId: job.request.snapshotId,
            currentSnapshotProducerId: 'producer',
          )
          .toEnvelope(),
    );
    await expectLater(
      service.recoverCompletedHistory('p'),
      throwsFormatException,
    );
    expect(await db.listRecentSyncRuns(profileId: 'p'), isEmpty);
  });
  for (final suffix in ['part-1.enc', 'manifest.json', 'commit.json']) {
    test(
      'corrupt remote $suffix still prevents location switch and success',
      () async {
        final job = await start();
        await approve(job);
        remote.corruptReadSuffix = suffix;
        await expectLater(service.finish(job), throwsFormatException);
        await unchanged();
        expect(await db.listRecentSyncRuns(profileId: 'p'), isEmpty);
      },
    );
  }
  test('forged completion cannot upload or change destination', () async {
    final job = await start();
    await approve(job, signer: await Ed25519().newKeyPair());
    await expectLater(service.finish(job), throwsFormatException);
    await unchanged();
    expect(remote.puts, isEmpty);
  });
  test('damaged content withholds commit and profile change', () async {
    final job = await start();
    await approve(job);
    await File(
      '${exchange.path}/Snapshots/Local/${job.request.snapshotId}/part-1.enc',
    ).writeAsBytes([9, 9, 9, 9]);
    await expectLater(service.finish(job), throwsFormatException);
    await unchanged();
    expect(remote.puts.any((k) => k.endsWith('/commit.json')), false);
  });
  test(
    'profile removed during upload is never recreated by late completion',
    () async {
      final job = await start();
      await approve(job);
      remote.onPut = (key) async {
        if (key.endsWith('/commit.json')) await profiles.remove('p');
      };
      await expectLater(service.finish(job), throwsStateError);
      expect(await profiles.read('p'), isNull);
    },
  );
  test('authorization revoked during upload cannot finalize', () async {
    final job = await start();
    await approve(job);
    remote.onPut = (key) async {
      if (key.endsWith('/commit.json')) factory.revoked = true;
    };
    await expectLater(service.finish(job), throwsStateError);
    await unchanged();
  });
  test('destination remains leased while upload is blocked', () async {
    final job = await start();
    await approve(job);
    final entered = Completer<void>(), release = Completer<void>();
    remote.onPut = (key) async {
      if (key.endsWith('/part-1.enc')) {
        entered.complete();
        await release.future;
      }
    };
    final running = service.finish(job);
    await entered.future;
    try {
      await expectLater(
        profiles.selectOriginalVelockFolder(
          expected: profile.toEnvelope(),
          segments: ['elsewhere'],
        ),
        throwsA(isA<SyncRunBusyException>()),
      );
    } finally {
      release.complete();
    }
    await running;
  });
}

class _Factory implements VelockDatasetAdapterFactory {
  _Factory(this.adapter);
  final SyncDatasetAdapter adapter;
  bool revoked = false;
  @override
  Future<SyncDatasetAdapter> create(VelockSyncProfile profile) async {
    if (revoked) throw StateError('revoked');
    return adapter;
  }
}

class _Remote extends InMemoryObjectStore {
  final puts = <String>[];
  final reads = <String>[];
  String? corruptReadSuffix;
  @override
  Stream<List<int>> read(
    String key, {
    int? start,
    int? endInclusive,
    RemoteOperationCancellation? cancellation,
  }) {
    reads.add(key);
    if (corruptReadSuffix != null && key.endsWith('/$corruptReadSuffix')) {
      return Stream.value([0]);
    }
    return super.read(
      key,
      start: start,
      endInclusive: endInclusive,
      cancellation: cancellation,
    );
  }

  bool failPart = false;
  Future<void> Function(String)? onPut;
  @override
  Future<RemoteObjectMetadata> put(
    String key,
    Stream<List<int>> content, {
    required int contentLength,
    bool ifAbsent = false,
    RemoteOperationCancellation? cancellation,
  }) async {
    if (failPart && key.endsWith('/part-1.enc')) throw StateError('offline');
    final result = await super.put(
      key,
      content,
      contentLength: contentLength,
      ifAbsent: ifAbsent,
      cancellation: cancellation,
    );
    puts.add(key);
    await onPut?.call(key);
    return result;
  }
}
