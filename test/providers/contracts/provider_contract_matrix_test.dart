import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'object_store_contract_fixture.dart';

void main() {
  test('provider contract matrix has complete enabled-provider coverage', () {
    final data =
        jsonDecode(
              File(
                'test/providers/contracts/provider_contract_matrix.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final contracts = (data['contracts'] as List).cast<String>().toSet();
    final expected = ObjectStoreContract.values
        .map((contract) => contract.id)
        .toSet();
    final providers = (data['providers'] as Map).cast<String, dynamic>();

    expect(contracts, expected);
    expect(
      providers.keys,
      containsAll(<String>['webdav', 'google_drive', 'one_drive']),
    );
    for (final entry in providers.entries) {
      final provider = (entry.value as Map).cast<String, dynamic>();
      expect(provider['adapter'], isA<String>(), reason: entry.key);
      expect(provider['suite'], isA<String>(), reason: entry.key);
      expect(
        File(provider['suite'] as String).existsSync(),
        isTrue,
        reason: entry.key,
      );
      expect(provider['safeFallback'], isA<String>(), reason: entry.key);

      final evidence = (provider['contracts'] as Map).cast<String, dynamic>();
      expect(evidence.keys.toSet(), expected, reason: entry.key);
      for (final contract in expected) {
        final record = (evidence[contract] as Map).cast<String, dynamic>();
        expect(
          record['status'],
          anyOf('pending_verification', 'verified'),
          reason: '${entry.key}:$contract',
        );
        expect(
          record['evidence'],
          isA<String>(),
          reason: '${entry.key}:$contract',
        );
        expect(
          record['evidence'] as String,
          contains(contract),
          reason: '${entry.key}:$contract',
        );
      }
    }
  });
}
