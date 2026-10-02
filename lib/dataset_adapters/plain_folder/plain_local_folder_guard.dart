import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';

/// How a picked local folder relates to the folder another location owns.
enum PlainLocalFolderRelation {
  /// Both are the same folder.
  same,

  /// The picked folder contains the other location's folder.
  contains,

  /// The picked folder sits inside the other location's folder.
  inside,
}

/// Raised when a local folder already belongs to another sync location.
///
/// One local folder belongs to exactly one location. Two locations over the
/// same files keep independent baselines and run independently, so a deletion
/// arriving through one remote is replayed to the other, conflict copies are
/// forwarded, and two concurrent runs see each other's half-written files.
class PlainLocalFolderInUseException implements Exception {
  const PlainLocalFolderInUseException({
    required this.existingDisplayName,
    required this.existingLocalName,
    required this.relation,
    required this.existingPaused,
  });

  final String existingDisplayName;
  final String existingLocalName;
  final PlainLocalFolderRelation relation;

  /// A paused location still owns its folder: resuming it would run both.
  final bool existingPaused;

  @override
  String toString() =>
      'Local folder already used by sync location $existingDisplayName '
      '(${relation.name})';
}

/// Comparable identity of a local folder.
///
/// The persisted reference is not comparable on its own: iOS hands out a new
/// opaque bookmark every time the same folder is picked. The identity is the
/// folder's location instead - a normalized path on iOS and desktop, the SAF
/// tree document on Android.
class PlainLocalFolderIdentity {
  const PlainLocalFolderIdentity._(
    this.namespace,
    this.key, {
    required this.hierarchical,
  });

  /// Separates identities that can never be compared (another SAF provider,
  /// a desktop path versus an iOS path).
  final String namespace;
  final String key;

  /// Whether [key] is a `/`-separated path, so containment can be decided.
  /// Opaque SAF document ids only support equality.
  final bool hierarchical;

  PlainLocalFolderRelation? relationTo(PlainLocalFolderIdentity other) {
    if (namespace != other.namespace) return null;
    if (key == other.key) return PlainLocalFolderRelation.same;
    if (!hierarchical || !other.hierarchical) return null;
    if (_isBelow(other.key, key)) return PlainLocalFolderRelation.contains;
    if (_isBelow(key, other.key)) return PlainLocalFolderRelation.inside;
    return null;
  }

  static bool _isBelow(String child, String parent) {
    final prefix = parent.endsWith('/') ? parent : '$parent/';
    return child.startsWith(prefix);
  }

  /// Normalized absolute path: no `.`/`..`, no trailing separator, and the
  /// Apple `/private` alias folded so `/private/var/x` equals `/var/x`.
  static String normalizePath(String path) {
    var normalized = p.posix.normalize(path.replaceAll(r'\', '/'));
    for (final alias in const ['/private/var', '/private/tmp']) {
      if (normalized == alias || normalized.startsWith('$alias/')) {
        normalized = normalized.substring('/private'.length);
        break;
      }
    }
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static PlainLocalFolderIdentity path(String path) =>
      PlainLocalFolderIdentity._(
        'path',
        normalizePath(path),
        hierarchical: true,
      );

  /// Identity of an Android SAF tree URI, or null when it is not one.
  ///
  /// `content://<authority>/tree/<documentId>[/document/...]`. External
  /// storage document ids are `<volume>:<path>`, so containment works there;
  /// other providers' ids are opaque and only compared for equality.
  static PlainLocalFolderIdentity? androidTree(String treeUri) {
    final uri = Uri.tryParse(treeUri);
    if (uri == null || uri.scheme != 'content') return null;
    final segments = uri.pathSegments;
    final treeIndex = segments.indexOf('tree');
    if (treeIndex < 0 || treeIndex + 1 >= segments.length) return null;
    var documentId = segments[treeIndex + 1];
    if (documentId.isEmpty) return null;
    final hierarchical =
        uri.authority == 'com.android.externalstorage.documents';
    if (hierarchical) {
      final colon = documentId.indexOf(':');
      if (colon >= 0) {
        final volume = documentId.substring(0, colon);
        final rest = documentId.substring(colon + 1);
        final path = rest.isEmpty ? '/' : normalizePath('/$rest');
        documentId = '$volume:$path';
      }
    }
    return PlainLocalFolderIdentity._(
      'saf:${uri.authority}',
      documentId,
      hierarchical: hierarchical,
    );
  }
}

/// Resolves the identity of a persisted local folder reference.
///
/// Returns null when it cannot be resolved (an iOS bookmark that no longer
/// opens). The caller then falls back to comparing the raw references.
Future<PlainLocalFolderIdentity?> resolvePlainLocalFolderIdentity({
  required FolderAccessKind kind,
  required String rootReference,
  required AppleSecurityScopedFolderAccess appleFolders,
}) async {
  switch (kind) {
    case FolderAccessKind.localPath:
      var path = p.absolute(rootReference);
      try {
        path = Directory(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        // A folder that vanished keeps its lexical path as identity. Sync on
        // purpose: one stat-like call, and it also runs inside widget tests.
      }
      return PlainLocalFolderIdentity.path(path);
    case FolderAccessKind.androidDocumentTree:
      return PlainLocalFolderIdentity.androidTree(rootReference);
    case FolderAccessKind.appleSecurityScopedBookmark:
      try {
        // The session is only held long enough to read the resolved location.
        final session = await appleFolders.acquire(rootReference);
        try {
          return PlainLocalFolderIdentity.path(session.path);
        } finally {
          await appleFolders.release(session.token);
        }
      } on Object {
        return null;
      }
  }
}

/// Refuses a local folder that is, contains, or sits inside the local folder
/// of another sync location (active or paused).
///
/// [selfProfileId] is excluded so a location re-picking its own folder is
/// never blocked by itself.
Future<void> assertPlainLocalFolderUnused({
  required PlainFolderSyncProfileRepository profiles,
  required FolderAccessKind kind,
  required String rootReference,
  required AppleSecurityScopedFolderAccess appleFolders,
  String? selfProfileId,
}) async {
  final others = [
    for (final existing in await profiles.list())
      if (existing.profileId != selfProfileId) existing,
  ];
  if (others.isEmpty) return;
  final wanted = await resolvePlainLocalFolderIdentity(
    kind: kind,
    rootReference: rootReference,
    appleFolders: appleFolders,
  );
  for (final existing in others) {
    PlainLocalFolderRelation? relation;
    if (existing.accessKind == kind &&
        existing.localRootReference == rootReference) {
      relation = PlainLocalFolderRelation.same;
    } else if (wanted != null) {
      final theirs = await resolvePlainLocalFolderIdentity(
        kind: existing.accessKind,
        rootReference: existing.localRootReference,
        appleFolders: appleFolders,
      );
      if (theirs != null) relation = wanted.relationTo(theirs);
    }
    if (relation == null) continue;
    throw PlainLocalFolderInUseException(
      existingDisplayName: existing.displayName,
      existingLocalName: existing.localDisplayName,
      relation: relation,
      existingPaused: !existing.isActive,
    );
  }
}
