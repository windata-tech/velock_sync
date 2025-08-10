import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/theme.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/sync/http.dart';

import 'core/app_router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalDataManager.instance.init();
  runApp(
    ProviderScope(
      retry: (int retryCount, Object error) {
        debugPrint('retryCount=$retryCount');
        if (retryCount >= 2) return null;

        return Duration(seconds: retryCount * 2);
      },
      child: const MyApp(),
    ),
  );
}

class MyApp extends HookConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ignore: riverpod_syntax_error
    final themeMode = ref.watch(vSThemeModeProvider);
    return PlatformProvider(
      settings: PlatformSettingsData(matchMaterialCaseForPlatformText: true),
      builder: (context) => PlatformTheme(
        materialLightTheme: materialLightTheme,
        materialDarkTheme: materialDarkTheme,
        cupertinoLightTheme: cupertinoLightTheme,
        cupertinoDarkTheme: cupertinoDarkTheme,
        themeMode: themeMode,
        builder: (context) => PlatformApp.router(
          localizationsDelegates: <LocalizationsDelegate<dynamic>>[
            DefaultMaterialLocalizations.delegate,
            DefaultWidgetsLocalizations.delegate,
            DefaultCupertinoLocalizations.delegate,
          ],
          title: 'Flutter Platform Widgets',
          onGenerateTitle: (BuildContext context) => 'APP NAME',
          routerConfig: goRouter,
        ),
      ),
    );
  }
}

class MyHomePage extends HookConsumerWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ignore: riverpod_syntax_error
    final as = ref.watch(dioProvider);

    return Scaffold(
      appBar: AppBar(backgroundColor: Theme.of(context).colorScheme.inversePrimary, title: Text(title)),
      body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[Text('hello world!')]),
      ),
    );
  }
}
