import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

/// iOS platform boundary for a user-selected directory. Only the opaque
/// bookmark is persisted. A filesystem path exists solely while a native
/// security-scoped access session is held for one operation.
abstract interface class AppleSecurityScopedFolderAccess {
  Future<String?> authorizeDirectory();

  /// Opens one security-scoped session for a persisted [bookmark].
  ///
  /// Fails with [AppleSecurityScopedFolderAccessLostException] when the stored
  /// bookmark can no longer be turned into a readable directory: the exact
  /// situation after a reinstall, a restore onto another device or a revoked
  /// permission. That is a "choose the folder again" action for the user, not
  /// an unexpected sync failure.
  Future<AppleSecurityScopedFolderSession> acquire(String bookmark);

  Future<void> release(String token);
}

/// A persisted bookmark no longer opens its directory.
///
/// It is [FolderRootUnavailableException]-compatible so selected-folder callers
/// keep working, and it classifies as `plain_folder.local_access_lost` - the
/// code the plain file sync screens already translate into
/// "请在详情页重新选择本机文件夹" - instead of the generic `sync.unexpected`.
class AppleSecurityScopedFolderAccessLostException
    extends FolderRootUnavailableException
    implements SyncFailureException {
  const AppleSecurityScopedFolderAccessLostException(
    super.rootPath, {
    this.nativeCode,
  });

  /// `FlutterError.code` reported by iOS (`BOOKMARK_RESOLVE`,
  /// `BOOKMARK_INVALID`); diagnostics only, never persisted.
  final String? nativeCode;

  @override
  SyncFailure get syncFailure => const SyncFailure(
    errorCode: 'plain_folder.local_access_lost',
    category: SyncErrorCategory.localAccessLost,
    retryable: false,
    suggestedAction: '本机文件夹的访问权限已失效，请在详情页重新选择本机文件夹。',
  );

  @override
  String toString() =>
      'The selected folder authorization is no longer usable: $rootPath';
}

/// Reports every acquisition failure as lost local access.
extension AppleSecurityScopedFolderAccessLostMapping
    on AppleSecurityScopedFolderAccess {
  /// Acquires [bookmark] for an operation that must tell the user to choose the
  /// local folder again.
  ///
  /// Differs from [AppleSecurityScopedFolderAccess.acquire] only in that any
  /// failure - including one raised by an injected implementation that does not
  /// know [AppleSecurityScopedFolderAccessLostException] - becomes that
  /// documented failure instead of an unclassified error.
  Future<AppleSecurityScopedFolderSession> acquireOrReportLostAccess(
    String bookmark,
  ) async {
    try {
      return await acquire(bookmark);
    } on AppleSecurityScopedFolderAccessLostException {
      rethrow;
    } on Object {
      // Opening a persisted bookmark has exactly two meanings for the user:
      // the authorization still works, or it has to be granted again.
      throw AppleSecurityScopedFolderAccessLostException(bookmark);
    }
  }
}

class AppleSecurityScopedFolderSession {
  const AppleSecurityScopedFolderSession({
    required this.token,
    required this.path,
  });

  final String token;
  final String path;
}

class MethodChannelAppleSecurityScopedFolderAccess
    implements AppleSecurityScopedFolderAccess {
  const MethodChannelAppleSecurityScopedFolderAccess({
    MethodChannel channel = const MethodChannel(
      'tech.windata.velock.sync/selected_folder',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<String?> authorizeDirectory() async {
    final bookmark = await _channel.invokeMethod<String>('authorizeDirectory');
    if (bookmark == null) return null;
    validateAppleSecurityScopedBookmark(bookmark);
    return bookmark;
  }

  @override
  Future<AppleSecurityScopedFolderSession> acquire(String bookmark) async {
    try {
      validateAppleSecurityScopedBookmark(bookmark);
    } on ArgumentError {
      // A stored bookmark that is not even valid base64 can never be resolved,
      // which is the same user-visible situation as a stale bookmark.
      throw AppleSecurityScopedFolderAccessLostException(bookmark);
    }
    final Map<String, Object?>? response;
    try {
      response = await _channel.invokeMapMethod<String, Object?>(
        'acquireDirectory',
        {'bookmark': bookmark},
      );
    } on PlatformException catch (error) {
      // iOS answers BOOKMARK_RESOLVE / BOOKMARK_INVALID here: the bookmark is
      // stale (reinstall, restore, revoked permission) or its directory is
      // unreadable. Report lost local access so callers can ask the user to
      // choose the folder again.
      throw AppleSecurityScopedFolderAccessLostException(
        bookmark,
        nativeCode: error.code,
      );
    }
    final token = response?['token'];
    final path = response?['path'];
    if (token is! String || token.isEmpty || path is! String || path.isEmpty) {
      throw const FormatException(
        'iOS selected-folder access response is invalid.',
      );
    }
    return AppleSecurityScopedFolderSession(token: token, path: path);
  }

  @override
  Future<void> release(String token) async {
    if (token.isEmpty) {
      throw ArgumentError.value(token, 'token', 'must not be empty');
    }
    await _channel.invokeMethod<void>('releaseDirectory', {'token': token});
  }
}

void validateAppleSecurityScopedBookmark(String bookmark) {
  if (bookmark.isEmpty) {
    throw ArgumentError.value(bookmark, 'bookmark', 'must not be empty');
  }
  try {
    if (base64Decode(bookmark).isEmpty) {
      throw const FormatException('Bookmark data is empty.');
    }
  } on FormatException {
    throw ArgumentError.value(
      bookmark,
      'bookmark',
      'must be non-empty base64 bookmark data',
    );
  }
}
