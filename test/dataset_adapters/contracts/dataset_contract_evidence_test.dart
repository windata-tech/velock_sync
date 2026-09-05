import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'dataset_adapter_contract.dart';

void main() {
  test('V1C-DATASET-001 evidence matrix is complete and scope-qualified', () {
    final document =
        jsonDecode(
              File(
                'test/dataset_adapters/contracts/dataset_contract_evidence.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    expect(document['requirement'], 'V1C-DATASET-001');
    expect(
      document['securityBoundary'],
      isA<String>().having(
        (value) => value,
        'security boundary',
        allOf(contains('opaque'), contains('do not decrypt')),
      ),
    );
    final crossRepository =
        document['crossRepositoryInterface'] as Map<String, dynamic>;
    expect(crossRepository['status'], 'frozen-and-locally-compatible');
    expect(
      crossRepository['contract'],
      'test_vectors/velock_exchange_v1/interface_contract.json',
    );
    expect(File(crossRepository['contract'] as String).existsSync(), isTrue);
    expect(
      crossRepository['implementedSurfaces'] as List<dynamic>,
      hasLength(greaterThanOrEqualTo(10)),
    );
    expect(
      crossRepository['limitations'],
      allOf(
        contains('release-signed IPC'),
        contains('physical-device interoperability'),
      ),
    );

    final adapters = document['adapters'] as List<dynamic>;
    expect(
      adapters.map((item) => (item as Map<String, dynamic>)['id']).toSet(),
      {'velock_exchange'},
    );

    final expectedIds = DatasetAdapterContract.values
        .map((contract) => contract.id)
        .toSet();
    const directScopes = {'direct-adapter-fixture'};
    const permittedScopes = {
      ...directScopes,
      'sync-core-integration',
      'focused-real-adapter-test',
      'shared-infrastructure',
      'outgoing-staging-recovery',
      'factory-discovery-preflight',
      'deferred-receipt-fixture',
    };

    for (final entry in adapters.cast<Map<String, dynamic>>()) {
      final contracts = entry['contracts'] as List<dynamic>;
      final byId = <String, Map<String, dynamic>>{};
      for (final contract in contracts.cast<Map<String, dynamic>>()) {
        final id = contract['id'] as String;
        expect(
          byId,
          isNot(contains(id)),
          reason: '${entry['id']} duplicates $id',
        );
        byId[id] = contract;
        expect(permittedScopes, contains(contract['scope']));
        expect(
          contract['evidence'],
          isA<String>().having((value) => value.trim(), 'evidence', isNotEmpty),
        );
        if (!directScopes.contains(contract['scope'])) {
          expect(
            contract['limitations'],
            isA<String>().having(
              (value) => value.trim(),
              'limitations',
              isNotEmpty,
            ),
            reason: '${entry['id']} $id must state its evidence boundary',
          );
        }
      }
      expect(byId.keys.toSet(), expectedIds, reason: '${entry['id']} coverage');
    }

    final blockers = document['remainingBlockers'] as List<dynamic>;
    expect(blockers, isNotEmpty);
    expect(
      blockers.join('\n'),
      allOf(
        contains('release trust/entitlement'),
        contains('physical dual-device'),
      ),
    );
    expect(blockers.join('\n'), isNot(contains('Cross-repository interface')));
  });
}
