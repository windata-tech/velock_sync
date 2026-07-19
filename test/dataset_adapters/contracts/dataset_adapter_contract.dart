import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';

/// The V1 behavior every enabled [SyncDatasetAdapter] must prove.
///
/// These IDs deliberately match §15 of `docs/V1_COMPLETION_SPEC.md`. A
/// fixture cannot omit a behavior: [defineDatasetAdapterContractSuite] fails
/// during test registration if any verification is missing.
enum DatasetAdapterContract {
  baselinePagination('baseline pagination'),
  add('add'),
  modify('modify'),
  move('move'),
  rename('rename'),
  deleteTombstone('delete/tombstone'),
  duplicateBatch('duplicate batch'),
  outOfOrderBatch('out-of-order batch'),
  conflict('conflict'),
  accessLossRegrant('access loss/regrant'),
  crashRecovery('crash recovery'),
  diskFull('disk full'),
  malformedArtifact('malformed artifact'),
  unsupportedVersion('unsupported version'),
  cursorAfterDurableApplyReceipt('cursor only after durable apply/receipt'),
  stagingCleanup('staging cleanup');

  const DatasetAdapterContract(this.title);

  final String title;

  String get id => 'DCA-${(index + 1).toString().padLeft(3, '0')}';
}

typedef DatasetContractVerification = Future<void> Function();

/// A real-adapter fixture for the unified V1 Dataset Adapter Contract Suite.
///
/// The descriptor verification is kept in the fixture rather than only in the
/// individual callbacks so each suite proves it instantiates its real adapter.
class DatasetAdapterContractFixture {
  DatasetAdapterContractFixture({
    required this.name,
    required this.verifyDescriptor,
    required Map<DatasetAdapterContract, DatasetContractVerification>
    verifications,
  }) : _verifications = Map.unmodifiable(verifications) {
    final missing = DatasetAdapterContract.values
        .where((contract) => !_verifications.containsKey(contract))
        .toList(growable: false);
    final unknown = _verifications.keys
        .where((contract) => !DatasetAdapterContract.values.contains(contract))
        .toList(growable: false);
    if (missing.isNotEmpty || unknown.isNotEmpty) {
      throw ArgumentError(
        'Dataset contract fixture "$name" is incomplete. '
        'Missing: ${missing.map((item) => item.id).join(', ')}; '
        'unknown: ${unknown.map((item) => item.id).join(', ')}.',
      );
    }
  }

  final String name;
  final Future<void> Function() verifyDescriptor;
  final Map<DatasetAdapterContract, DatasetContractVerification> _verifications;

  DatasetContractVerification verification(DatasetAdapterContract contract) =>
      _verifications[contract]!;
}

/// Registers one independently reportable test for every V1 dataset contract.
///
/// The fixture must use a real Selected Folder or Velock Exchange adapter in
/// its checks. The harness does not permit `skip` so coverage cannot be
/// silently downgraded when a new adapter is enabled.
void defineDatasetAdapterContractSuite(DatasetAdapterContractFixture fixture) {
  group('Dataset adapter contract: ${fixture.name}', () {
    test('DCA-000 adapter describes itself', () async {
      await fixture.verifyDescriptor();
    });

    for (final contract in DatasetAdapterContract.values) {
      test('${contract.id} ${contract.title}', fixture.verification(contract));
    }
  });
}
