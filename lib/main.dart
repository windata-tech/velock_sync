import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:velock_sync/appearance/theme.dart';
import 'package:velock_sync/background/background_sync.dart';
import 'package:velock_sync/background/foreground_sync_coordinator.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
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
  await _provisionNasConnection();
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

/// One-shot provisioning hook used to seed the NAS WebDAV connection through
/// the app's own credential store and state database. It is inert unless a
/// marker file exists at `<Application Support>/velock-sync/nas_setup.json`.
Future<void> _provisionNasConnection() async {
  final directory = await getApplicationSupportDirectory();
  final marker = File(p.join(directory.path, 'velock-sync', 'nas_setup.json'));
  if (!await marker.exists()) return;
  try {
    final json =
        jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
    final credentialRef = await SecureCredentialStore().writeWebDavPassword(
      json['password'] as String,
    );
    final connection = ConnectionModel(
      id: '1785566443318',
      name: '新建连接',
      description: null,
      source: '格间',
      sourceDescription: null,
      target: '${json['address']}:${json['port']}',
      targetDescription: 'runtimeType=WebDavProtocolModel',
      protocol: ProtocolModel.webDav(
        protocolType: WebDavProtocolType.https,
        address: json['address'] as String,
        port: json['port'] as String,
        username: json['username'] as String?,
        credentialRef: credentialRef,
        path: json['path'] as String?,
      ),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      status: ConnectionStatus.active,
    );
    await SyncStateDatabase.instance.replaceConnectionPayloads({
      connection.id: jsonEncode(connection.toJson()),
    });
    await marker.delete();
    debugPrint('NAS connection provisioned.');
  } on Object catch (error) {
    debugPrint('NAS connection provisioning failed: $error');
  }
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
          // The product UI is Chinese-first: system-provided widget strings
          // (license page, action sheets, pickers) must not fall back to English.
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          title: 'Velock Sync',
          onGenerateTitle: (BuildContext context) => 'Velock Sync',
          debugShowCheckedModeBanner: false,
          routerConfig: goRouter,
        ),
      ),
    );
  }
}
