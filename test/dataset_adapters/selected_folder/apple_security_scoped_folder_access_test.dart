import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/apple_security_scoped_folder_access.dart';

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
}
