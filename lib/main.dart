import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/theme.dart';
import 'package:velock_sync/background/background_sync.dart';
import 'package:velock_sync/background/foreground_sync_coordinator.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/providers/oauth/oauth_callback_link_receiver.dart';

import 'core/app_router.dart';

/// Starts at bootstrap so a custom-scheme OAuth callback is retained even if
/// the system launches the app from the browser.
late final OAuthCallbackLinkReceiver oauthCallbackLinkReceiver;

void main() async {
  // debugDefaultTargetPlatformOverride = TargetPlatform.android;
  WidgetsFlutterBinding.ensureInitialized();
  oauthCallbackLinkReceiver = OAuthCallbackLinkReceiver.system();
  await LocalDataManager.instance.init();
  await SyncStateDatabase.initialize();
  await initializeBackgroundSync();
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

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  late final ForegroundSyncCoordinator _foregroundSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foregroundSync = ForegroundSyncCoordinator(
      runProfiles: runEnabledBackgroundProfiles,
    )..start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_foregroundSync.onAppResumed());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_foregroundSync.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          title: 'Velock Sync',
          onGenerateTitle: (BuildContext context) => 'Velock Sync',
          routerConfig: goRouter,
        ),
      ),
    );
  }
}
