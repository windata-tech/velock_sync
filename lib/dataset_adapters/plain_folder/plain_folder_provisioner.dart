import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_scope_guard.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_local_folder_guard.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/repository/sync_profile_repository.dart';

/// Creates one plain folder sync location after the user picked both halves.
///
/// No key material, vault or recovery package is involved: the location keeps
/// only the authorized local folder reference and the remote folder path.
class PlainFolderProvisioner {
  PlainFolderProvisioner({
    required FolderAccessAuthorizer authorizer,
    required PlainFolderSyncProfileRepository profiles,
    required SyncProfileRepository backups,
    AppleSecurityScopedFolderAccess? appleFolders,
    Uuid? uuid,
    DateTime Function()? now,
  }) : _authorizer = authorizer,
       _profiles = profiles,
       _backups = backups,
       _appleFolders =
           appleFolders ?? const MethodChannelAppleSecurityScopedFolderAccess(),
       _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  final FolderAccessAuthorizer _authorizer;
  final PlainFolderSyncProfileRepository _profiles;

  /// Velock backups on this device. [create] refuses to run without it: a
  /// mirror may never be pointed at (or above, or below) a folder one of them
  /// owns, and a safety check a caller can forget is no check at all.
  final SyncProfileRepository _backups;
  final AppleSecurityScopedFolderAccess _appleFolders;
  final Uuid _uuid;
  final DateTime Function() _now;

  /// Asks the platform for a folder. Returns null when the user cancels.
  Future<FolderAccessGrant?> pickLocalFolder() =>
      _authorizer.authorizeDirectory();

  /// Creates the location from an already authorized folder.
  Future<PlainFolderSyncProfile> create({
    required FolderAccessGrant grant,
    required String displayName,
    required String localDisplayName,
    required String connectionId,
    required String deviceId,
    required List<String> remoteRootSegments,
    required MirrorDirection direction,
    required MirrorConflictPolicy conflictPolicy,
    MirrorInitialSyncPolicy initialSyncPolicy = MirrorInitialSyncPolicy.merge,
    SyncProfileBackgroundPolicy backgroundPolicy =
        const SyncProfileBackgroundPolicy(),
  }) async {
    if (displayName.trim().isEmpty) {
      throw ArgumentError.value(displayName, 'displayName');
    }
    if (connectionId.isEmpty || deviceId.isEmpty) {
      throw ArgumentError('Sync location identifiers must not be empty.');
    }
    final canonicalSegments =
        PlainFolderSyncProfile.canonicalPlainRemoteRootSegments(
          remoteRootSegments,
        );
    // A plaintext mirror over a backup folder would treat the encrypted objects
    // as user data. Refuse it before anything is written. The repository is a
    // required constructor argument, so the check cannot be skipped by a caller
    // that simply forgot it.
    final backups = _backups;
    await assertPlainScopeAvoidsBackups(
      backups: backups,
      connectionId: connectionId,
      segments: canonicalSegments,
    );
    // One local folder belongs to exactly one location, whatever the remote:
    // two locations over the same files replay each other's deletions and
    // conflict copies. Checked before the remote overlap so the user hears
    // about the folder they just picked.
    await assertLocalFolderUnused(grant);
    // Two locations whose remote folders contain one another mirror the same
    // files through two independent baselines and then fight over the result.
    await assertPlainScopeAvoidsOtherLocations(
      profiles: _profiles,
      connectionId: connectionId,
      segments: canonicalSegments,
    );
    final profile = PlainFolderSyncProfile(
      profileId: _uuid.v4(),
      datasetId: _uuid.v4(),
      deviceId: deviceId,
      displayName: displayName.trim(),
      localRootReference: grant.rootReference,
      localDisplayName: localDisplayName,
      accessKind: grant.kind,
      connectionId: connectionId,
      remoteRootSegments: canonicalSegments,
      direction: direction,
      conflictPolicy: conflictPolicy,
      initialSyncPolicy: initialSyncPolicy,
      backgroundEnabled: backgroundPolicy.enabled,
      backgroundAllowCellular: backgroundPolicy.allowCellular,
      backgroundRequiresCharging: backgroundPolicy.requiresCharging,
      backgroundCellularMaxTransferBytes:
          backgroundPolicy.cellularMaxTransferBytes,
      createdAt: _now().toUtc(),
    );
    await _profiles.save(profile);
    return profile;
  }

  /// Refuses a local folder another location already owns (same, containing,
  /// or inside). Callers run it right after the pick so the user hears about
  /// it immediately; [create] repeats it before writing anything.
  Future<void> assertLocalFolderUnused(
    FolderAccessGrant grant, {
    String? selfProfileId,
  }) => assertPlainLocalFolderUnused(
    profiles: _profiles,
    kind: grant.kind,
    rootReference: grant.rootReference,
    appleFolders: _appleFolders,
    selfProfileId: selfProfileId,
  );

  /// Human-readable folder name for the picked folder, or an empty string when
  /// the platform cannot derive one.
  ///
  /// The result is stored data, not a label: the UI is localized, so this method
  /// never invents a placeholder word. A caller that gets an empty string
  /// substitutes its own localized fallback.
  ///
  /// iOS returns an opaque bookmark, so the name is resolved through a short
  /// lived security-scoped session. Android exposes a SAF tree URI whose last
  /// document segment is the folder name.
  Future<String> resolveLocalDisplayName(FolderAccessGrant grant) async {
    switch (grant.kind) {
      case FolderAccessKind.localPath:
        return folderNameOf(grant.rootReference);
      case FolderAccessKind.androidDocumentTree:
        return _androidTreeName(grant.rootReference);
      case FolderAccessKind.appleSecurityScopedBookmark:
        try {
          final session = await _appleFolders.acquire(grant.rootReference);
          try {
            return folderNameOf(session.path);
          } finally {
            await _appleFolders.release(session.token);
          }
        } on Object {
          return '';
        }
    }
  }

  /// Last segment of a local path, or an empty string for a root or relative
  /// path the caller cannot show.
  static String folderNameOf(String path) {
    final name = p.basename(path);
    if (name.isEmpty || name == '/' || name == '.' || name == '..') return '';
    return name;
  }

  static String _androidTreeName(String treeUri) {
    final uri = Uri.tryParse(treeUri);
    if (uri == null || uri.pathSegments.isEmpty) return '';
    final last = Uri.decodeComponent(uri.pathSegments.last);
    final separator = last.contains(':') ? ':' : '/';
    final parts = last.split(separator).where((part) => part.isNotEmpty);
    if (parts.isEmpty) return '';
    return parts.last;
  }
}

/// Locates the shared device identifier used by every V1 profile.
Future<String> resolvePlainSyncDeviceId({
  required Future<String?> Function() read,
  required Future<void> Function(String value) write,
  required String Function() create,
}) async {
  final existing = await read();
  if (existing != null && existing.isNotEmpty) return existing;
  final created = create();
  await write(created);
  return created;
}

/// Convenience for tests and services that only need a directory path.
Directory? plainLocalDirectory(PlainFolderSyncProfile profile) =>
    profile.accessKind == FolderAccessKind.localPath
    ? Directory(profile.localRootReference)
    : null;
