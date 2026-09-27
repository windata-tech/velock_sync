import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

const _rootPath = '/backup';
const _childPath = '/backup/child';
const _loadingKey = Key('remote-browser-loading');
const _currentPathKey = Key('remote-browser-current-path');

final _connection = ConnectionModel(
  id: 'test',
  name: 'Test NAS',
  source: 'test',
  target: 'test',
  protocol: const WebDavProtocolModel(
    protocolType: WebDavProtocolType.https,
    address: 'https://example.invalid',
    port: '443',
    path: _rootPath,
  ),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: ConnectionStatus.active,
);

FileBrowserState _parentState() => FileBrowserState(
  path: _rootPath,
  rootPath: _rootPath,
  files: [WebdavFile(path: _childPath, isDir: true, name: 'child')],
);

FileBrowserState _childState() => FileBrowserState(
  path: _childPath,
  rootPath: _rootPath,
  files: [
    WebdavFile(
      path: '/backup/child/inside.txt',
      isDir: false,
      name: 'inside-child',
    ),
  ],
);

class _Detail extends ConnectionDetail {
  @override
  Future<ConnectionModel?> build(String id) async => _connection;
}

class _ControlledBrowser extends RemoteFileBrowser {
  _ControlledBrowser({required this.initialState, this.initialCompleter});

  final FileBrowserState initialState;
  final Completer<FileBrowserState>? initialCompleter;
  final List<String> goCalls = [];

  Completer<FileBrowserState>? _nextGo;
  String _currentPath = _rootPath;
  FileBrowserState? _visible;

  @override
  FileBrowserState? get visibleState =>
      state.isLoading ? _visible : state.value;

  Completer<FileBrowserState> armGo() {
    final completer = Completer<FileBrowserState>();
    _nextGo = completer;
    return completer;
  }

  @override
  String get currentPath => _currentPath;

  @override
  bool get canGoBack => _currentPath != initialState.rootPath;

  @override
  Future<FileBrowserState> build({
    required ConnectionModel connectionModel,
  }) async {
    _currentPath = initialState.path;
    final pending = initialCompleter;
    if (pending != null) return pending.future;
    return initialState;
  }

  @override
  Future<void> go(String value) async {
    goCalls.add(value);
    _currentPath = value;
    _visible = visibleState;
    state = const AsyncLoading<FileBrowserState>();

    final pending = _nextGo ?? Completer<FileBrowserState>();
    _nextGo = null;
    try {
      final next = await pending.future;
      state = AsyncData(next);
    } on Object catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
    }
  }

  @override
  Future<void> goBack() async {
    if (!canGoBack) return;
    _currentPath = initialState.path;
    state = AsyncData(initialState);
  }

  @override
  Future<void> onRemoteFileItemTapped(
    WebdavFile file,
    void Function(int count, int total)? onProgress,
  ) => go(file.path);
}

Widget _app({
  required TargetPlatform platform,
  required _ControlledBrowser browser,
}) {
  return ProviderScope(
    overrides: [
      connectionDetailProvider('test').overrideWith(_Detail.new),
      remoteFileBrowserProvider(
        connectionModel: _connection,
      ).overrideWith(() => browser),
    ],
    child: PlatformProvider(
      initialPlatform: platform,
      builder: (_) => MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(platform: platform),
        home: const Connection('test'),
      ),
    ),
  );
}

Future<void> _pumpConnection(
  WidgetTester tester, {
  required TargetPlatform platform,
  required _ControlledBrowser browser,
  bool settle = true,
}) async {
  await tester.pumpWidget(_app(platform: platform, browser: browser));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    group('$platform remote browser loading', () {
      for (final largeText in [false, true]) {
        testWidgets(
          'connection info is optional and closable largeText=$largeText',
          (tester) async {
            if (largeText) {
              await tester.binding.setSurfaceSize(const Size(320, 640));
              tester.platformDispatcher.textScaleFactorTestValue = 2;
              addTearDown(() {
                tester.binding.setSurfaceSize(null);
                tester.platformDispatcher.clearTextScaleFactorTestValue();
              });
            }
            final browser = _ControlledBrowser(initialState: _parentState());
            await _pumpConnection(tester, platform: platform, browser: browser);
            expect(find.text('支持能力'), findsNothing);
            expect(find.text('使用限制'), findsNothing);
            expect(find.text('WebDAV 能力与限制'), findsNothing);
            expect(find.text(_rootPath), findsOneWidget);
            await tester.tap(find.byKey(const Key('connection-info')));
            await tester.pumpAndSettle();
            expect(find.text('连接说明'), findsOneWidget);
            expect(find.text('这些是连接方式的技术说明，不是当前服务器的检测结果。'), findsOneWidget);
            expect(
              find.textContaining('不支持断点续传：大文件中断后要从头重新上传'),
              findsOneWidget,
            );
            expect(browser.goCalls, isEmpty);
            await tester.ensureVisible(find.text('关闭'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('关闭'));
            await tester.pumpAndSettle();
            expect(find.text('连接说明'), findsNothing);
            expect(find.text(_rootPath), findsOneWidget);
            expect(find.text('child'), findsOneWidget);
            expect(browser.goCalls, isEmpty);
            expect(tester.takeException(), isNull);
          },
        );
      }
      testWidgets(
        'keeps the parent listing mounted while a child directory loads',
        (tester) async {
          final browser = _ControlledBrowser(initialState: _parentState());
          await _pumpConnection(tester, platform: platform, browser: browser);

          final childFinder = find.text('child');
          final pathFinder = find.byKey(_currentPathKey);
          final childElement = tester.element(childFinder);
          final childPosition = tester.getTopLeft(childFinder);
          final pathElement = tester.element(pathFinder);
          final pathPosition = tester.getTopLeft(pathFinder);
          final childCompleter = browser.armGo();

          await tester.tap(childFinder);
          await tester.pump();

          expect(browser.goCalls, [_childPath]);
          expect(find.text(_rootPath), findsOneWidget);
          expect(find.byKey(_loadingKey), findsOneWidget);
          expect(childFinder, findsOneWidget);
          expect(pathFinder, findsOneWidget);
          expect(identical(childElement, tester.element(childFinder)), isTrue);
          expect(tester.getTopLeft(childFinder), childPosition);
          expect(identical(pathElement, tester.element(pathFinder)), isTrue);
          expect(tester.getTopLeft(pathFinder), pathPosition);

          await tester.tap(childFinder, warnIfMissed: false);
          await tester.pump();
          expect(browser.goCalls, [_childPath]);

          childCompleter.complete(_childState());
          await tester.pumpAndSettle();

          expect(find.text(_childPath), findsOneWidget);
          expect(find.text('inside-child'), findsOneWidget);
          expect(find.text('child'), findsNothing);
          expect(find.byKey(_loadingKey), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'replaces the stale listing with an error and still allows back',
        (tester) async {
          final browser = _ControlledBrowser(initialState: _parentState());
          await _pumpConnection(tester, platform: platform, browser: browser);

          final childCompleter = browser.armGo();
          await tester.tap(find.text('child'));
          await tester.pump();
          expect(find.text('child'), findsOneWidget);

          childCompleter.completeError(
            StateError('child directory denied'),
            StackTrace.current,
          );
          await tester.pumpAndSettle();

          expect(find.text('无法加载文件夹'), findsOneWidget);
          expect(find.text('child'), findsNothing);
          expect(find.byKey(_loadingKey), findsNothing);
          expect(find.text('支持能力'), findsNothing);
          expect(find.byKey(_currentPathKey), findsOneWidget);
          expect(find.text('重试'), findsOneWidget);
          expect(find.byType(AppBackButton), findsOneWidget);

          await tester.tap(find.byType(AppBackButton));
          await tester.pumpAndSettle();

          expect(find.text(_rootPath), findsOneWidget);
          expect(find.text('child'), findsOneWidget);
          expect(find.text('无法加载文件夹'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'does not render an empty-directory state during initial loading',
        (tester) async {
          final initialCompleter = Completer<FileBrowserState>();
          final browser = _ControlledBrowser(
            initialState: _parentState(),
            initialCompleter: initialCompleter,
          );
          await _pumpConnection(
            tester,
            platform: platform,
            browser: browser,
            settle: false,
          );

          expect(find.byKey(_loadingKey), findsOneWidget);
          final pathText = tester.widget<Text>(find.byKey(_currentPathKey));
          expect(pathText.data, _rootPath);
          expect(find.text('支持能力'), findsNothing);
          expect(find.byKey(_currentPathKey), findsOneWidget);
          expect(find.text('这个目录还是空的'), findsNothing);
          expect(find.text('child'), findsNothing);

          initialCompleter.complete(_parentState());
          await tester.pumpAndSettle();

          expect(find.byKey(_loadingKey), findsNothing);
          expect(find.text('child'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    });
  }
}
