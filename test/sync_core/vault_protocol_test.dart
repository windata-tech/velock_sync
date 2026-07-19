import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';
import 'package:velock_sync/sync_core/engine/vault_protocol.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  test(
    'creates an immutable canonical V1 protocol discovery document',
    () async {
      final remote = InMemoryObjectStore();
      final document = VaultProtocolDocument(
        vaultId: 'vault-1',
        createdAt: DateTime.utc(2026, 7, 15),
      );
      final bootstrapper = VaultProtocolBootstrapper();

      await bootstrapper.ensure(remote: remote, expected: document);
      await bootstrapper.ensure(remote: remote, expected: document);

      final key = LogicalKeys.protocol('vault-1');
      final bytes = await remote.read(key).single;
      expect(
        VaultProtocolDocument.parse(Uint8List.fromList(bytes)).vaultId,
        'vault-1',
      );
    },
  );

  test('rejects a discovery document with another pinned vault ID', () async {
    final remote = InMemoryObjectStore();
    final bootstrapper = VaultProtocolBootstrapper();
    await bootstrapper.ensure(
      remote: remote,
      expected: VaultProtocolDocument(
        vaultId: 'vault-1',
        createdAt: DateTime.utc(2026, 7, 15),
        minimumReaderVersion: 2,
      ),
    );

    await expectLater(
      bootstrapper.ensure(
        remote: remote,
        expected: VaultProtocolDocument(
          vaultId: 'vault-1',
          createdAt: DateTime.utc(2026, 7, 16),
        ),
      ),
      throwsStateError,
    );
  });
}
