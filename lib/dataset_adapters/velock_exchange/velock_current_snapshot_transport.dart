import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:velock_sync/sync_core/contracts/remote_object_store.dart';

/// Public authenticated inventory only. Sync never decrypts snapshot contents.
/// This proves neither business application nor successful device restoration.
class VelockSnapshotInventory {
  VelockSnapshotInventory._({
    required this.snapshotId,
    required this.vaultId,
    required this.producerId,
    required this.keyId,
    required this.manifest,
    required this.commit,
    required this.objects,
    required this.heads,
    required this.recordCount,
  });
  final String snapshotId, vaultId, producerId, keyId;
  final Uint8List manifest, commit;
  final Map<String, SnapshotObjectDigest> objects;
  final Map<String, ({int sequence, String batchId})> heads;
  final int recordCount;
  int get totalBytes =>
      manifest.length +
      commit.length +
      objects.values.fold(0, (sum, object) => sum + object.size);
  String get remotePrefix => 'vaults/$vaultId/current-snapshots/$snapshotId/';

  static const maxManifestBytes = 32 * 1024 * 1024;
  static const maxMetadataBytes = 128 * 1024 * 1024;
  static const kind = 'velock-current-state-snapshot';
  static const version = 2;

  static Future<VelockSnapshotInventory> verify({
    required List<int> manifest,
    required List<int> commit,
    required String snapshotId,
    required String vaultId,
    required String producerId,
    required String keyId,
    required PublicKey trustedSigningKey,
    int maxTotalBytes = 10 * 1024 * 1024 * 1024,
  }) async {
    for (final id in [snapshotId, vaultId, producerId, keyId]) {
      snapshotIdentifier(id);
    }
    if (manifest.isEmpty ||
        manifest.length > maxManifestBytes ||
        commit.isEmpty ||
        commit.length > 4096) {
      throw const FormatException('Snapshot object size limit exceeded.');
    }
    // Copy before yielding, so callers cannot mutate an authenticated inventory.
    final mBytes = Uint8List.fromList(manifest).asUnmodifiableView();
    final cBytes = Uint8List.fromList(commit).asUnmodifiableView();
    final m = _object(mBytes, maxManifestBytes);
    final c = _object(cBytes, 4096);
    _keys(c, {'kind', 'version', 'snapshotId', 'vaultId', 'manifestSha256'});
    _keys(m, {
      'kind',
      'version',
      'snapshotId',
      'vaultId',
      'producerId',
      'keyId',
      'createdAt',
      'recordCount',
      'parts',
      'blobs',
      'heads',
      'signature',
    });
    if (c['kind'] != kind ||
        c['version'] != version ||
        c['snapshotId'] != snapshotId ||
        c['vaultId'] != vaultId ||
        c['manifestSha256'] != sha256.convert(mBytes).toString() ||
        m['kind'] != kind ||
        m['version'] != version ||
        m['snapshotId'] != snapshotId ||
        m['vaultId'] != vaultId ||
        m['producerId'] != producerId ||
        m['keyId'] != keyId ||
        m['createdAt'] is! String ||
        DateTime.tryParse(m['createdAt'] as String)?.isUtc != true ||
        m['signature'] is! String) {
      throw const FormatException('Snapshot identity or commit mismatch.');
    }
    final payload = Map<String, dynamic>.from(m)..remove('signature');
    final signature = base64Url.decode(m['signature'] as String);
    if (signature.length != 64 ||
        !await Ed25519().verify([
          ...utf8.encode('VelockCurrentStateSnapshot/2\n'),
          ...snapshotJson(payload),
        ], signature: Signature(signature, publicKey: trustedSigningKey))) {
      throw const FormatException('Invalid snapshot signature.');
    }
    final count = _number(m['recordCount'], 0, 100000);
    final objects = <String, SnapshotObjectDigest>{};
    final parts = _list(m['parts'], 1000);
    var records = 0;
    var metadataBytes = 0;
    for (var index = 0; index < parts.length; index++) {
      final p = _map(parts[index]);
      _keys(p, {'number', 'size', 'sha256', 'records'});
      if (p['number'] != index + 1) {
        throw const FormatException('Invalid snapshot part order.');
      }
      records += _number(p['records'], 1, 500);
      final size = _number(p['size'], 1, 8 * 1024 * 1024);
      metadataBytes += size;
      objects['part-${index + 1}.enc'] = SnapshotObjectDigest(
        size,
        _digest(p['sha256']),
      );
    }
    if (records != count || metadataBytes > maxMetadataBytes) {
      throw const FormatException('Invalid snapshot record inventory.');
    }
    for (final raw in _list(m['blobs'], 100000)) {
      final b = _map(raw);
      _keys(b, {'id', 'size', 'sha256', 'chunkSize', 'protection'});
      final id = snapshotIdentifier(b['id']);
      if (objects.containsKey('blob-$id') ||
          b['protection'] != 'source-opaque') {
        throw const FormatException('Invalid snapshot blob inventory.');
      }
      _number(b['chunkSize'], 0, 1 << 40);
      objects['blob-$id'] = SnapshotObjectDigest(
        _number(b['size'], 1, 1 << 40),
        _digest(b['sha256']),
      );
    }
    final rawHeads = _map(m['heads']);
    if (rawHeads.length > 1000) {
      throw const FormatException('Too many snapshot heads.');
    }
    final heads = <String, ({int sequence, String batchId})>{};
    for (final e in rawHeads.entries) {
      final h = _map(e.value);
      _keys(h, {'sequence', 'batchId'});
      heads[snapshotIdentifier(e.key)] = (
        sequence: _number(h['sequence'], 1, 0x1fffffffffffff),
        batchId: snapshotIdentifier(h['batchId']),
      );
    }
    final result = VelockSnapshotInventory._(
      snapshotId: snapshotId,
      vaultId: vaultId,
      producerId: producerId,
      keyId: keyId,
      manifest: mBytes,
      commit: cBytes,
      objects: Map.unmodifiable(objects),
      heads: Map.unmodifiable(heads),
      recordCount: count,
    );
    if (maxTotalBytes < 1 || result.totalBytes > maxTotalBytes) {
      throw const FormatException('Snapshot exceeds storage budget.');
    }
    return result;
  }
}

class SnapshotObjectDigest {
  const SnapshotObjectDigest(this.size, this.sha256Hex);
  final int size;
  final String sha256Hex;
}

/// Transfers exact existing ciphertext. Commit is published last, after every
/// object has been read back and hashed; retry never overwrites any object.
/// Receipt/cursor installation is explicitly outside this transport's remit.
class VelockCurrentSnapshotTransport {
  const VelockCurrentSnapshotTransport();

  Future<void> upload({
    required Directory source,
    required VelockSnapshotInventory inventory,
    required RemoteObjectStore remote,
    RemoteOperationCancellation? cancellation,
    void Function(int completed, int total)? onProgress,
  }) async {
    await _directory(source);
    // A locally replaced manifest must not be paired with an older inventory.
    await _localBytes(source, 'manifest.json', inventory.manifest);
    await _localBytes(source, 'commit.json', inventory.commit);
    var completed = 0;
    Future<void> put(
      String name,
      Stream<List<int>> Function() read,
      SnapshotObjectDigest digest,
    ) async {
      cancellation?.throwIfCancelled();
      final key = '${inventory.remotePrefix}$name';
      if (await remote.stat(key, cancellation: cancellation) == null) {
        try {
          await remote.put(
            key,
            _checked(read(), digest),
            contentLength: digest.size,
            ifAbsent: true,
            cancellation: cancellation,
          );
        } on RemoteObjectAlreadyExistsException {
          // Concurrent immutable creation is acceptable only after full reread.
        }
      }
      await _checked(
        remote.read(key, cancellation: cancellation),
        digest,
      ).drain<void>();
      completed += digest.size;
      onProgress?.call(completed, inventory.totalBytes);
    }

    for (final e in inventory.objects.entries) {
      final file = await _regularFile(source, e.key);
      await put(e.key, file.openRead, e.value);
    }
    await put(
      'manifest.json',
      () => Stream.value(inventory.manifest),
      _bytesDigest(inventory.manifest),
    );
    await put(
      'commit.json',
      () => Stream.value(inventory.commit),
      _bytesDigest(inventory.commit),
    );
  }

  /// Verifies all opaque objects in an already published snapshot, even when
  /// stat/ETag claims they exist. Does not report business restoration success.
  Future<void> verifyRemote({
    required VelockSnapshotInventory inventory,
    required RemoteObjectStore remote,
    RemoteOperationCancellation? cancellation,
  }) async {
    for (final e in {
      ...inventory.objects,
      'manifest.json': _bytesDigest(inventory.manifest),
      'commit.json': _bytesDigest(inventory.commit),
    }.entries) {
      cancellation?.throwIfCancelled();
      await _checked(
        remote.read(
          '${inventory.remotePrefix}${e.key}',
          cancellation: cancellation,
        ),
        e.value,
      ).drain<void>();
    }
  }

  /// Atomically stages a complete package in an app-owned cache. Interrupted
  /// downloads keep only incomplete ciphertext; no usable commit is exposed.
  Future<Directory> download({
    required Directory destinationRoot,
    required VelockSnapshotInventory inventory,
    required RemoteObjectStore remote,
    RemoteOperationCancellation? cancellation,
  }) async {
    await destinationRoot.create(recursive: true);
    await _directory(destinationRoot);
    final target = Directory('${destinationRoot.path}/${inventory.snapshotId}');
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await _verifyLocal(target, inventory);
      return target;
    }
    // Unique staging prevents concurrent downloads from deleting each other.
    final pending = await destinationRoot.createTemp('.snapshot-');
    try {
      for (final e in inventory.objects.entries) {
        cancellation?.throwIfCancelled();
        final file = File('${pending.path}/${e.key}');
        final handle = await file.open(mode: FileMode.write);
        try {
          await for (final chunk in _checked(
            remote.read(
              '${inventory.remotePrefix}${e.key}',
              cancellation: cancellation,
            ),
            e.value,
          )) {
            await handle.writeFrom(chunk);
          }
          await handle.flush();
        } finally {
          await handle.close();
        }
      }
      // Recheck publication, then expose local commit only for this inventory.
      await _checked(
        remote.read(
          '${inventory.remotePrefix}manifest.json',
          cancellation: cancellation,
        ),
        _bytesDigest(inventory.manifest),
      ).drain<void>();
      await _checked(
        remote.read(
          '${inventory.remotePrefix}commit.json',
          cancellation: cancellation,
        ),
        _bytesDigest(inventory.commit),
      ).drain<void>();
      await File(
        '${pending.path}/manifest.json',
      ).writeAsBytes(inventory.manifest, flush: true);
      cancellation?.throwIfCancelled();
      await File(
        '${pending.path}/commit.json',
      ).writeAsBytes(inventory.commit, flush: true);
      // A losing concurrent writer verifies the winner; never overwrite it.
      if (await target.exists()) {
        await _verifyLocal(target, inventory);
        return target;
      }
      await pending.rename(target.path);
      return target;
    } finally {
      if (await pending.exists()) await pending.delete(recursive: true);
    }
  }

  Future<void> _verifyLocal(
    Directory dir,
    VelockSnapshotInventory inventory,
  ) async {
    await _directory(dir);
    await _localBytes(dir, 'manifest.json', inventory.manifest);
    await _localBytes(dir, 'commit.json', inventory.commit);
    for (final e in inventory.objects.entries) {
      final file = await _regularFile(dir, e.key);
      await _checked(file.openRead(), e.value).drain<void>();
    }
  }
}

Future<Uint8List> readSnapshotObject(
  Stream<List<int>> stream,
  int limit,
) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('Snapshot object exceeds size limit.');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

String snapshotIdentifier(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value) ||
      value.contains('..')) {
    throw const FormatException('Invalid snapshot identifier.');
  }
  return value;
}

Uint8List snapshotJson(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(_canonical(value))));
Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid snapshot object.');
  }
  return value;
}

Map<String, dynamic> _object(List<int> bytes, int limit) {
  if (bytes.isEmpty || bytes.length > limit) {
    throw const FormatException('Snapshot size limit.');
  }
  final result = _map(jsonDecode(utf8.decode(bytes)));
  final encoded = snapshotJson(result);
  if (encoded.length != bytes.length) {
    throw const FormatException('Noncanonical snapshot JSON.');
  }
  for (var i = 0; i < bytes.length; i++) {
    if (encoded[i] != bytes[i]) {
      throw const FormatException('Noncanonical snapshot JSON.');
    }
  }
  return result;
}

/// Requires [expected]; other keys are extensions, signed and canonical like
/// the rest (see `velock_exchange_extensions.dart`).
void _keys(Map<String, dynamic> map, Set<String> expected) {
  if (!map.keys.toSet().containsAll(expected)) {
    throw const FormatException('Unexpected snapshot fields.');
  }
}

List<dynamic> _list(Object? value, int limit) {
  if (value is! List || value.length > limit) {
    throw const FormatException('Snapshot list limit.');
  }
  return value;
}

int _number(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('Invalid snapshot integer.');
  }
  return value;
}

String _digest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException('Invalid snapshot digest.');
  }
  return value;
}

SnapshotObjectDigest _bytesDigest(List<int> bytes) =>
    SnapshotObjectDigest(bytes.length, sha256.convert(bytes).toString());
Future<void> _directory(Directory dir) async {
  if (await FileSystemEntity.type(dir.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException('Snapshot path is not a directory.');
  }
}

Future<File> _regularFile(Directory dir, String name) async {
  final file = File('${dir.path}/$name');
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException('Snapshot object is not a regular file.');
  }
  return file;
}

Future<void> _localBytes(Directory dir, String name, List<int> expected) async {
  final file = await _regularFile(dir, name);
  await _checked(file.openRead(), _bytesDigest(expected)).drain<void>();
}

Stream<List<int>> _checked(
  Stream<List<int>> input,
  SnapshotObjectDigest expected,
) async* {
  var length = 0;
  final sink = _HashSink();
  final hash = sha256.startChunkedConversion(sink);
  await for (final chunk in input) {
    length += chunk.length;
    if (length > expected.size) {
      throw const FormatException('Snapshot object grew.');
    }
    hash.add(chunk);
    yield chunk;
  }
  hash.close();
  if (length != expected.size ||
      sink.digest?.toString() != expected.sha256Hex) {
    throw const FormatException('Snapshot object integrity mismatch.');
  }
}

class _HashSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}
