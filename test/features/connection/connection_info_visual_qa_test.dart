/// Visual QA for the connection notes sheet.
///
/// Run with a real CJK font and an output directory:
///   BACKUP_UI_FONT=/System/Library/Fonts/STHeiti\ Medium.ttc \
///   BACKUP_UI_SCREENSHOT_DIR=/tmp/connection-info-qa \
///   flutter test test/features/connection/connection_info_visual_qa_test.dart
///
/// Without those variables the test still runs (and asserts the sheet renders)
/// but writes no files.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/ui/connection_info_sheet.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

void main() {
  final captureKey = GlobalKey();

  setUpAll(() async {
    final font = Platform.environment['BACKUP_UI_FONT'];
    if (font != null && File(font).existsSync()) {
      final bytes = File(font).readAsBytes();
      for (final family in const ['ConnQA', 'Roboto', '.SF Pro Text']) {
        final loader = FontLoader(family)
          ..addFont(bytes.then((b) => ByteData.sublistView(b)));
        await loader.load();
      }
    }
    for (final entry in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    }.entries) {
      final icons = FontLoader(entry.key)
        ..addFont(rootBundle.load(entry.value));
      await icons.load();
    }
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['BACKUP_UI_SCREENSHOT_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> show(
    WidgetTester tester,
    ProtocolModel protocol,
    Locale locale,
  ) async {
    // A fresh key per capture: the same widget type would otherwise reuse the
    // previous Navigator, keeping the last sheet on screen.
    await tester.pumpWidget(
      KeyedSubtree(
        key: UniqueKey(),
        child: _harness(captureKey, protocol, locale),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('captures the connection notes for WebDAV and a cloud drive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(440, 956);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await show(tester, _webDav, const Locale('zh'));
    expect(find.text('连接说明'), findsOneWidget);
    expect(find.text('登录信息'), findsOneWidget);
    expect(find.textContaining('不支持断点续传'), findsOneWidget);
    await capture(tester, '01-webdav-zh');

    await show(tester, _googleDrive, const Locale('zh'));
    expect(find.textContaining('PKCE'), findsOneWidget);
    await capture(tester, '02-google-drive-zh');

    await show(tester, _webDav, const Locale('en'));
    expect(find.text('Connection info'), findsOneWidget);
    expect(find.textContaining('No resume'), findsOneWidget);
    await capture(tester, '03-webdav-en');
  });
}

const _webDav = ProtocolModel.webDav(
  protocolType: WebDavProtocolType.https,
  address: 'https://dav.example.test',
  port: '443',
);

const _googleDrive = ProtocolModel.oauth(
  providerType: RemoteProviderType.googleDrive,
  clientId: 'public-client',
  credentialRef: 'opaque-ref',
  rootId: 'root',
);

Widget _harness(GlobalKey captureKey, ProtocolModel protocol, Locale locale) =>
    ProviderScope(
      child: MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          platform: TargetPlatform.iOS,
          fontFamily: 'ConnQA',
          cupertinoOverrideTheme: CupertinoThemeData(
            textTheme: CupertinoTextThemeData(
              textStyle: const CupertinoTextThemeData().textStyle.copyWith(
                fontFamily: 'ConnQA',
              ),
              actionTextStyle: const CupertinoTextThemeData().actionTextStyle
                  .copyWith(fontFamily: 'ConnQA'),
            ),
          ),
        ),
        // A Cupertino popup has no Material ancestor of its own, so the sheet
        // inherits this style instead of the test fallback font.
        builder: (context, child) => RepaintBoundary(
          key: captureKey,
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'ConnQA'),
            child: child!,
          ),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            backgroundColor: const Color(0xFFF2F2F7),
            body: Center(
              child: TextButton(
                onPressed: () => showConnectionInfoSheet(context, protocol),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
