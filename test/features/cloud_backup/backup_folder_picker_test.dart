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
      await tester.pageBack();
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
    });
  }
}
