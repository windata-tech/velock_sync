import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/cloud_backup/application/webdav_backup_folder_browser.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/providers/provider_request_exception.dart';

void main() {
  Future<void> pumpPicker(
    WidgetTester tester, {
    required Future<List<WebDavBackupFolder>> Function(List<String>) load,
    void Function(List<String>?)? onSelected,
    Locale locale = const Locale('zh'),
    double textScale = 1,
    Future<void> Function(List<String>, String)? create,
    bool restoring = false,
  }) async {
    await tester.pumpWidget(
      PlatformProvider(
        initialPlatform: TargetPlatform.iOS,
        builder: (_) => MaterialApp(
          locale: locale,
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(platform: TargetPlatform.iOS),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final result = await Navigator.of(context).push<List<String>>(
                    MaterialPageRoute(
                      builder: (_) => BackupFolderPicker(
                        connectionName: '我的 NAS',
                        basePath: '/dav',
                        loadFolders: load,
                        createFolder: create,
                        restoring: restoring,
                      ),
                    ),
                  );
                  onSelected?.call(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('header and system back go up before leaving folder picker', (
    tester,
  ) async {
    var closed = false;
    await pumpPicker(
      tester,
      load: (path) async => path.length < 2
          ? [WebDavBackupFolder(name: path.isEmpty ? 'one' : 'two')]
          : [],
      onSelected: (_) => closed = true,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-folder-one')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-folder-two')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-folder-back')));
    await tester.pumpAndSettle();
    expect(find.text('/dav/one'), findsOneWidget);
    expect(closed, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('/dav'), findsOneWidget);
    expect(closed, isFalse);
    await tester.tap(find.byKey(const Key('backup-folder-back')));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  testWidgets(
    'back can escape failed or loading child without exiting picker',
    (tester) async {
      final pending = Completer<List<WebDavBackupFolder>>();
      await pumpPicker(
        tester,
        load: (path) async {
          if (path.isEmpty) return const [WebDavBackupFolder(name: 'slow')];
          return pending.future;
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup-folder-slow')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('backup-folder-back')));
      await tester.pumpAndSettle();
      expect(find.text('/dav'), findsOneWidget);
      pending.completeError(StateError('denied'));
      await tester.pumpAndSettle();
      expect(find.text('/dav'), findsOneWidget);
      expect(find.byKey(const Key('backup-folder-error')), findsNothing);
    },
  );

  testWidgets(
    'browses children, goes up, returns only explicitly selected folder',
    (tester) async {
      final calls = <List<String>>[];
      List<String>? selected;
      await pumpPicker(
        tester,
        load: (path) async {
          calls.add([...path]);
          return path.isEmpty
              ? const [WebDavBackupFolder(name: '共享 文件夹')]
              : path.length == 1
              ? const [WebDavBackupFolder(name: '备份 100%')]
              : const [];
        },
        onSelected: (path) => selected = path,
      );
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(find.byKey(const ValueKey('backup-folder-共享 文件夹')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup-folder-备份 100%')));
      await tester.pumpAndSettle();
      expect(find.text('/dav/共享 文件夹/备份 100%'), findsOneWidget);
      await tester.tap(find.byKey(const Key('backup-folder-up')));
      await tester.pumpAndSettle();
      expect(find.text('/dav/共享 文件夹'), findsOneWidget);
      expect(selected, isNull);
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();
      expect(selected, ['共享 文件夹']);
      expect(calls, [
        [],
        ['共享 文件夹'],
        ['共享 文件夹', '备份 100%'],
        ['共享 文件夹'],
      ]);
    },
  );

  testWidgets(
    'loading cannot select and a late result after back is harmless',
    (tester) async {
      final pending = Completer<List<WebDavBackupFolder>>();
      var returned = false;
      List<String>? selected;
      await pumpPicker(
        tester,
        load: (_) => pending.future,
        onSelected: (path) {
          returned = true;
          selected = path;
        },
      );
      expect(
        tester
            .widget<BackupActionButton>(
              find.byKey(const Key('use-backup-folder')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('backup-folder-back')));
      await tester.pumpAndSettle();
      pending.complete(const []);
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(selected, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed folder cannot be selected; retry explicitly reloads', (
    tester,
  ) async {
    var calls = 0;
    await pumpPicker(
      tester,
      load: (_) async {
        if (++calls == 1) throw StateError('not for display');
        return const [];
      },
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backup-folder-error')), findsOneWidget);
    expect(find.textContaining('not for display'), findsNothing);
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('use-backup-folder')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('backup-folder-retry')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(
      tester
          .widget<BackupActionButton>(
            find.byKey(const Key('use-backup-folder')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'authentication failure is not retried or treated as an empty folder',
    (tester) async {
      var calls = 0;
      await pumpPicker(
        tester,
        load: (_) async {
          calls++;
          throw ProviderRequestException.fromStatus(401);
        },
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byKey(const Key('backup-folder-retry')), findsNothing);
      expect(
        tester
            .widget<BackupActionButton>(
              find.byKey(const Key('use-backup-folder')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'explicit creation opens the new folder but does not select it or start backup',
    (tester) async {
      final created = <List<String>>[];
      List<String>? selected;
      await pumpPicker(
        tester,
        load: (path) async =>
            path.isEmpty ? const [WebDavBackupFolder(name: '硬盘')] : const [],
        create: (parent, name) async => created.add([...parent, name]),
        onSelected: (path) => selected = path,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('backup-folder-硬盘')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-backup-folder')));
      await tester.pumpAndSettle();
      expect(find.text('创建位置：/dav/硬盘'), findsOneWidget);
      expect(created, isEmpty);
      await tester.enterText(
        find.byKey(const Key('new-backup-folder-name')),
        ' 格间备份 100% ',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-new-backup-folder')));
      await tester.pumpAndSettle();
      expect(created, [
        ['硬盘', '格间备份 100%'],
      ]);
      expect(find.text('/dav/硬盘/格间备份 100%'), findsOneWidget);
      expect(find.byKey(const Key('backup-folder-created')), findsOneWidget);
      expect(selected, isNull);
      await tester.tap(find.byKey(const Key('use-backup-folder')));
      await tester.pumpAndSettle();
      expect(selected, ['硬盘', '格间备份 100%']);
    },
  );

  testWidgets('cancel and invalid or duplicate names never create a folder', (
    tester,
  ) async {
    var calls = 0;
    await pumpPicker(
      tester,
      load: (_) async => const [WebDavBackupFolder(name: '已有文件夹')],
      create: (_, _) async {
        calls++;
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-backup-folder')));
    await tester.pumpAndSettle();
    for (final name in ['', '../不应创建', '.', '已有文件夹']) {
      await tester.enterText(
        find.byKey(const Key('new-backup-folder-name')),
        name,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-new-backup-folder')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-backup-folder-name')), findsOneWidget);
      expect(calls, 0);
    }
    await tester.tap(find.byKey(const Key('cancel-new-backup-folder')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('/dav'), findsOneWidget);
  });

  testWidgets(
    'creation in flight cannot duplicate, navigate or select the old folder',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      await pumpPicker(
        tester,
        load: (_) async => const [],
        create: (_, _) {
          calls++;
          return pending.future;
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-backup-folder')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('new-backup-folder-name')),
        '新目录',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('confirm-new-backup-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-backup-folder')));
      await tester.pump();
      expect(calls, 1);
      expect(
        tester
            .widget<BackupActionButton>(
              find.byKey(const Key('use-backup-folder')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<PopScope>(
              find.byWidgetPredicate((widget) => widget is PopScope).first,
            )
            .canPop,
        isFalse,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('/dav/新目录'), findsOneWidget);
    },
  );

  for (final error in [
    ProviderRequestException.fromStatus(405),
    const WebDavBackupFolderException('provider.webdav.create_outcome_unknown'),
  ]) {
    testWidgets(
      'failed/unconfirmed creation does not open or select an existing folder: $error',
      (tester) async {
        var calls = 0;
        var loads = 0;
        List<String>? selected;
        await pumpPicker(
          tester,
          load: (_) async {
            loads++;
            return const [];
          },
          create: (_, _) async {
            calls++;
            throw error;
          },
          onSelected: (path) => selected = path,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('new-backup-folder')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('new-backup-folder-name')),
          '新目录',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('confirm-new-backup-folder')));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(loads, 1);
        expect(find.text('/dav'), findsOneWidget);
        expect(find.byKey(const Key('backup-folder-created')), findsNothing);
        expect(
          find.byKey(const Key('backup-folder-create-error')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<BackupActionButton>(
                find.byKey(const Key('use-backup-folder')),
              )
              .onPressed,
          isNull,
        );
        expect(selected, isNull);
        await tester.tap(find.byKey(const Key('refresh-after-folder-create')));
        await tester.pumpAndSettle();
        expect(loads, 2);
        expect(calls, 1);
      },
    );
  }

  testWidgets(
    'restore mode remains read-only even when creation callback is provided',
    (tester) async {
      await pumpPicker(
        tester,
        restoring: true,
        load: (_) async => const [],
        create: (_, _) async => fail('Must not create during restore'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-backup-folder')), findsNothing);
    },
  );

  for (final locale in const [Locale('zh'), Locale('en')]) {
    testWidgets('folder picker fits 320px and 2x text in $locale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpPicker(
        tester,
        locale: locale,
        textScale: 2,
        create: (_, _) async {},
        load: (_) async => const [
          WebDavBackupFolder(name: '长文件夹名称 folder with spaces 100%'),
        ],
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('use-backup-folder')).hitTestable(),
        findsOneWidget,
      );
      final newFolder = find.byKey(const Key('new-backup-folder'));
      await tester.scrollUntilVisible(
        newFolder,
        120,
        scrollable: find.descendant(
          of: find.byKey(const Key('backup-folder-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(newFolder);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('new-backup-folder-name')),
        '新的格间备份',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('cancel-new-backup-folder')));
      await tester.pumpAndSettle();
    });
  }
}
