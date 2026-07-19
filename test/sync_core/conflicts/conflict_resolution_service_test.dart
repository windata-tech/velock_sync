import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_service.dart';
import 'package:velock_sync/sync_core/conflicts/conflict_resolution_strategy.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

void main() {
  group('DurableConflictResolutionService', () {
    late SyncStateDatabase database;
    late SyncProfileRepository profiles;

    setUp(() async {
      database = await SyncStateDatabase.inMemory();
      profiles = SyncProfileRepository(database);
    });

    tearDown(() => database.close());

    test(
      'fails closed for a missing conflict without creating an intent',
      () async {
        final result = await _service(database, profiles).resolve(
          conflictId: 'missing-conflict',
          strategy: ConflictResolutionStrategy.keepLocal,
        );

        expect(result.status, ConflictResolutionStatus.missing);
        expect(
          await database.readConflictResolutionIntent('missing-conflict'),
          isNull,
        );
      },
    );

    test('rejects unavailable profiles without creating an intent', () async {
      await _recordConflict(database, profileId: 'unavailable-profile');

      final result = await _service(database, profiles).resolve(
        conflictId: 'conflict-1',
        strategy: ConflictResolutionStrategy.keepLocal,
      );

      expect(result.status, ConflictResolutionStatus.rejected);
      expect(result.errorCode, 'profile-unavailable');
      expect(await database.readConflictResolutionIntent('conflict-1'), isNull);
      expect(await database.readUnresolvedConflict('conflict-1'), isNotNull);
    });

    test(
      'rejects dataset strategies not supported by the profile kind',
      () async {
        await profiles.save(_selectedFolderProfile());
        await _recordConflict(database);

        final result = await _service(database, profiles).resolve(
          conflictId: 'conflict-1',
          strategy: ConflictResolutionStrategy.openInVelock,
        );

        expect(result.status, ConflictResolutionStatus.rejected);
        expect(result.errorCode, 'invalid-strategy');
        expect(
          await database.readConflictResolutionIntent('conflict-1'),
          isNull,
        );
      },
    );

    test(
      'rejects legacy or malformed selected-folder details before intent',
      () async {
        await profiles.save(_selectedFolderProfile());
        await _recordConflict(database, protectedDetails: '{"version":1}');
        final resolver = _FakeSelectedFolderResolver();

        final result =
            await _service(
              database,
              profiles,
              selectedFolderResolver: resolver,
            ).resolve(
              conflictId: 'conflict-1',
              strategy: ConflictResolutionStrategy.keepLocal,
            );

        expect(result.status, ConflictResolutionStatus.rejected);
        expect(result.errorCode, 'invalid-selected-folder-conflict-details');
        expect(resolver.calls, isZero);
        expect(
          await database.readConflictResolutionIntent('conflict-1'),
          isNull,
        );
      },
    );

    test('accepts protected details for an incoming folder delete', () async {
      await profiles.save(_selectedFolderProfile());
      await _recordConflict(database, protectedDetails: _folderDeleteDetails());
      final resolver = _FakeSelectedFolderResolver(
        onResolve: (_, details, strategy) async {
          expect(details.incomingWasDelete, isTrue);
          expect(details.incomingConflictCopy, isNull);
          expect(strategy, ConflictResolutionStrategy.keepRemote);
          return const ConflictResolutionArtifact(
            'selected-folder:delete-opaque',
          );
        },
      );

      final result =
          await _service(
            database,
            profiles,
            selectedFolderResolver: resolver,
          ).resolve(
            conflictId: 'conflict-1',
            strategy: ConflictResolutionStrategy.keepRemote,
          );

      expect(result.status, ConflictResolutionStatus.completed);
      expect(resolver.calls, 1);
      expect(await database.readUnresolvedConflict('conflict-1'), isNull);
    });

    test(
      'persists running intent before selected-folder resolver and completes',
      () async {
        await profiles.save(_selectedFolderProfile());
        await _recordConflict(database, protectedDetails: _folderDetails());
        final resolver = _FakeSelectedFolderResolver(
          onResolve: (_, _, _) async {
            final intent = await database.readConflictResolutionIntent(
              'conflict-1',
            );
            expect(intent!.state, ConflictResolutionIntentState.running);
            expect(intent.leaseOwner, isNotEmpty);
            return const ConflictResolutionArtifact('selected-folder:opaque-1');
          },
        );

        final result =
            await _service(
              database,
              profiles,
              selectedFolderResolver: resolver,
            ).resolve(
              conflictId: 'conflict-1',
              strategy: ConflictResolutionStrategy.keepBoth,
            );

        expect(result.status, ConflictResolutionStatus.completed);
        expect(resolver.calls, 1);
        final intent = await database.readConflictResolutionIntent(
          'conflict-1',
        );
        expect(intent!.state, ConflictResolutionIntentState.completed);
        expect(intent.strategy, 'keep-both');
        expect(intent.receiptArtifact, 'selected-folder:opaque-1');
        expect(await database.readUnresolvedConflict('conflict-1'), isNull);
      },
    );

    test(
      'keeps the conflict unresolved and makes intent retryable on failure',
      () async {
        await profiles.save(_selectedFolderProfile());
        await _recordConflict(database, protectedDetails: _folderDetails());
        final resolver = _FakeSelectedFolderResolver(
          onResolve: (_, _, _) => throw const ConflictResolutionFailure(
            'selected-folder-publish-failed',
          ),
        );

        final result =
            await _service(
              database,
              profiles,
              selectedFolderResolver: resolver,
            ).resolve(
              conflictId: 'conflict-1',
              strategy: ConflictResolutionStrategy.keepRemote,
            );

        expect(result.status, ConflictResolutionStatus.failed);
        expect(result.errorCode, 'selected-folder-publish-failed');
        final intent = await database.readConflictResolutionIntent(
          'conflict-1',
        );
        expect(intent!.state, ConflictResolutionIntentState.retryable);
        expect(intent.errorCode, 'selected-folder-publish-failed');
        expect(await database.readUnresolvedConflict('conflict-1'), isNotNull);
      },
    );

    test('deduplicates same-process requests for the same strategy', () async {
      await profiles.save(_selectedFolderProfile());
      await _recordConflict(database, protectedDetails: _folderDetails());
      final started = Completer<void>();
      final finish = Completer<ConflictResolutionArtifact>();
      final resolver = _FakeSelectedFolderResolver(
        onResolve: (_, _, _) {
          started.complete();
          return finish.future;
        },
      );
      final service = _service(
        database,
        profiles,
        selectedFolderResolver: resolver,
      );

      final first = service.resolve(
        conflictId: 'conflict-1',
        strategy: ConflictResolutionStrategy.keepLocal,
      );
      await started.future;
      final second = service.resolve(
        conflictId: 'conflict-1',
        strategy: ConflictResolutionStrategy.keepLocal,
      );

      expect(identical(first, second), isTrue);
      expect(resolver.calls, 1);
      finish.complete(
        const ConflictResolutionArtifact('selected-folder:opaque-2'),
      );
      expect((await first).status, ConflictResolutionStatus.completed);
    });

    test('does not take a conflict owned by another strategy', () async {
      await profiles.save(_selectedFolderProfile());
      await _recordConflict(database, protectedDetails: _folderDetails());
      final now = DateTime.utc(2026, 7, 17, 12);
      await database.acquireConflictResolutionIntent(
        conflictId: 'conflict-1',
        strategy: ConflictResolutionStrategy.keepRemote.persistedValue,
        owner: 'other-process',
        now: now,
        lease: const Duration(minutes: 5),
      );

      final result =
          await _service(
            database,
            profiles,
            now: () => now.add(const Duration(minutes: 1)),
          ).resolve(
            conflictId: 'conflict-1',
            strategy: ConflictResolutionStrategy.keepLocal,
          );

      expect(result.status, ConflictResolutionStatus.strategyMismatch);
      expect(await database.readUnresolvedConflict('conflict-1'), isNotNull);
    });

    test(
      'recovers a stale lease and then completes through the durable path',
      () async {
        await profiles.save(_selectedFolderProfile());
        await _recordConflict(database, protectedDetails: _folderDetails());
        final startedAt = DateTime.utc(2026, 7, 17, 12);
        await database.acquireConflictResolutionIntent(
          conflictId: 'conflict-1',
          strategy: ConflictResolutionStrategy.keepLocal.persistedValue,
          owner: 'crashed-process',
          now: startedAt,
          lease: const Duration(minutes: 1),
        );

        final result =
            await _service(
              database,
              profiles,
              selectedFolderResolver: _FakeSelectedFolderResolver(),
              now: () => startedAt.add(const Duration(minutes: 2)),
            ).resolve(
              conflictId: 'conflict-1',
              strategy: ConflictResolutionStrategy.keepLocal,
            );

        expect(result.status, ConflictResolutionStatus.completed);
        expect(await database.readUnresolvedConflict('conflict-1'), isNull);
      },
    );

    test(
      'requires a verified opaque Velock receipt before completing',
      () async {
        await profiles.save(_velockProfile());
        await _recordConflict(database);
        final opener = _FakeVelockOpener(
          result: const VelockConflictResolutionReceipt('velock:receipt-1'),
        );
        final verifier = _FakeVelockReceiptVerifier(result: false);

        final result =
            await _service(
              database,
              profiles,
              velockOpener: opener,
              velockReceiptVerifier: verifier,
            ).resolve(
              conflictId: 'conflict-1',
              strategy: ConflictResolutionStrategy.openInVelock,
            );

        expect(result.status, ConflictResolutionStatus.failed);
        expect(result.errorCode, 'untrusted-velock-receipt');
        expect(opener.profile?.profileId, 'profile-1');
        expect(opener.conflict?.conflictId, 'conflict-1');
        expect(verifier.profile?.profileId, 'profile-1');
        expect(verifier.conflict?.conflictId, 'conflict-1');
        expect(await database.readUnresolvedConflict('conflict-1'), isNotNull);
        expect(
          (await database.readConflictResolutionIntent('conflict-1'))!.state,
          ConflictResolutionIntentState.retryable,
        );
      },
    );

    test(
      'completes a Velock conflict only with a verified nonempty receipt',
      () async {
        await profiles.save(_velockProfile());
        await _recordConflict(database);
        final opener = _FakeVelockOpener(
          result: const VelockConflictResolutionReceipt('velock:receipt-2'),
        );

        final result =
            await _service(
              database,
              profiles,
              velockOpener: opener,
              velockReceiptVerifier: _FakeVelockReceiptVerifier(result: true),
            ).resolve(
              conflictId: 'conflict-1',
              strategy: ConflictResolutionStrategy.openInVelock,
            );

        expect(result.status, ConflictResolutionStatus.completed);
        expect(await database.readUnresolvedConflict('conflict-1'), isNull);
        expect(
          (await database.readConflictResolutionIntent(
            'conflict-1',
          ))!.receiptArtifact,
          'velock:receipt-2',
        );
        expect(opener.acknowledgements, 1);
      },
    );

    test(
      'rejects empty resolution artifacts without resolving the conflict',
      () async {
        await profiles.save(_selectedFolderProfile());
        await _recordConflict(database, protectedDetails: _folderDetails());
        final resolver = _FakeSelectedFolderResolver(
          onResolve: (_, _, _) async => const ConflictResolutionArtifact(''),
        );

        final result =
            await _service(
              database,
              profiles,
              selectedFolderResolver: resolver,
            ).resolve(
              conflictId: 'conflict-1',
              strategy: ConflictResolutionStrategy.keepLocal,
            );

        expect(result.status, ConflictResolutionStatus.failed);
        expect(result.errorCode, 'missing-resolution-artifact');
        expect(await database.readUnresolvedConflict('conflict-1'), isNotNull);
      },
    );
  });
}

DurableConflictResolutionService _service(
  SyncStateDatabase database,
  SyncProfileRepository profiles, {
  SelectedFolderConflictResolver? selectedFolderResolver,
  VelockConflictOpener? velockOpener,
  VelockConflictReceiptVerifier? velockReceiptVerifier,
  DateTime Function()? now,
}) => DurableConflictResolutionService(
  database: database,
  profiles: profiles,
  selectedFolderResolver:
      selectedFolderResolver ?? _FakeSelectedFolderResolver(),
  velockOpener: velockOpener ?? _FakeVelockOpener(),
  velockReceiptVerifier:
      velockReceiptVerifier ?? _FakeVelockReceiptVerifier(result: true),
  now: now,
);

Future<void> _recordConflict(
  SyncStateDatabase database, {
  String profileId = 'profile-1',
  String? protectedDetails,
}) => database.recordFolderConflict(
  conflictId: 'conflict-1',
  profileId: profileId,
  entityId: 'opaque-entity',
  sourceDeviceId: 'remote-device',
  localRevisionId: 'local-revision',
  incomingRevisionId: 'incoming-revision',
  type: 'concurrent',
  protectedDetails: protectedDetails,
);

String _folderDetails() => jsonEncode({
  'version': 1,
  'target': 'nested/note.txt',
  'incomingConflictCopy': 'nested/note.txt.velock-conflict-incoming',
  'entryType': 'file',
  'localRevisionId': 'local-revision',
  'incomingRevisionId': 'incoming-revision',
  'localVector': {'local-device': 1},
  'incomingVector': {'remote-device': 1},
  'incomingWasDelete': false,
});

String _folderDeleteDetails() => jsonEncode({
  'version': 1,
  'target': 'nested/note.txt',
  'entryType': 'file',
  'localRevisionId': 'local-revision',
  'incomingRevisionId': 'incoming-revision',
  'localVector': {'local-device': 1},
  'incomingVector': {'remote-device': 1},
  'incomingWasDelete': true,
});

SyncProfileEnvelope _selectedFolderProfile() => _profile(
  kind: SyncDatasetKind.selectedFolder,
  dataset: const {
    'rootPath': '/safe/path',
    'rootKeyRef': 'secure/root',
    'signingKeyRef': 'secure/signing',
  },
);

SyncProfileEnvelope _velockProfile() => _profile(
  kind: SyncDatasetKind.velockManaged,
  dataset: const {
    'pairedProducerId': 'producer-1',
    'pairedProducerPublicKeyId': 'key-1',
    'exchangeBindingId': 'exchange-1',
  },
);

SyncProfileEnvelope _profile({
  required SyncDatasetKind kind,
  required Map<String, Object?> dataset,
}) => SyncProfileEnvelope(
  kind: kind,
  profileId: 'profile-1',
  datasetId: 'dataset-1',
  vaultId: 'vault-1',
  deviceId: 'device-1',
  displayName: 'Test profile',
  connectionId: 'connection-1',
  state: SyncProfileState.active,
  backgroundPolicy: const SyncProfileBackgroundPolicy(),
  dataset: dataset,
  createdAt: DateTime.utc(2026, 7, 17),
);

typedef _ResolveSelectedFolder =
    Future<ConflictResolutionArtifact> Function(
      SyncConflictRecord conflict,
      SelectedFolderConflictDetails details,
      ConflictResolutionStrategy strategy,
    );

class _FakeSelectedFolderResolver implements SelectedFolderConflictResolver {
  _FakeSelectedFolderResolver({this.onResolve});

  final _ResolveSelectedFolder? onResolve;
  int calls = 0;

  @override
  Future<ConflictResolutionArtifact> resolve({
    required SyncConflictRecord conflict,
    required SelectedFolderConflictDetails details,
    required ConflictResolutionStrategy strategy,
  }) {
    calls++;
    return onResolve?.call(conflict, details, strategy) ??
        Future.value(
          const ConflictResolutionArtifact('selected-folder:opaque'),
        );
  }
}

class _FakeVelockOpener implements VelockConflictOpener {
  _FakeVelockOpener({
    this.result = const VelockConflictResolutionReceipt('velock:opaque'),
  });

  final VelockConflictResolutionReceipt result;
  SyncProfileEnvelope? profile;
  SyncConflictRecord? conflict;
  int acknowledgements = 0;

  @override
  Future<VelockConflictResolutionReceipt> open({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
  }) async {
    this.profile = profile;
    this.conflict = conflict;
    return result;
  }

  @override
  Future<void> acknowledge({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
    required VelockConflictResolutionReceipt receipt,
  }) async {
    acknowledgements++;
  }
}

class _FakeVelockReceiptVerifier implements VelockConflictReceiptVerifier {
  _FakeVelockReceiptVerifier({required this.result});

  final bool result;
  SyncProfileEnvelope? profile;
  SyncConflictRecord? conflict;

  @override
  Future<bool> verify({
    required SyncProfileEnvelope profile,
    required SyncConflictRecord conflict,
    required VelockConflictResolutionReceipt receipt,
  }) async {
    this.profile = profile;
    this.conflict = conflict;
    return result;
  }
}
