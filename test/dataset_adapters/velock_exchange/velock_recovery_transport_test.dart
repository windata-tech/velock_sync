import 'package:dio/dio.dart';
import 'package:velock_sync/providers/webdav/webdav_object_store.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_recovery_transport.dart';
import 'package:velock_sync/sync_core/testing/in_memory_object_store.dart';

void main() {
  const vault = '00000000-0000-4000-8000-000000000001';
  final raw = jsonEncode({
    'format': 'velock-cloud-recovery',
    'version': 1,
    'lookup': 'a' * 64,
    'vaultId': vault,
    'keyId': '00000000-0000-4000-8000-000000000002',
    'code': 'VSR1-opaque-test-fixture',
  });
  late Directory root;
  late InMemoryObjectStore remote;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('recovery-transport-');
    remote = InMemoryObjectStore();
  });
  tearDown(() async => root.delete(recursive: true));
  Future<void> stage(String data) async {
    final file = File('${root.path}/Recovery/Outgoing/$vault.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(data);
  }

  test(
    'immutable upload verified and unpaired download hands off identical bytes',
    () async {
      await stage(raw);
      await VelockRecoveryTransport.upload(
        root: root,
        vaultId: vault,
        remote: remote,
      );
      await VelockRecoveryTransport.upload(
        root: root,
        vaultId: vault,
        remote: remote,
      );
      expect((await remote.list()).items.length, 1);
      expect(
        await VelockRecoveryTransport.download(root: root, remote: remote),
        1,
      );
      final selection = jsonDecode(
        await File(
          '${root.path}/Recovery/Incoming/selection.json',
        ).readAsString(),
      );
      expect(selection['files'], [raw]);
    },
  );
  test('missing export and corrupt existing remote fail backup', () async {
    await expectLater(
      VelockRecoveryTransport.upload(
        root: root,
        vaultId: vault,
        remote: remote,
      ),
      throwsStateError,
    );
    await stage(raw);
    await remote.put(
      VelockRecoveryTransport.objectName(raw),
      Stream.value(utf8.encode('corrupt')),
      contentLength: 7,
    );
    await expectLater(
      VelockRecoveryTransport.upload(
        root: root,
        vaultId: vault,
        remote: remote,
      ),
      throwsStateError,
    );
  });
  test(
    'empty folder or damaged download cannot leave stale selection',
    () async {
      await stage(raw);
      await VelockRecoveryTransport.upload(
        root: root,
        vaultId: vault,
        remote: remote,
      );
      await VelockRecoveryTransport.download(root: root, remote: remote);
      await remote.delete(VelockRecoveryTransport.objectName(raw));
      await expectLater(
        VelockRecoveryTransport.download(root: root, remote: remote),
        throwsStateError,
      );
      expect(
        await File('${root.path}/Recovery/Incoming/selection.json').exists(),
        isFalse,
      );
      await remote.put(
        VelockRecoveryTransport.objectName(raw),
        Stream.value(utf8.encode('{}')),
        contentLength: 2,
      );
      await expectLater(
        VelockRecoveryTransport.download(root: root, remote: remote),
        throwsFormatException,
      );
    },
  );
  test(
    'dismissed recovery flow cannot publish a downloaded selection',
    () async {
      await stage(raw);
      await VelockRecoveryTransport.upload(
        root: root,
        vaultId: vault,
        remote: remote,
      );
      await expectLater(
        VelockRecoveryTransport.download(
          root: root,
          remote: remote,
          isCurrent: () => false,
        ),
        throwsStateError,
      );
      expect(
        await File('${root.path}/Recovery/Incoming/selection.json').exists(),
        isFalse,
      );
    },
  );

  test('more recovery files than the cap still restores from the newest', () async {
    // Each password change and each restored device adds a file; they are
    // never removed. The download used to fail outright past 32 files.
    for (var i = 0; i < VelockRecoveryTransport.maxCandidates + 3; i++) {
      final file = jsonEncode({
        'format': 'velock-cloud-recovery',
        'version': 1,
        'lookup': 'a' * 64,
        'vaultId': vault,
        'keyId': '00000000-0000-4000-8000-000000000002',
        'code': 'VSR1-version-$i',
      });
      final bytes = utf8.encode(file);
      await remote.put(
        VelockRecoveryTransport.objectName(file),
        Stream.value(bytes),
        contentLength: bytes.length,
      );
    }

    expect(
      await VelockRecoveryTransport.download(root: root, remote: remote),
      VelockRecoveryTransport.maxCandidates,
    );
  });

  final contractDir = Platform.environment['RECOVERY_CONTRACT_DIR'];
  if (contractDir != null)
    test(
      'transport real Velock encrypted fixture without knowing secrets',
      () async {
        final data = await File('$contractDir/source.json').readAsString();
        final url = Platform.environment['RECOVERY_TEST_WEBDAV_URL'];
        final RemoteObjectStore contractRemote = url == null
            ? remote
            : WebDavObjectStore(
                dio: Dio(),
                baseUri: Uri.parse(url),
                username: 'recoverytest',
                password: 'recoverytest',
              );
        await stage(data);
        await VelockRecoveryTransport.upload(
          root: root,
          vaultId: vault,
          remote: contractRemote,
        );
        await VelockRecoveryTransport.download(
          root: Directory(contractDir),
          remote: contractRemote,
        );
      },
    );
}
