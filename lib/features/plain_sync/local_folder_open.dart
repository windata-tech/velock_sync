import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/l10n/sync_locale.dart';

/// What happened when a sync folder was handed to the system file manager.
enum FolderOpenOutcome {
  /// The system file manager was asked to show the folder.
  opened,

  /// Nothing on this device handles the folder, or the hand-off failed.
  unavailable,
}

/// Opens a folder with the operating system's own file manager.
///
/// Injectable so the URL construction stays testable without a device.
typedef FolderLauncher = Future<bool> Function(Uri uri);

final folderLauncherProvider = Provider<FolderLauncher>(
  (ref) => (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// iOS resolves a security-scoped bookmark to a path only inside a native
/// session; that session is closed again as soon as the path is known because
/// the file manager works with its own access.
final appleFolderAccessProvider = Provider<AppleSecurityScopedFolderAccess>(
  (ref) => const MethodChannelAppleSecurityScopedFolderAccess(),
);

/// Best-effort hand-off of a local sync folder to the system file manager.
///
/// * Android document trees open through their `content://` tree URI, which is
///   what the system Files app and other document providers handle.
/// * iOS opens the Files app at the folder through `shareddocuments://`.
/// * Plain paths (desktop) open as `file://` URLs.
///
/// The folder stays untouched either way: this never writes, moves or deletes
/// anything, and a device without a handler only reports [FolderOpenOutcome.
/// unavailable] so the caller can show the path instead.
Future<FolderOpenOutcome> openLocalFolderInFileManager(
  FolderAccessGrant grant, {
  required FolderLauncher launch,
  required AppleSecurityScopedFolderAccess appleFolders,
}) async {
  try {
    switch (grant.kind) {
      case FolderAccessKind.androidDocumentTree:
        return await _handOff(launch, Uri.parse(grant.rootReference));
      case FolderAccessKind.localPath:
        return await _handOff(launch, Uri.file(grant.rootReference));
      case FolderAccessKind.appleSecurityScopedBookmark:
        final session = await appleFolders.acquire(grant.rootReference);
        try {
          return await _handOff(
            launch,
            Uri.parse('shareddocuments://${session.path}'),
          );
        } finally {
          await appleFolders.release(session.token);
        }
    }
  } on Object {
    return FolderOpenOutcome.unavailable;
  }
}

Future<FolderOpenOutcome> _handOff(FolderLauncher launch, Uri uri) async =>
    await launch(uri)
    ? FolderOpenOutcome.opened
    : FolderOpenOutcome.unavailable;

/// Rebuilds the folder grant a sync location stored (kind + reference).
FolderAccessGrant grantForLocalRoot({
  required FolderAccessKind kind,
  required String rootReference,
}) => switch (kind) {
  FolderAccessKind.localPath => FolderAccessGrant.localPath(
    Directory(rootReference),
  ),
  FolderAccessKind.androidDocumentTree => FolderAccessGrant.androidDocumentTree(
    rootReference,
  ),
  FolderAccessKind.appleSecurityScopedBookmark =>
    FolderAccessGrant.appleSecurityScopedBookmark(rootReference),
};

/// Wording for a hand-off that did not work, including the folder to look for.
String folderOpenUnavailableMessage(BuildContext context, String folder) =>
    syncText(
      context,
      '这个设备上没有可以打开文件夹的应用。文件夹位置：$folder',
      'No file manager on this device could open the folder. Folder: $folder',
    );
