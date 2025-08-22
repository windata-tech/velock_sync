import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/theme.dart';
import 'package:velock_sync/core/local_data_manager.dart';

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
          builder: FToastBuilder(),
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
