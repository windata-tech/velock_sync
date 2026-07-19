import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/providers/oauth/oauth_callback_link_receiver.dart';

void main() {
  test(
    'buffers only the registered callback and matches it by OAuth state',
    () async {
      final links = StreamController<Uri>();
      final receiver = OAuthCallbackLinkReceiver(links.stream);
      addTearDown(() async {
        await receiver.dispose();
        await links.close();
      });

      links.add(Uri.parse('velocksync://other/callback?state=ignored'));
      links.add(
        Uri.parse('velocksync://oauth/callback?state=expected&code=code'),
      );
      await Future<void>.delayed(Duration.zero);

      final callback = await receiver.waitForCallback('expected');

      expect(callback.queryParameters['code'], 'code');
    },
  );

  test('recognizes only the narrow registered OAuth callback URI', () {
    expect(
      OAuthCallbackLinkReceiver.isOAuthCallback(
        Uri.parse('velocksync://oauth/callback'),
      ),
      isTrue,
    );
    expect(
      OAuthCallbackLinkReceiver.isOAuthCallback(
        Uri.parse('https://oauth/callback'),
      ),
      isFalse,
    );
  });
}
