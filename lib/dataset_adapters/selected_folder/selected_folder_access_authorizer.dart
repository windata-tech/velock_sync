import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/android_document_tree_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';

/// Grants the user-selected directory to a Selected Folder profile. The path
/// is only accepted after the platform picker returns and access is verified.
/// Android persists an SAF tree URI, never an unreliable converted path.
abstract interface class FolderAccessAuthorizer {
  Future<FolderAccessGrant?> authorizeDirectory();
}

enum FolderAccessKind {
  localPath,
  androidDocumentTree,
  appleSecurityScopedBookmark,
}

class FolderAccessGrant {
  const FolderAccessGrant._({required this.kind, required this.rootReference});

  factory FolderAccessGrant.localPath(Directory directory) =>
      FolderAccessGrant._(
        kind: FolderAccessKind.localPath,
        rootReference: directory.path,
      );

  factory FolderAccessGrant.androidDocumentTree(String treeUri) {
    if (!treeUri.startsWith('content://')) {
      throw ArgumentError.value(treeUri, 'treeUri', 'must be a content URI');
    }
    return FolderAccessGrant._(
      kind: FolderAccessKind.androidDocumentTree,
      rootReference: treeUri,
    );
  }

  factory FolderAccessGrant.appleSecurityScopedBookmark(String bookmark) {
    validateAppleSecurityScopedBookmark(bookmark);
    return FolderAccessGrant._(
      kind: FolderAccessKind.appleSecurityScopedBookmark,
      rootReference: bookmark,
    );
  }

  final FolderAccessKind kind;
  final String rootReference;
}

class NativeFolderAccessAuthorizer implements FolderAccessAuthorizer {
  NativeFolderAccessAuthorizer({
    AndroidDocumentTreeAccess? androidDocumentTrees,
    AppleSecurityScopedFolderAccess? appleFolders,
  }) : _androidDocumentTrees =
           androidDocumentTrees ?? MethodChannelAndroidDocumentTreeAccess(),
       _appleFolders =
           appleFolders ?? const MethodChannelAppleSecurityScopedFolderAccess();

  final AndroidDocumentTreeAccess _androidDocumentTrees;
  final AppleSecurityScopedFolderAccess _appleFolders;

  @override
  Future<FolderAccessGrant?> authorizeDirectory() async {
    if (Platform.isAndroid) {
      final treeUri = await _androidDocumentTrees.authorizeTree();
      return treeUri == null
          ? null
          : FolderAccessGrant.androidDocumentTree(treeUri);
    }
    if (Platform.isIOS) {
      final bookmark = await _appleFolders.authorizeDirectory();
      return bookmark == null
          ? null
          : FolderAccessGrant.appleSecurityScopedBookmark(bookmark);
    }
    final path = await getDirectoryPath(confirmButtonText: '选择同步文件夹');
    if (path == null) return null;
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw StateError('The selected directory is no longer accessible.');
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw StateError('The selected item is not a directory.');
    }
    return FolderAccessGrant.localPath(directory);
  }
}
