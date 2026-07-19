import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';

void main() {
  test(
    'FolderAccessAuthorizer keeps its result nullable for picker cancellation',
    () async {
      final authorizer = _FakeFolderAccessAuthorizer(null);

      expect(await authorizer.authorizeDirectory(), isNull);
    },
  );

  test(
    'FolderAccessAuthorizer result is a directory available to the scanner',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'velock-folder-access-',
      );
      addTearDown(() => root.delete(recursive: true));
      final authorizer = _FakeFolderAccessAuthorizer(root);

      final grant = (await authorizer.authorizeDirectory())!;
      expect(grant.kind, FolderAccessKind.localPath);
      expect(grant.rootReference, root.path);
    },
  );

  test('Android document tree grants retain only a content URI', () {
    final grant = FolderAccessGrant.androidDocumentTree(
      'content://com.android.externalstorage.documents/tree/primary%3ADocuments',
    );

    expect(grant.kind, FolderAccessKind.androidDocumentTree);
    expect(grant.rootReference, startsWith('content://'));
    expect(
      () => FolderAccessGrant.androidDocumentTree('/storage/emulated/0'),
      throwsArgumentError,
    );
  });

  test('Apple directory grants retain only opaque bookmark data', () {
    final bookmark = base64Encode([1, 2, 3, 4]);
    final grant = FolderAccessGrant.appleSecurityScopedBookmark(bookmark);

    expect(grant.kind, FolderAccessKind.appleSecurityScopedBookmark);
    expect(grant.rootReference, bookmark);
    expect(
      () => FolderAccessGrant.appleSecurityScopedBookmark('not-base64!'),
      throwsArgumentError,
    );
    expect(
      () => FolderAccessGrant.appleSecurityScopedBookmark(''),
      throwsArgumentError,
    );
  });
}

class _FakeFolderAccessAuthorizer implements FolderAccessAuthorizer {
  const _FakeFolderAccessAuthorizer(this.value);

  final Directory? value;

  @override
  Future<FolderAccessGrant?> authorizeDirectory() async =>
      value == null ? null : FolderAccessGrant.localPath(value!);
}
