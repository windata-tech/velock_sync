import 'dart:typed_data';

/// The source of a synchronised dataset. These values are provider-neutral.
enum DatasetKind { velockManaged }

enum DatasetAccessState { available, needsAuthorization, unavailable }

enum EncryptionMode { velockManaged }

enum RemoteProviderType {
  webDav,
  googleDrive,
  oneDrive,
  baiduNetdisk,
  aliyunDrive,
}

enum RemoteLayoutMode { managedVault }

enum SyncDirection { bidirectional, uploadOnly, downloadOnly }

enum SyncOperationType { upsert, delete, resolveConflict }

/// Entry kinds reserved for future dataset adapters.
enum FolderEntryType { file, directory }

enum VersionVectorComparison { equal, dominates, dominated, concurrent }

/// An immutable vector clock used to decide whether an incoming revision can
/// replace the local revision without losing an offline edit.
class VersionVector {
  VersionVector(Map<String, int> values)
    : _values = Map.unmodifiable({
        for (final entry in values.entries)
          if (entry.value > 0) entry.key: entry.value,
      });

  final Map<String, int> _values;

  Map<String, int> get values => _values;

  int operator [](String deviceId) => _values[deviceId] ?? 0;

  VersionVectorComparison compareTo(VersionVector other) {
    var thisGreater = false;
    var otherGreater = false;
    final devices = {..._values.keys, ...other._values.keys};

    for (final device in devices) {
      final current = this[device];
      final incoming = other[device];
      if (current > incoming) thisGreater = true;
      if (incoming > current) otherGreater = true;
    }

    if (!thisGreater && !otherGreater) return VersionVectorComparison.equal;
    if (thisGreater && !otherGreater) return VersionVectorComparison.dominates;
    if (!thisGreater && otherGreater) return VersionVectorComparison.dominated;
    return VersionVectorComparison.concurrent;
  }

  VersionVector incremented(String deviceId) {
    if (deviceId.isEmpty) throw ArgumentError.value(deviceId, 'deviceId');
    return VersionVector({..._values, deviceId: this[deviceId] + 1});
  }

  /// Produces the vector required for a conflict-resolution operation.
  VersionVector mergedAndIncremented(VersionVector other, String deviceId) {
    final merged = <String, int>{..._values};
    for (final entry in other._values.entries) {
      final current = merged[entry.key] ?? 0;
      if (entry.value > current) merged[entry.key] = entry.value;
    }
    return VersionVector(merged).incremented(deviceId);
  }

  @override
  bool operator ==(Object other) =>
      other is VersionVector && _mapsEqual(_values, other._values);

  @override
  int get hashCode => Object.hashAll(
    _values.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );

  static bool _mapsEqual(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    return a.entries.every((entry) => b[entry.key] == entry.value);
  }
}

class DatasetDescriptor {
  const DatasetDescriptor({
    required this.datasetId,
    required this.vaultId,
    required this.kind,
    required this.displayName,
    required this.accessState,
    required this.encryptionMode,
  });

  final String datasetId;
  final String vaultId;
  final DatasetKind kind;
  final String displayName;
  final DatasetAccessState accessState;
  final EncryptionMode encryptionMode;
}

class RemoteCapabilities {
  const RemoteCapabilities({
    required this.supportsConditionalCreate,
    required this.supportsConditionalUpdate,
    required this.supportsRangeDownload,
    required this.supportsResumableUpload,
    required this.supportsServerHash,
    required this.supportsTrash,
    required this.supportsHiddenAppFolder,
    required this.hasStrongListConsistency,
    this.maxSingleRequestBytes,
    this.recommendedChunkBytes,
  });

  static const unknown = RemoteCapabilities(
    supportsConditionalCreate: false,
    supportsConditionalUpdate: false,
    supportsRangeDownload: false,
    supportsResumableUpload: false,
    supportsServerHash: false,
    supportsTrash: false,
    supportsHiddenAppFolder: false,
    hasStrongListConsistency: false,
  );

  final bool supportsConditionalCreate;
  final bool supportsConditionalUpdate;
  final bool supportsRangeDownload;
  final bool supportsResumableUpload;
  final bool supportsServerHash;
  final bool supportsTrash;
  final bool supportsHiddenAppFolder;
  final bool hasStrongListConsistency;
  final int? maxSingleRequestBytes;
  final int? recommendedChunkBytes;
}

class RemoteTarget {
  const RemoteTarget({
    required this.targetId,
    required this.providerType,
    required this.displayName,
    required this.credentialRef,
    required this.providerRootRef,
    required this.capabilities,
    required this.layoutMode,
  });

  final String targetId;
  final RemoteProviderType providerType;
  final String displayName;
  final String credentialRef;
  final String providerRootRef;
  final RemoteCapabilities capabilities;
  final RemoteLayoutMode layoutMode;
}

class SyncOperation {
  const SyncOperation({
    required this.operationId,
    required this.entityId,
    required this.entityKind,
    required this.type,
    required this.versionVector,
    required this.revisionId,
    required this.protectedPayload,
    required this.blobIds,
    required this.createdAt,
    this.previousRevisionId,
  });

  final String operationId;
  final String entityId;
  final String entityKind;
  final SyncOperationType type;
  final VersionVector versionVector;
  final String revisionId;
  final String? previousRevisionId;
  final Uint8List protectedPayload;
  final List<String> blobIds;
  final DateTime createdAt;
}

class BlobDescriptor {
  const BlobDescriptor({
    required this.blobId,
    required this.cipherSize,
    required this.cipherSha256,
    this.mediaType = 'application/octet-stream',
    this.chunkSize = 0,
  });

  final String blobId;
  final int cipherSize;
  final String cipherSha256;
  final String mediaType;
  final int chunkSize;
}

/// Durable, provider-neutral metadata for one entry under a dataset.
/// root. File contents and user-visible paths never enter remote objects here;
/// this is strictly local scanner state.
class FolderScanEntry {
  const FolderScanEntry({
    required this.entityId,
    required this.relativePath,
    required this.type,
    required this.scanGeneration,
    this.size,
    this.modifiedAt,
    this.fileIdentity,
    this.contentHash,
    this.deletedAt,
    this.pendingGeneration,
  });

  final String entityId;
  final String relativePath;
  final FolderEntryType type;
  final int? size;
  final DateTime? modifiedAt;
  final String? fileIdentity;
  final String? contentHash;
  final int scanGeneration;
  final DateTime? deletedAt;
  final int? pendingGeneration;

  FolderScanEntry copyWith({
    String? entityId,
    String? relativePath,
    FolderEntryType? type,
    int? size,
    DateTime? modifiedAt,
    String? fileIdentity,
    String? contentHash,
    int? scanGeneration,
    DateTime? deletedAt,
    int? pendingGeneration,
  }) => FolderScanEntry(
    entityId: entityId ?? this.entityId,
    relativePath: relativePath ?? this.relativePath,
    type: type ?? this.type,
    size: size ?? this.size,
    modifiedAt: modifiedAt ?? this.modifiedAt,
    fileIdentity: fileIdentity ?? this.fileIdentity,
    contentHash: contentHash ?? this.contentHash,
    scanGeneration: scanGeneration ?? this.scanGeneration,
    deletedAt: deletedAt ?? this.deletedAt,
    pendingGeneration: pendingGeneration ?? this.pendingGeneration,
  );
}
