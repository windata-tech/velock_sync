import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/sync_core/model/sync_failure.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/apple-selected-folder');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'authorize returns a validated bookmark and preserves cancellation',
    () async {
      final bookmark = base64Encode([1, 2, 3]);
      var response = bookmark;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'authorizeDirectory');
            return response;
          });
      const access = MethodChannelAppleSecurityScopedFolderAccess(
        channel: channel,
      );

      expect(await access.authorizeDirectory(), bookmark);
      response = '';
      expect(access.authorizeDirectory(), throwsArgumentError);
    },
  );

  test('acquire and release use one opaque native session', () async {
    final bookmark = base64Encode([4, 5, 6]);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'acquireDirectory') {
            return {'token': 'session-1', 'path': '/private/authorized'};
          }
          return null;
        });
    const access = MethodChannelAppleSecurityScopedFolderAccess(
      channel: channel,
    );

    final session = await access.acquire(bookmark);
    expect(session.path, '/private/authorized');
    expect(session.token, 'session-1');
    await access.release(session.token);
    expect(calls.map((call) => call.method), [
      'acquireDirectory',
      'releaseDirectory',
    ]);
    expect((calls.first.arguments as Map)['bookmark'], bookmark);
    expect((calls.last.arguments as Map)['token'], 'session-1');
  });

  test('acquire fails closed on an invalid native response', () async {
    final bookmark = base64Encode([7, 8, 9]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => {'path': '/tmp'});
    const access = MethodChannelAppleSecurityScopedFolderAccess(
      channel: channel,
    );

    expect(access.acquire(bookmark), throwsFormatException);
  });

  test(
    'acquire reports a stale or revoked bookmark as lost local access',
    () async {
      final bookmark = base64Encode([10, 11, 12]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'acquireDirectory');
            throw PlatformException(
              code: 'BOOKMARK_RESOLVE',
              message: 'The directory authorization is stale.',
            );
          });
      const access = MethodChannelAppleSecurityScopedFolderAccess(
        channel: channel,
      );

      final failure = await access
          .acquire(bookmark)
          .then<Object?>(
            (session) => session,
            onError: (Object error) => error,
          );

      expect(
        failure,
        isA<AppleSecurityScopedFolderAccessLostException>(),
        reason: 'a stale bookmark is a lost folder, not an unexpected error',
      );
      // Selected-folder callers may keep catching the storage-level failure.
      expect(failure, isA<FolderRootUnavailableException>());
      expect(
        (failure! as AppleSecurityScopedFolderAccessLostException).nativeCode,
        'BOOKMARK_RESOLVE',
      );
      // The code the plain file sync screens turn into
      // "请在详情页重新选择本机文件夹" - the message that used to be unreachable
      // on the reinstall/restore case because the failure classified as
      // sync.unexpected instead.
      final classified = SyncFailureClassifier.classify(failure);
      expect(classified.errorCode, 'plain_folder.local_access_lost');
      expect(classified.category, SyncErrorCategory.localAccessLost);
      expect(classified.retryable, isFalse);
    },
  );

  test('acquire treats an unusable stored bookmark as lost access', () async {
    var channelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          channelCalls++;
          return null;
        });
    const access = MethodChannelAppleSecurityScopedFolderAccess(
      channel: channel,
    );

    await expectLater(
      access.acquire('not-a-bookmark'),
      throwsA(isA<AppleSecurityScopedFolderAccessLostException>()),
    );
    expect(
      channelCalls,
      0,
      reason: 'an unusable bookmark never reaches the platform',
    );
  });

  test('acquireOrReportLostAccess maps a foreign implementation', () async {
    // The mapping must not depend on the implementation knowing the typed
    // failure: a hand-written or future facade may still throw a raw error.
    final failure = await _ThrowingAppleAccess(const FormatException('nope'))
        .acquireOrReportLostAccess('stored-bookmark')
        .then<Object?>((session) => session, onError: (Object error) => error);

    expect(failure, isA<AppleSecurityScopedFolderAccessLostException>());
    expect(
      SyncFailureClassifier.classify(failure!).errorCode,
      'plain_folder.local_access_lost',
    );
  });

  test('acquireOrReportLostAccess keeps a typed failure unchanged', () async {
    final failure =
        await _ThrowingAppleAccess(
              const AppleSecurityScopedFolderAccessLostException(
                'stored-bookmark',
                nativeCode: 'BOOKMARK_RESOLVE',
              ),
            )
            .acquireOrReportLostAccess('stored-bookmark')
            .then<Object?>(
              (session) => session,
              onError: (Object error) => error,
            );

    expect(
      (failure! as AppleSecurityScopedFolderAccessLostException).nativeCode,
      'BOOKMARK_RESOLVE',
    );
  });
}

class _ThrowingAppleAccess implements AppleSecurityScopedFolderAccess {
  const _ThrowingAppleAccess(this.error);

  final Object error;

  @override
  Future<String?> authorizeDirectory() async => null;

  @override
  Future<AppleSecurityScopedFolderSession> acquire(String bookmark) async =>
      throw error;

  @override
  Future<void> release(String token) async {}
}
