import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/engine/initial_sync_assessment.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  const assessor = InitialSyncAssessor();

  test('identifies an empty remote root for a baseline upload', () async {
    final assessment = await assessor.assess(
      vaultId: 'vault-1',
      remote: InMemoryObjectStore(),
    );

    expect(assessment.remoteState, InitialSyncRemoteState.empty);
  });

  test(
    'identifies an existing expected Vault without exposing remote paths',
    () async {
      final remote = InMemoryObjectStore();
      await remote.put(
        LogicalKeys.protocol('vault-1'),
        Stream.value(Uint8List.fromList([1])),
        contentLength: 1,
        ifAbsent: true,
      );

      final assessment = await assessor.assess(
        vaultId: 'vault-1',
        remote: remote,
      );

      expect(assessment.remoteState, InitialSyncRemoteState.expectedVault);
    },
  );

  test(
    'warns about non-empty content that is not the expected Vault',
    () async {
      final remote = InMemoryObjectStore();
      await remote.put(
        'unrelated-object',
        Stream.value(Uint8List.fromList([1])),
        contentLength: 1,
        ifAbsent: true,
      );

      final assessment = await assessor.assess(
        vaultId: 'vault-1',
        remote: remote,
      );

      expect(assessment.remoteState, InitialSyncRemoteState.unrelatedContent);
    },
  );
}
