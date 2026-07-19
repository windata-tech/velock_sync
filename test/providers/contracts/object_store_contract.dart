import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

import 'object_store_contract_fixture.dart';

/// Registers the complete V1 ObjectStore contract for one enabled provider.
///
/// Provider fixtures own their HTTP scripting, while this function enforces
/// identical contract names and makes an omitted check a hard test failure.
void runObjectStoreContract(ObjectStoreContractFixture fixture) {
  final missing = ObjectStoreContract.values
      .where((contract) => fixture.checks[contract] == null)
      .toList(growable: false);
  if (missing.isNotEmpty) {
    throw StateError(
      '${fixture.providerName} is missing contract checks: '
      '${missing.map((contract) => contract.id).join(', ')}',
    );
  }

  group('${fixture.providerName} V1 ObjectStore contract', () {
    for (final contract in ObjectStoreContract.values) {
      test(contract.id, () async {
        await fixture.reset();
        await fixture.arrange(contract);
        final store = await fixture.createStore();
        expect(store, isA<RemoteObjectStore>());
        await fixture.checks[contract]!(store);
      });
    }
  });
}
