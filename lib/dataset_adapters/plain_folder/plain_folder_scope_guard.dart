import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/sync_profiles/model/remote_root_segments.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

/// Raised when a plain mirror would cover a folder a Velock backup owns.
///
/// The mirror is plaintext and treats every remote file as user data: pointed
/// at a backup folder (or at any parent of one) it would upload, download and
/// — once a baseline exists — delete the encrypted objects the Velock app needs
/// to restore. That damage cannot be undone from this app, so the binding is
/// refused instead of warned about.
class BackupFolderOverlapException implements Exception {
  const BackupFolderOverlapException(this.backupName);

  /// The backup whose folder would be covered.
  final String backupName;

  @override
  String toString() => 'Plain sync would cover the backup "$backupName".';
}

/// Refuses a plain remote scope that overlaps a backup on the same connection.
///
/// Overlap means equal, an ancestor, or a descendant: all three put backup
/// objects inside the mirrored tree. Comparison ignores case because a WebDAV
/// server backed by a case-insensitive filesystem treats the two spellings as
/// one folder.
Future<void> assertPlainScopeAvoidsBackups({
  required SyncProfileRepository backups,
  required String connectionId,
  required Iterable<String> segments,
}) async {
  final wanted = PlainFolderSyncProfile.canonicalPlainRemoteRootSegments(
    segments,
  );
  for (final summary in await backups.listSummaries()) {
    final kind = summary.kind;
    if (kind != SyncDatasetKind.velockManaged &&
        kind != SyncDatasetKind.selectedFolder) {
      continue;
    }
    final profile = await backups.read(summary.profileId);
    if (profile == null || profile.connectionId != connectionId) continue;
    if (!remoteScopesOverlap(wanted, envelopeRemoteRootSegments(profile))) {
      continue;
    }
    throw BackupFolderOverlapException(
      profile.displayName.isEmpty ? '格间备份' : profile.displayName,
    );
  }
}

/// Whether two relative remote scopes share any folder (equal, ancestor or
/// descendant), compared case-insensitively.
bool remoteScopesOverlap(Iterable<String> a, Iterable<String> b) {
  final left = a.map((segment) => segment.toLowerCase()).toList();
  final right = b.map((segment) => segment.toLowerCase()).toList();
  final shared = left.length < right.length ? left.length : right.length;
  for (var index = 0; index < shared; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Raised when two sync locations would cover each other's folders.
///
/// Location A at `/X` and location B at `/X/Y` mirror the same files through two
/// independent baselines: a deletion on one side propagates into both trees, and
/// the two locations then fight over the result. Unlike a backup collision this
/// is not about encryption, so it is reported with its own wording.
class PlainLocationOverlapException implements Exception {
  const PlainLocationOverlapException(this.existingDisplayName);

  final String existingDisplayName;

  @override
  String toString() => 'Plain sync locations overlap: $existingDisplayName';
}

/// Refuses a scope that contains, sits inside, or equals another location's.
///
/// [selfProfileId] is excluded so re-saving an existing location (rename,
/// direction change, re-picking the same folder) is never blocked by itself.
Future<void> assertPlainScopeAvoidsOtherLocations({
  required PlainFolderSyncProfileRepository profiles,
  required String connectionId,
  required Iterable<String> segments,
  String? localRootReference,
  String? selfProfileId,
}) async {
  final wanted = PlainFolderSyncProfile.canonicalPlainRemoteRootSegments(
    segments,
  );
  for (final existing in await profiles.list()) {
    if (existing.profileId == selfProfileId) continue;
    if (!existing.isActive) continue;
    if (existing.connectionId != connectionId) continue;
    final existingScope =
        PlainFolderSyncProfile.canonicalPlainRemoteRootSegments(
          existing.remoteRootSegments,
        );
    if (!remoteScopesOverlap(wanted, existingScope)) continue;
    // Exactly the same remote folder is allowed from a DIFFERENT local folder
    // (two devices, or two local folders feeding one share: the documented
    // multi-device usage). One scope inside the other is not: those two
    // locations would mirror each other's files through independent baselines
    // and fight over every deletion.
    final sameScope =
        wanted.length == existingScope.length &&
        wanted.join('/') == existingScope.join('/');
    final sameLocal =
        localRootReference != null &&
        localRootReference == existing.localRootReference;
    if (sameScope && !sameLocal) continue;
    throw PlainLocationOverlapException(existing.displayName);
  }
}
