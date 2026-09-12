import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/secure_storage/in_memory_vault_key_store.dart';

void main() {
  test('VaultKeyStore stores a root key behind an opaque reference', () async {
    final store = InMemoryVaultKeyStore();
    final key = Uint8List.fromList(List<int>.generate(32, (index) => index));

    final ref = await store.writeRootKey(key);
    expect(ref, startsWith('velock-sync/vault-root/'));
    expect(await store.readRootKey(ref), key);

    await store.delete(ref);
    expect(await store.readRootKey(ref), isNull);
  });
}
