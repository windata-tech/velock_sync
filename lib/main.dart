import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
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
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/features/plain_sync/state/plain_sync_providers.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/providers/oauth/oauth_callback_link_receiver.dart';

import 'core/app_router.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/l10n/sync_language.dart';

/// Starts at bootstrap so a custom-scheme OAuth callback is retained even if
/// the system launches the app from the browser.
late final OAuthCallbackLinkReceiver oauthCallbackLinkReceiver;

void main() async {
  // debugDefaultTargetPlatformOverride = TargetPlatform.android;
  WidgetsFlutterBinding.ensureInitialized();
  oauthCallbackLinkReceiver = OAuthCallbackLinkReceiver.system();
  await LocalDataManager.instance.init();
  await SyncStateDatabase.initialize();
  // A run row is marked `running` before its transfer starts and closed when it
  // ends. Close the rows a killed process left behind, otherwise the location
  // claims to be syncing for ever and refuses edits and deletion. A background
  // isolate of this same process may already be running a sync; the sweep
  // leaves runs whose lock this process still owns alone.
  try {
    await SyncStateDatabase.instance.failInterruptedSyncRuns();
  } on Object catch (error, stackTrace) {
    // Never block startup on reconciliation; a stuck row is reported by the
    // surfaces that read it, and the next launch tries again.
    loge('Interrupted sync run sweep failed: $error', stackTrace: stackTrace);
  }
  await _provisionNasConnection();
  await initializeBackgroundSync();
  runApp(
    ProviderScope(
      overrides: [
        syncLanguageBootstrapProvider.overrideWithValue(
          SyncLanguage.fromStored(
            LocalDataManager.instance.getString(AppKeys.languageCode),
          ),
        ),
      ],
      retry: (int retryCount, Object error) {
        if (kDebugMode) debugPrint('retryCount=$retryCount');
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
  // Debug-only test hook: it injects a WebDAV connection from a plaintext
  // marker file, which must never be possible in a shipped build.
  if (!kDebugMode) return;
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
    if (kDebugMode) debugPrint('NAS connection provisioned.');
  } on Object catch (error) {
    if (kDebugMode) debugPrint('NAS connection provisioning failed: $error');
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
      runProfiles: () async {
        try {
          return await runEnabledBackgroundProfiles();
        } finally {
          // The home cards read the database once per load; without this an
          // automatic run on resume finished unseen until "Refresh status".
          if (mounted) {
            ref.read(profilesRevisionProvider.notifier).bump();
            ref.invalidate(plainLocationViewsProvider);
          }
        }
      },
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
    // One MaterialApp for both platforms: pages already pick their own
    // design-language widgets through `isApplePlatform(context)`, and the
    // Cupertino theme is installed below so Cupertino widgets resolve the same
    // colours they did under a CupertinoApp. This replaces the discontinued
    // flutter_platform_widgets app shell (PlatformProvider/PlatformTheme/
    // PlatformApp).
    return MaterialApp.router(
      builder: (context, child) {
        final themed = CupertinoTheme(
          data: Theme.of(context).brightness == Brightness.dark
              ? cupertinoDarkTheme
              : cupertinoLightTheme,
          child: child ?? const SizedBox.shrink(),
        );
        // Toasts are drawn above the whole app on both platforms.
        return FToastBuilder()(context, themed);
      },
      // Unset preferences keep Chinese; an explicit system choice uses Flutter
      // locale resolution and updates with the device language.
      locale: ref.watch(syncLanguageProvider).locale,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: <LocalizationsDelegate<dynamic>>[
        ...GlobalMaterialLocalizations.delegates,
      ],
      title: 'Velock Sync',
      onGenerateTitle: (BuildContext context) => 'Velock Sync',
      debugShowCheckedModeBanner: false,
      theme: materialLightTheme,
      darkTheme: materialDarkTheme,
      themeMode: themeMode,
      routerConfig: goRouter,
    );
  }
}
