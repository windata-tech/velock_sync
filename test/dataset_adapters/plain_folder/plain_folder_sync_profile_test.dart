import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_sync_profile.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';

/// A complete dataset block: one local folder mirrored to `phone/photos`.
const _fullDataset = <String, Object?>{
  'accessKind': 'androidDocumentTree',
  'localRootReference':
      'content://com.android.externalstorage.documents/tree/primary%3APhotos',
  'localDisplayName': 'Photos (phone)',
  'remoteRootSegments': <String>['phone', 'photos'],
  'direction': 'uploadOnly',
  'conflictPolicy': 'preferLocal',
  'initialSyncPolicy': 'localWins',
};

const _fullBackground = <String, Object?>{
  'enabled': true,
  'allowCellular': true,
  'requiresCharging': true,
  'cellularMaxTransferBytes': 10 * 1024 * 1024,
};

const _createdAtIso = '2026-09-19T08:30:00.000Z';

/// One persisted V1 envelope, with every field overridable so a single case
/// can be made invalid without losing the rest of the document.
Map<String, dynamic> _envelope({
  Object? kind = 'plain-folder',
  Object? vaultId = '',
  Object? state = 'active',
  Object? profileId = 'profile-1',
  Object? datasetId = 'dataset-1',
  Object? deviceId = 'device-1',
  Object? displayName = 'Photos',
  Object? connectionId = 'connection-1',
  Object? createdAt = _createdAtIso,
  Object? background = _fullBackground,
  Map<String, Object?>? dataset,
}) => <String, dynamic>{
  'schemaVersion': 1,
  'kind': kind,
  'profileId': profileId,
  'datasetId': datasetId,
  'vaultId': vaultId,
  'deviceId': deviceId,
  'displayName': displayName,
  'connectionId': connectionId,
  'state': state,
  'background': background,
  'dataset': dataset ?? _fullDataset,
  'createdAt': createdAt,
};

PlainFolderSyncProfile _profile({
  String profileId = 'profile-1',
  String displayName = 'Photos',
  PlainFolderProfileState state = PlainFolderProfileState.active,
}) => PlainFolderSyncProfile(
  profileId: profileId,
  datasetId: 'dataset-1',
  deviceId: 'device-1',
  displayName: displayName,
  localRootReference: '/Users/example/Pictures/Photos',
  localDisplayName: 'Photos',
  connectionId: 'connection-1',
  remoteRootSegments: const ['phone', 'photos'],
  createdAt: DateTime.utc(2026, 9, 19, 8, 30),
  state: state,
);

void main() {
  group('PlainFolderSyncProfile envelope round-trip', () {
    test('keeps every field and the stable plain-folder kind', () {
      final profile = PlainFolderSyncProfile.fromJson(_envelope());

      expect(profile.profileId, 'profile-1');
      expect(profile.datasetId, 'dataset-1');
      expect(profile.deviceId, 'device-1');
      expect(profile.displayName, 'Photos');
      expect(profile.localRootReference, _fullDataset['localRootReference']);
      expect(profile.localDisplayName, 'Photos (phone)');
      expect(profile.accessKind, FolderAccessKind.androidDocumentTree);
      expect(profile.connectionId, 'connection-1');
      expect(profile.remoteRootSegments, ['phone', 'photos']);
      expect(profile.direction, MirrorDirection.uploadOnly);
      expect(profile.conflictPolicy, MirrorConflictPolicy.preferLocal);
      expect(profile.initialSyncPolicy, MirrorInitialSyncPolicy.localWins);
      expect(profile.backgroundEnabled, isTrue);
      expect(profile.backgroundAllowCellular, isTrue);
      expect(profile.backgroundRequiresCharging, isTrue);
      expect(profile.backgroundCellularMaxTransferBytes, 10 * 1024 * 1024);
      expect(profile.state, PlainFolderProfileState.active);
      expect(profile.isActive, isTrue);
      expect(profile.createdAt, DateTime.utc(2026, 9, 19, 8, 30));
      expect(profile.createdAt.isUtc, isTrue);

      final json = profile.toJson();
      expect(json['schemaVersion'], 1);
      expect(json['kind'], 'plain-folder');
      expect(json['kind'], SyncDatasetKind.plainFolder.persistedValue);
      expect(json['vaultId'], isEmpty);
      expect(json['state'], 'active');
      expect(json['createdAt'], _createdAtIso);
      expect(json['background'], _fullBackground);
      expect(json['dataset'], _fullDataset);
      expect(profile.toEnvelope().kind, SyncDatasetKind.plainFolder);

      final restored = PlainFolderSyncProfile.fromJson(json);
      expect(jsonEncode(restored.toJson()), jsonEncode(json));
      expect(restored.toJson(), profile.toJson());
    });

    test('applies documented defaults to a minimal legacy payload', () {
      final profile = PlainFolderSyncProfile.fromJson(
        _envelope(
          dataset: const {'localRootReference': '/storage/emulated/0/Photos'},
          background: null,
        ),
      );

      expect(profile.direction, MirrorDirection.bidirectional);
      expect(profile.conflictPolicy, MirrorConflictPolicy.keepBoth);
      expect(profile.initialSyncPolicy, MirrorInitialSyncPolicy.merge);
      expect(profile.remoteRootSegments, isEmpty);
      expect(profile.accessKind, FolderAccessKind.localPath);
      // A payload written before the local name existed reuses the title.
      expect(profile.localDisplayName, 'Photos');
      expect(profile.backgroundEnabled, isFalse);
      expect(profile.backgroundAllowCellular, isFalse);
      expect(profile.backgroundRequiresCharging, isFalse);
      expect(
        profile.backgroundCellularMaxTransferBytes,
        defaultBackgroundCellularMaxTransferBytes,
      );

      final dataset = profile.toJson()['dataset'] as Map<String, Object?>;
      expect(dataset['accessKind'], 'localPath');
      expect(dataset['direction'], 'bidirectional');
      expect(dataset['conflictPolicy'], 'keepBoth');
      expect(dataset['initialSyncPolicy'], 'merge');
      expect(dataset['remoteRootSegments'], isEmpty);
      expect(dataset['localDisplayName'], 'Photos');
      expect(dataset['localRootReference'], '/storage/emulated/0/Photos');
    });

    test('keeps an empty remote scope at the connection root', () {
      final profile = PlainFolderSyncProfile.fromJson(
        _envelope(
          dataset: const {
            'localRootReference': '/safe/photos',
            'remoteRootSegments': <String>[],
          },
        ),
      );

      expect(profile.remoteRootSegments, isEmpty);
      expect(
        PlainFolderSyncProfile.remoteLocationLabel(
          'NAS',
          profile.remoteRootSegments,
        ),
        'NAS',
      );
      expect(
        PlainFolderSyncProfile.remoteLocationLabel('NAS', const [
          'phone',
          'photos',
        ]),
        'NAS · /phone/photos',
      );
    });

    test('keeps the paused lifecycle state across a round-trip', () {
      final profile = PlainFolderSyncProfile.fromJson(
        _envelope(
          state: 'paused',
          dataset: const {'localRootReference': '/safe/photos'},
        ),
      );

      expect(profile.state, PlainFolderProfileState.paused);
      expect(profile.isActive, isFalse);
      expect(profile.toJson()['state'], 'paused');
    });
  });

  group('PlainFolderSyncProfile payload validation', () {
    test('rejects a payload that is not a plain folder location', () {
      expect(
        () => PlainFolderSyncProfile.fromJson(
          _envelope(kind: 'selected-folder', vaultId: 'vault-1'),
        ),
        throwsFormatException,
      );
      expect(
        () => PlainFolderSyncProfile.fromJson(
          _envelope(kind: 'velock-managed', vaultId: 'vault-1'),
        ),
        throwsFormatException,
      );
      expect(
        () =>
            PlainFolderSyncProfile.fromJson(_envelope(kind: 'plain-folder-v2')),
        throwsA(isA<UnsupportedSyncProfileEnvelopeException>()),
      );
    });

    test('rejects a remote scope that is not a string list', () {
      for (final scope in const <Object>[
        'photos',
        <Object>[1, 2],
        <Object>['photos', 3],
        {'segment': 'photos'},
      ]) {
        expect(
          () => PlainFolderSyncProfile.fromJson(
            _envelope(
              dataset: <String, Object?>{
                'localRootReference': '/safe/photos',
                'remoteRootSegments': scope,
              },
            ),
          ),
          throwsFormatException,
          reason: 'remote scope $scope must be rejected',
        );
      }
    });

    test('rejects unsafe remote scope segments', () {
      for (final scope in const <List<String>>[
        ['..'],
        ['photos', '..'],
        [''],
        ['photos', ''],
        ['/'],
        ['.'],
        ['photos/sub'],
        ['photos\\sub'],
      ]) {
        expect(
          () => PlainFolderSyncProfile.fromJson(
            _envelope(
              dataset: <String, Object?>{
                'localRootReference': '/safe/photos',
                'remoteRootSegments': scope,
              },
            ),
          ),
          throwsFormatException,
          reason: 'remote scope $scope must be rejected',
        );
      }
    });

    test('rejects unknown option names and non-string options', () {
      for (final dataset in const <Map<String, Object>>[
        {'localRootReference': '/safe/photos', 'direction': 'twoWay'},
        {'localRootReference': '/safe/photos', 'direction': 'bothWays'},
        {'localRootReference': '/safe/photos', 'conflictPolicy': 'keepNewest'},
        {'localRootReference': '/safe/photos', 'conflictPolicy': 'rename'},
        {
          'localRootReference': '/safe/photos',
          'initialSyncPolicy': 'overwrite',
        },
        {'localRootReference': '/safe/photos', 'accessKind': 'cloudPath'},
        {'localRootReference': '/safe/photos', 'direction': 3},
        {'localRootReference': '/safe/photos', 'conflictPolicy': true},
      ]) {
        expect(
          () => PlainFolderSyncProfile.fromJson(_envelope(dataset: dataset)),
          throwsFormatException,
          reason: '$dataset must be rejected',
        );
      }
    });

    test('rejects a payload without a usable local root reference', () {
      for (final dataset in const <Map<String, Object?>>[
        {
          'remoteRootSegments': <String>['photos'],
        },
        {'localRootReference': ''},
        {'localRootReference': 42},
        {'localRootReference': null},
      ]) {
        expect(
          () => PlainFolderSyncProfile.fromJson(_envelope(dataset: dataset)),
          throwsFormatException,
          reason: '$dataset must be rejected',
        );
      }
    });

    test('rejects a non-string local display name or dataset block', () {
      expect(
        () => PlainFolderSyncProfile.fromJson(
          _envelope(
            dataset: const {
              'localRootReference': '/safe/photos',
              'localDisplayName': 7,
            },
          ),
        ),
        throwsFormatException,
      );

      final notAnObject = _envelope()..['dataset'] = 'photos';
      expect(
        () => PlainFolderSyncProfile.fromJson(notAnObject),
        throwsFormatException,
      );
    });
  });

  group('SyncProfileEnvelope vaultId rule', () {
    test('accepts an empty vaultId for a plain folder location only', () {
      final envelope = SyncProfileEnvelope.fromJson(
        _envelope(kind: 'plain-folder', vaultId: ''),
      );
      expect(envelope.kind, SyncDatasetKind.plainFolder);
      expect(envelope.vaultId, isEmpty);
      expect(envelope.dataset['localRootReference'], isNotNull);

      // The same document with a vault still parses for the encrypted kinds,
      // so the rejection below is specifically about the empty vaultId.
      for (final kind in const ['selected-folder', 'velock-managed']) {
        expect(
          SyncProfileEnvelope.fromJson(
            _envelope(kind: kind, vaultId: 'vault-1'),
          ).vaultId,
          'vault-1',
        );
        expect(
          () =>
              SyncProfileEnvelope.fromJson(_envelope(kind: kind, vaultId: '')),
          throwsFormatException,
          reason: '$kind must name its vault',
        );
      }
    });

    test('rejects a missing or non-string vaultId for every kind', () {
      for (final kind in const [
        'plain-folder',
        'selected-folder',
        'velock-managed',
      ]) {
        for (final vaultId in const <Object?>[null, 7]) {
          expect(
            () => SyncProfileEnvelope.fromJson(
              _envelope(kind: kind, vaultId: vaultId),
            ),
            throwsFormatException,
            reason: '$kind with vaultId $vaultId must be rejected',
          );
        }
        final missing = _envelope(kind: kind)..remove('vaultId');
        expect(
          () => SyncProfileEnvelope.fromJson(missing),
          throwsFormatException,
          reason: '$kind without vaultId must be rejected',
        );
      }
    });

    test('keeps the persisted kind value stable and unambiguous', () {
      expect(SyncDatasetKind.plainFolder.persistedValue, 'plain-folder');
      expect(
        SyncDatasetKind.tryParse('plain-folder'),
        SyncDatasetKind.plainFolder,
      );
      expect(SyncDatasetKind.tryParse('plainFolder'), isNull);
      expect(SyncDatasetKind.tryParse('plain-folder-v2'), isNull);
      expect(SyncDatasetKind.tryParse(null), isNull);
    });
  });

  group('PlainFolderSyncProfileRepository', () {
    late SyncStateDatabase database;
    late PlainFolderSyncProfileRepository repository;

    setUp(() async {
      database = await SyncStateDatabase.inMemory();
      repository = PlainFolderSyncProfileRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('saves, reads and lists one plain folder location', () async {
      final profile = _profile();
      await repository.save(profile);

      final stored = await repository.read(profile.profileId);
      expect(stored, isNotNull);
      expect(stored!.toJson(), profile.toJson());
      expect(stored.connectionId, 'connection-1');
      expect(stored.remoteRootSegments, ['phone', 'photos']);
      expect((await repository.list()).single.profileId, profile.profileId);

      final payload =
          jsonDecode(
                (await database.readSyncProfilePayload(profile.profileId))!,
              )
              as Map<String, dynamic>;
      expect(payload['kind'], 'plain-folder');
      expect(payload['vaultId'], isEmpty);
      expect(payload['connectionId'], 'connection-1');
      expect(
        (payload['dataset'] as Map<String, dynamic>)['localRootReference'],
        profile.localRootReference,
      );

      expect(await repository.read('missing-profile'), isNull);
    });

    test('lists only plain folder locations', () async {
      await repository.save(_profile());
      final selectedFolder = SelectedFolderSyncProfile(
        profileId: 'selected-1',
        datasetId: 'dataset-2',
        vaultId: 'vault-1',
        deviceId: 'device-1',
        displayName: 'Documents',
        rootPath: '/safe/documents',
        connectionId: 'connection-1',
        keyId: 'key-1',
        rootKeyRef: 'velock-sync/vault-root/opaque',
        signingKeyRef: 'velock-sync/device-signing/opaque',
        createdAt: DateTime.utc(2026, 9, 19, 9),
      );
      await SelectedFolderSyncProfileRepository(database).save(selectedFolder);

      expect((await repository.list()).map((p) => p.profileId), ['profile-1']);
      expect(await repository.read(selectedFolder.profileId), isNull);
      // The existing surface keeps working the other way round too: a plain
      // folder payload is not mistaken for a Selected Folder profile.
      expect(
        (await SelectedFolderSyncProfileRepository(
          database,
        ).list()).map((p) => p.profileId),
        ['selected-1'],
      );
    });

    test('skips payloads it cannot own instead of breaking the list', () async {
      await repository.save(_profile());
      // A row whose envelope names a different profile must not be adopted.
      await database.upsertSyncProfilePayload(
        profileId: 'row-foreign',
        datasetId: 'dataset-1',
        targetId: 'connection-1',
        vaultId: '',
        state: 'active',
        payload: jsonEncode(_profile(profileId: 'profile-other').toJson()),
      );
      // A future kind must not make the whole screen unusable.
      await database.upsertSyncProfilePayload(
        profileId: 'row-future',
        datasetId: 'dataset-1',
        targetId: 'connection-1',
        vaultId: '',
        state: 'active',
        payload: jsonEncode(_envelope(kind: 'plain-folder-v2')),
      );

      expect((await repository.list()).map((p) => p.profileId), ['profile-1']);
      expect(await repository.read('row-foreign'), isNull);
      expect(await repository.read('row-future'), isNull);
    });

    test(
      'a malformed row is skipped, logged by id and never hides the others',
      () async {
        await repository.save(_profile());
        // A row whose payload cannot be decoded at all: the UI must keep the
        // other locations, but the vanished one has to be observable.
        await database.upsertSyncProfilePayload(
          profileId: 'row-broken',
          datasetId: 'dataset-1',
          targetId: 'connection-1',
          vaultId: '',
          state: 'active',
          payload: '{"kind": "plain-folder", "profileId": ',
        );

        final lines = <String>[];
        final previousLogger = logger;
        logger = Logger(
          output: _CapturingLogOutput(lines),
          filter: ProductionFilter(),
        );
        addTearDown(() => logger = previousLogger);

        expect((await repository.list()).map((p) => p.profileId), [
          'profile-1',
        ]);
        expect(await repository.read('row-broken'), isNull);

        expect(
          lines.where((line) => line.contains('row-broken')),
          isNotEmpty,
          reason: 'the skipped location is logged with its id',
        );
        final report = lines.join('\n');
        expect(
          report.contains('localRootReference') ||
              report.contains('rootReference'),
          isFalse,
          reason: 'no payload contents and no user paths end up in the log',
        );
      },
    );

    test('pauses and resumes one location', () async {
      await repository.save(_profile());

      await repository.pause('profile-1');
      final paused = (await repository.read('profile-1'))!;
      expect(paused.state, PlainFolderProfileState.paused);
      expect(paused.isActive, isFalse);
      // A paused location stays visible until it is removed.
      expect((await repository.list()).single.isActive, isFalse);

      await repository.resume('profile-1');
      final resumed = (await repository.read('profile-1'))!;
      expect(resumed.state, PlainFolderProfileState.active);
      expect(resumed.isActive, isTrue);
    });

    test(
      'lets the database lifecycle state override a stale payload state',
      () async {
        await repository.save(_profile(state: PlainFolderProfileState.paused));
        // The payload still says paused after a resume.
        final payloadBefore =
            jsonDecode((await database.readSyncProfilePayload('profile-1'))!)
                as Map<String, dynamic>;
        expect(payloadBefore['state'], 'paused');

        await repository.resume('profile-1');

        expect(
          (await repository.read('profile-1'))!.state,
          PlainFolderProfileState.active,
        );
        final payloadAfter =
            jsonDecode((await database.readSyncProfilePayload('profile-1'))!)
                as Map<String, dynamic>;
        expect(payloadAfter['state'], 'paused');
      },
    );

    test('removes one location while keeping its durable payload', () async {
      await repository.save(_profile());

      await repository.remove('profile-1');

      expect(await repository.read('profile-1'), isNull);
      expect(await repository.list(), isEmpty);
      expect(await database.readSyncProfilePayload('profile-1'), isNotNull);
      await expectLater(repository.resume('profile-1'), throwsStateError);
    });

    test('refuses to remove a location that is still running', () async {
      await repository.save(_profile());
      await database.startSyncRun(
        runId: 'run-1',
        profileId: 'profile-1',
        startedAt: DateTime.utc(2026, 9, 19, 10),
      );

      await expectLater(repository.remove('profile-1'), throwsStateError);
      expect(await repository.read('profile-1'), isNotNull);
    });

    test('applies one confirmed edit and keeps every other field', () async {
      final profile = _profile();
      await repository.save(profile);
      final expected = (await repository.read('profile-1'))!;

      final updated = await repository.update(
        expected,
        (current) => current.copyWith(
          displayName: 'Photos (new)',
          localDisplayName: 'Photos (new)',
          remoteRootSegments: const ['phone', 'photos', '2026'],
          conflictPolicy: MirrorConflictPolicy.preferRemote,
        ),
      );

      expect(updated.displayName, 'Photos (new)');
      expect(updated.remoteRootSegments, ['phone', 'photos', '2026']);
      expect(updated.conflictPolicy, MirrorConflictPolicy.preferRemote);

      final reloaded = (await repository.read('profile-1'))!;
      expect(reloaded.toJson(), updated.toJson());
      expect(reloaded.localRootReference, profile.localRootReference);
      expect(reloaded.connectionId, profile.connectionId);
      expect(reloaded.datasetId, profile.datasetId);
      expect(reloaded.profileId, profile.profileId);
      expect(reloaded.createdAt, profile.createdAt);
      expect(reloaded.state, PlainFolderProfileState.active);
    });

    test('rejects a stale snapshot and keeps the stored location', () async {
      await repository.save(_profile());
      final stale = (await repository.read('profile-1'))!;
      await repository.update(
        stale,
        (current) => current.copyWith(displayName: 'Second'),
      );

      await expectLater(
        repository.update(
          stale,
          (current) => current.copyWith(displayName: 'Third'),
        ),
        throwsStateError,
      );
      expect((await repository.read('profile-1'))!.displayName, 'Second');
    });

    test('rejects a running location', () async {
      await repository.save(_profile());
      final expected = (await repository.read('profile-1'))!;
      await database.startSyncRun(
        runId: 'run-1',
        profileId: 'profile-1',
        startedAt: DateTime.utc(2026, 9, 19, 10),
      );

      await expectLater(
        repository.update(
          expected,
          (current) => current.copyWith(displayName: 'While running'),
        ),
        throwsStateError,
      );
      expect((await repository.read('profile-1'))!.displayName, 'Photos');
    });

    test('rejects an edit for a missing location', () async {
      await expectLater(
        repository.update(
          _profile(profileId: 'never-saved'),
          (current) => current,
        ),
        throwsStateError,
      );
    });

    test('keeps a paused location editable', () async {
      await repository.save(_profile());
      await repository.pause('profile-1');
      final paused = (await repository.read('profile-1'))!;

      // Pausing stops transfers; it must not freeze the settings the user may
      // still want to correct (or block resuming through an edit).
      final updated = await repository.update(
        paused,
        (current) => current.copyWith(displayName: 'x'),
      );
      expect(updated.displayName, 'x');
      expect(
        (await repository.read('profile-1'))!.state,
        PlainFolderProfileState.paused,
      );
    });

    test(
      'relocation moves the folder and drops the old mirror state at once',
      () async {
        final profile = _profile();
        await repository.save(profile);
        // A finished location: baseline rows, a conflict log and a run row.
        await database.upsertMirrorEntries(profile.profileId, [
          MirrorBaselineEntry(
            relativePath: 'phone/photos/a.jpg',
            kind: MirrorEntryKind.file,
            localSize: 3,
            remoteSize: 3,
            syncedAt: DateTime.utc(2026, 9, 19, 9),
          ),
        ]);
        await database.recordMirrorConflicts(profile.profileId, [
          MirrorPlannedConflict(
            relativePath: 'phone/photos/a.jpg',
            kind: MirrorConflictKind.bothModified,
            resolution: MirrorConflictResolution.keepBoth,
          ),
        ], detectedAt: DateTime.utc(2026, 9, 19, 9));
        await database.saveMirrorRunStats(
          MirrorRunStats(
            runId: 'run-before',
            profileId: profile.profileId,
            startedAt: DateTime.utc(2026, 9, 19, 9),
            uploadedFileCount: 1,
          ),
        );
        final stored = (await repository.read(profile.profileId))!;

        final relocated = await repository.relocate(
          stored,
          (current) => current.copyWith(
            localRootReference: '/Users/example/Pictures/New',
            remoteRootSegments: const ['phone', 'new'],
          ),
        );

        expect(relocated.localRootReference, '/Users/example/Pictures/New');
        expect(relocated.remoteRootSegments, ['phone', 'new']);
        // The stored payload is the new binding...
        final reread = (await repository.read(profile.profileId))!;
        expect(reread.localRootReference, '/Users/example/Pictures/New');
        expect(reread.remoteRootSegments, ['phone', 'new']);
        // ...and nothing of the old folders is left to plan deletions with.
        expect(await database.readMirrorEntries(profile.profileId), isEmpty);
        expect(await database.readMirrorConflicts(profile.profileId), isEmpty);
        expect(
          await database.readLatestMirrorRunStats(profile.profileId),
          isNull,
        );
      },
    );

    test(
      'relocation can keep the baseline when the folders did not move',
      () async {
        final profile = _profile();
        await repository.save(profile);
        await database.upsertMirrorEntries(profile.profileId, [
          MirrorBaselineEntry(
            relativePath: 'phone/photos/a.jpg',
            kind: MirrorEntryKind.file,
            syncedAt: DateTime.utc(2026, 9, 19, 9),
          ),
        ]);
        final stored = (await repository.read(profile.profileId))!;

        await repository.relocate(
          stored,
          (current) => current.copyWith(displayName: 'Photos (renamed)'),
          resetBaseline: false,
        );

        expect((await database.readMirrorEntries(profile.profileId)).keys, [
          'phone/photos/a.jpg',
        ]);
        expect(
          (await repository.read(profile.profileId))!.displayName,
          'Photos (renamed)',
        );
      },
    );

    test(
      'a refused remote probe leaves the location and its baseline alone',
      () async {
        final profile = _profile();
        await repository.save(profile);
        await database.upsertMirrorEntries(profile.profileId, [
          MirrorBaselineEntry(
            relativePath: 'phone/photos/a.jpg',
            kind: MirrorEntryKind.file,
            syncedAt: DateTime.utc(2026, 9, 19, 9),
          ),
        ]);
        final stored = (await repository.read(profile.profileId))!;

        await expectLater(
          repository.relocate(
            stored,
            (current) =>
                current.copyWith(remoteRootSegments: const ['phone', 'x']),
            confirmRemoteWrite: (_) async =>
                throw const PlainFolderSyncException(
                  SyncFailure(
                    errorCode: 'plain_folder.remote_folder_unwritable',
                    category: SyncErrorCategory.permissionRequired,
                    retryable: false,
                    suggestedAction: '远端文件夹不存在或这个账号不能写入。',
                  ),
                ),
          ),
          throwsA(isA<PlainFolderSyncException>()),
        );

        final after = (await repository.read(profile.profileId))!;
        expect(after.remoteRootSegments, ['phone', 'photos']);
        expect(
          await database.readMirrorEntries(profile.profileId),
          hasLength(1),
          reason: 'a refused relocation never drops the baseline',
        );
      },
    );

    test('a stale relocation snapshot is refused', () async {
      final profile = _profile();
      await repository.save(profile);
      final stale = (await repository.read(profile.profileId))!;
      // Somebody else saved an edit in the meantime.
      await repository.update(
        stale,
        (current) => current.copyWith(displayName: 'Photos (newer)'),
      );

      await expectLater(
        repository.relocate(
          stale,
          (current) =>
              current.copyWith(remoteRootSegments: const ['elsewhere']),
        ),
        throwsStateError,
      );
      expect((await repository.read(profile.profileId))!.remoteRootSegments, [
        'phone',
        'photos',
      ]);
    });

    test('refuses to persist an unsafe remote scope', () async {
      await repository.save(_profile());
      final expected = (await repository.read('profile-1'))!;

      await expectLater(
        repository.update(
          expected,
          (current) => current.copyWith(remoteRootSegments: const ['..']),
        ),
        throwsFormatException,
      );
      expect((await repository.read('profile-1'))!.remoteRootSegments, [
        'phone',
        'photos',
      ]);
    });
  });
}

/// Collects the log lines a test wants to assert on.
class _CapturingLogOutput extends LogOutput {
  _CapturingLogOutput(this.lines);

  final List<String> lines;

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}
