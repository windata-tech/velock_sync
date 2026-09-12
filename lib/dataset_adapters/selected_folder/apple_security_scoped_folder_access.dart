import 'dart:convert';

import 'package:flutter/services.dart';

/// iOS platform boundary for a user-selected directory. Only the opaque
/// bookmark is persisted. A filesystem path exists solely while a native
/// security-scoped access session is held for one operation.
abstract interface class AppleSecurityScopedFolderAccess {
  Future<String?> authorizeDirectory();

  Future<AppleSecurityScopedFolderSession> acquire(String bookmark);

  Future<void> release(String token);
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
    validateAppleSecurityScopedBookmark(bookmark);
    final response = await _channel.invokeMapMethod<String, Object?>(
      'acquireDirectory',
      {'bookmark': bookmark},
    );
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
