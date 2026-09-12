import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_incoming_applier.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_scanner.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_blob_cipher.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_key_deriver.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  late Directory root;
  late SyncStateDatabase database;
  late GenericVaultBlobCipher cipher;
  late SelectedFolderIncomingApplier applier;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('velock-incoming-');
    database = await SyncStateDatabase.inMemory();
    cipher = GenericVaultBlobCipher(
      keyDeriver: GenericVaultKeyDeriver(Uint8List(32)),
      keyId: 'key-1',
      chunkSize: 4,
      secureBytes: (_) => Uint8List(8),
    );
    applier = SelectedFolderIncomingApplier(
      root: root,
      datasetId: 'folder-1',
      profileId: 'profile-1',
      database: database,
      blobCipher: cipher,
    );
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  test(
    'writes an authenticated incoming file once and persists its revision',
    () async {
      final encrypted = await _encrypt(cipher, 'vault-1', 'blob-1', 'remote');
      final operation = _fileOperation(
        operationId: 'op-1',
        revisionId: 'revision-1',
        vector: {'device-remote': 1},
      );

      await applier.apply(
        vaultId: 'vault-1',
        sourceDeviceId: 'device-remote',
        batchId: 'batch-1',
        operations: [operation],
        blobs: {'blob-1': encrypted},
      );
      await applier.apply(
        vaultId: 'vault-1',
        sourceDeviceId: 'device-remote',
        batchId: 'batch-1',
        operations: [operation],
        blobs: {'blob-1': encrypted},
      );

      expect(
        await File('${root.path}/nested/note.txt').readAsString(),
        'remote',
      );
      expect(
        await database.isFolderOperationApplied(
          datasetId: 'folder-1',
          operationId: 'op-1',
        ),
        isTrue,
      );
      expect(
        (await database.readFolderEntitySyncState(
          datasetId: 'folder-1',
          entityId: 'entity-1',
        ))!.versionVector,
        VersionVector({'device-remote': 1}),
      );
    },
  );

  test(
    'preserves local content as a conflict copy for concurrent incoming edit',
    () async {
      final local = File('${root.path}/nested/note.txt');
      await local.parent.create(recursive: true);
      await local.writeAsString('local');
      await database.upsertFolderEntitySyncState(
        datasetId: 'folder-1',
        entityId: 'entity-1',
        revisionId: 'local-revision',
        versionVector: VersionVector({'device-local': 1}),
        isTombstone: false,
      );
      final encrypted = await _encrypt(
        cipher,
        'vault-1',
        'blob-1',
        'remote-file-body',
      );

      await applier.apply(
        vaultId: 'vault-1',
        sourceDeviceId: 'device-remote',
        batchId: 'batch-1',
        operations: [
          _fileOperation(
            operationId: 'op-1',
            revisionId: 'incoming-revision',
            vector: {'device-remote': 1},
          ),
        ],
        blobs: {'blob-1': encrypted},
      );

      expect(await local.readAsString(), 'local');
      final conflicts = await root
          .list(recursive: true)
          .where((entry) => entry.path.contains('.velock-conflict-'))
          .cast<File>()
          .toList();
      expect(conflicts, hasLength(1));
      expect(await conflicts.single.readAsString(), 'remote-file-body');

      final conflictRecord = (await database.listUnresolvedConflicts()).single;
      final details =
          jsonDecode(conflictRecord.protectedDetails!) as Map<String, dynamic>;
      expect(details['version'], 1);
      expect(details['target'], 'nested/note.txt');
      expect(details['incomingConflictCopy'], contains('.velock-conflict-'));
      expect(details['entryType'], 'file');
      expect(details['localRevisionId'], 'local-revision');
      expect(details['incomingRevisionId'], 'incoming-revision');
      expect(details['localVector'], {'device-local': 1});
      expect(details['incomingVector'], {'device-remote': 1});
      expect(details['incomingWasDelete'], isFalse);
      expect(
        conflictRecord.protectedDetails,
        isNot(contains('remote-file-body')),
      );
    },
  );

  test(
    'records safe resolvable metadata for a concurrent incoming delete',
    () async {
      final local = File('${root.path}/nested/note.txt');
      await local.parent.create(recursive: true);
      await local.writeAsString('local');
      await database.upsertFolderEntitySyncState(
        datasetId: 'folder-1',
        entityId: 'entity-1',
        revisionId: 'local-revision',
        versionVector: VersionVector({'device-local': 1}),
        isTombstone: false,
      );

      await applier.apply(
        vaultId: 'vault-1',
        sourceDeviceId: 'device-remote',
        batchId: 'batch-delete',
        operations: [
          _fileOperation(
            operationId: 'op-delete',
            revisionId: 'incoming-delete-revision',
            vector: {'device-remote': 1},
            type: SyncOperationType.delete,
          ),
        ],
        blobs: const {},
      );

      expect(await local.readAsString(), 'local');
      expect(
        await root
            .list(recursive: true)
            .where((entry) => entry.path.contains('.velock-conflict-'))
            .isEmpty,
        isTrue,
      );
      final conflictRecord = (await database.listUnresolvedConflicts()).single;
      final details =
          jsonDecode(conflictRecord.protectedDetails!) as Map<String, dynamic>;
      expect(conflictRecord.type, startsWith('delete-modify'));
      expect(details['target'], 'nested/note.txt');
      expect(details.containsKey('incomingConflictCopy'), isFalse);
      expect(details['entryType'], 'file');
      expect(details['localVector'], {'device-local': 1});
      expect(details['incomingVector'], {'device-remote': 1});
      expect(details['incomingWasDelete'], isTrue);
    },
  );

  test('rejects a payload path outside the selected folder', () async {
    final operation = _fileOperation(
      operationId: 'op-1',
      revisionId: 'revision-1',
      vector: {'device-remote': 1},
      path: '../escape.txt',
    );
    await expectLater(
      applier.apply(
        vaultId: 'vault-1',
        sourceDeviceId: 'device-remote',
        batchId: 'batch-1',
        operations: [operation],
        blobs: const {},
      ),
      throwsA(isA<FolderPathInvalidException>()),
    );
  });
}

SyncOperation _fileOperation({
  required String operationId,
  required String revisionId,
  required Map<String, int> vector,
  String path = 'nested/note.txt',
  SyncOperationType type = SyncOperationType.upsert,
}) => SyncOperation(
  operationId: operationId,
  entityId: 'entity-1',
  entityKind: 'file',
  type: type,
  versionVector: VersionVector(vector),
  revisionId: revisionId,
  protectedPayload: Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'entryType': 'file',
        'relativePath': path,
        'size': 6,
        'modifiedAt': '2026-07-15T00:00:00.000Z',
        'deletedAt': null,
      }),
    ),
  ),
  blobIds: type == SyncOperationType.delete ? const [] : const ['blob-1'],
  createdAt: DateTime.utc(2026, 7, 15),
);

Future<Uint8List> _encrypt(
  GenericVaultBlobCipher cipher,
  String vaultId,
  String blobId,
  String value,
) async {
  final output = BytesBuilder(copy: false);
  await for (final chunk in cipher.encrypt(
    vaultId: vaultId,
    blobId: blobId,
    plaintextLength: utf8.encode(value).length,
    plaintext: Stream.value(utf8.encode(value)),
  )) {
    output.add(chunk);
  }
  return output.takeBytes();
}
