import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/infrastructure/storage/available_space_probe.dart';
import 'package:velock_sync/infrastructure/storage/staging_disk_preflight.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

void main() {
  test('creates its staging root before checking free disk space', () async {
    final parent = await Directory.systemTemp.createTemp('velock-space-');
    addTearDown(() => parent.delete(recursive: true));
    final staging = Directory('${parent.path}/staging');
    final probe = _Probe(128);

    await StagingDiskPreflight(
      probe,
      minimumFreeBytes: 64,
    ).ensureAvailable(staging);

    expect(await staging.exists(), isTrue);
    expect(probe.checked, staging.path);
  });

  test(
    'reports a retryable, privacy-safe failure when space is insufficient',
    () async {
      final parent = await Directory.systemTemp.createTemp('velock-space-');
      addTearDown(() => parent.delete(recursive: true));

      await expectLater(
        StagingDiskPreflight(
          _Probe(63),
          minimumFreeBytes: 64,
        ).ensureAvailable(Directory('${parent.path}/staging')),
        throwsA(isA<StagingDiskSpaceException>()),
      );
      expect(
        const StagingDiskSpaceException().syncFailure.category,
        SyncErrorCategory.insufficientSpace,
      );
    },
  );
}

class _Probe implements AvailableSpaceProbe {
  _Probe(this.bytes);

  final int bytes;
  String? checked;

  @override
  Future<int> availableBytes(Directory directory) async {
    checked = directory.path;
    return bytes;
  }
}
