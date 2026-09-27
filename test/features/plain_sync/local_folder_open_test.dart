/// The local "open" action is a hand-off, not a filesystem change.
///
/// Each stored grant kind maps to the URL the system file manager understands:
/// an Android document tree keeps its `content://` URI, an Apple
/// security-scoped bookmark is resolved inside a native session and opened as
/// `shareddocuments://<path>`, and a plain path opens as a `file://` URL. The
/// native session is always released, and a device without a handler reports
/// "unavailable" instead of throwing.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/features/plain_sync/local_folder_open.dart';

class _FakeAppleAccess implements AppleSecurityScopedFolderAccess {
  static const path = '/private/var/mobile/Documents/照片';

  final List<String> acquired = [];
  final List<String> released = [];

  @override
  Future<String?> authorizeDirectory() async => null;

  @override
  Future<AppleSecurityScopedFolderSession> acquire(String bookmark) async {
    acquired.add(bookmark);
    return AppleSecurityScopedFolderSession(token: 'token-1', path: path);
  }

  @override
  Future<void> release(String token) async => released.add(token);
}

void main() {
  /// Records the URLs the OS would be asked to open.
  FolderLauncher launcher(List<Uri> launched, {required bool handled}) =>
      (uri) async {
        launched.add(uri);
        return handled;
      };

  test('an Android document tree opens through its content URI', () async {
    final launched = <Uri>[];
    final outcome = await openLocalFolderInFileManager(
      FolderAccessGrant.androidDocumentTree(
        'content://com.android.externalstorage.documents/tree/primary%3APhotos',
      ),
      launch: launcher(launched, handled: true),
      appleFolders: _FakeAppleAccess(),
    );

    expect(outcome, FolderOpenOutcome.opened);
    expect(launched.single.scheme, 'content');
    expect(
      launched.single.toString(),
      'content://com.android.externalstorage.documents/tree/primary%3APhotos',
    );
  });

  test('an Apple bookmark opens the Files app at the folder', () async {
    final launched = <Uri>[];
    final apple = _FakeAppleAccess();

    final outcome = await openLocalFolderInFileManager(
      FolderAccessGrant.appleSecurityScopedBookmark('Ym9va21hcms='),
      launch: launcher(launched, handled: true),
      appleFolders: apple,
    );

    expect(outcome, FolderOpenOutcome.opened);
    expect(apple.acquired, ['Ym9va21hcms=']);
    expect(launched.single.toString(), startsWith('shareddocuments://'));
    expect(
      Uri.decodeComponent(launched.single.path),
      '/private/var/mobile/Documents/照片',
    );
    // The security-scoped session is closed again straight away: the file
    // manager works with its own access.
    expect(apple.released, ['token-1']);
  });

  test('a plain path opens as a file URL', () async {
    final launched = <Uri>[];
    final outcome = await openLocalFolderInFileManager(
      FolderAccessGrant.localPath(Directory('/Users/me/照片')),
      launch: launcher(launched, handled: true),
      appleFolders: _FakeAppleAccess(),
    );

    expect(outcome, FolderOpenOutcome.opened);
    expect(launched.single.scheme, 'file');
    expect(Uri.decodeComponent(launched.single.path), '/Users/me/照片');
  });

  test('a device without a handler reports unavailable', () async {
    final launched = <Uri>[];
    final outcome = await openLocalFolderInFileManager(
      FolderAccessGrant.localPath(Directory('/Users/me/照片')),
      launch: launcher(launched, handled: false),
      appleFolders: _FakeAppleAccess(),
    );

    expect(outcome, FolderOpenOutcome.unavailable);
    expect(launched, hasLength(1));
  });

  test('a broken bookmark never throws', () async {
    final launched = <Uri>[];
    final outcome = await openLocalFolderInFileManager(
      FolderAccessGrant.appleSecurityScopedBookmark('Ym9va21hcms='),
      launch: launcher(launched, handled: true),
      appleFolders: _FailingAppleAccess(),
    );

    expect(outcome, FolderOpenOutcome.unavailable);
    expect(launched, isEmpty);
  });
}

class _FailingAppleAccess implements AppleSecurityScopedFolderAccess {
  @override
  Future<String?> authorizeDirectory() async => null;

  @override
  Future<AppleSecurityScopedFolderSession> acquire(String bookmark) async =>
      throw StateError('stale bookmark');

  @override
  Future<void> release(String token) async {}
}
