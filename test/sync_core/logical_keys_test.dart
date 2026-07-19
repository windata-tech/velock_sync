import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/engine/logical_keys.dart';

void main() {
  group('LogicalKeys', () {
    test('uses V1 layout and a 20-digit sequence', () {
      expect(
        LogicalKeys.commit('vault-1', 'device-1', 42, 'batch-1'),
        'velock-sync/v1/vault-1/devices/device-1/commits/00000000000000000042-batch-1.commit',
      );
      expect(
        LogicalKeys.member('vault-1', 'device-1'),
        'velock-sync/v1/vault-1/members/device-1.member',
      );
    });

    test('rejects path traversal in opaque IDs', () {
      expect(() => LogicalKeys.protocol('../vault'), throwsArgumentError);
      expect(
        () => LogicalKeys.blob('vault', 'nested/blob'),
        throwsArgumentError,
      );
      expect(() => LogicalKeys.formatSequence(0), throwsArgumentError);
    });
  });
}
