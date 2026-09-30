import 'dart:convert';
import 'package:velock_sync/features/plain_sync/ui/plain_sync_home.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_sync_profile.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_wizard_readiness.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_folder_picker.dart';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';
import 'package:velock_sync/features/connection/ui/new_oauth.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/files_provider.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:velock_sync/features/connection/ui/new_webdav.dart';
import 'package:velock_sync/features/connection/ui/protocols.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/providers/oauth/oauth_client_registration.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';

final _oauthProviders = RemoteProviderType.values
    .where((type) => type != RemoteProviderType.webDav)
    .toList();

/// Titles the protocol list shows in the Chinese UI.
const _zhTileTitle = {
  RemoteProviderType.googleDrive: 'Google Drive',
  RemoteProviderType.oneDrive: 'OneDrive',
  RemoteProviderType.baiduNetdisk: '百度网盘',
  RemoteProviderType.aliyunDrive: '阿里云盘',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncStateDatabase database;
  late ProviderContainer container;
  late List<ProtocolModel> probes;
  late DateTime wizardNow;
  late _RegistrationCredentials credentials;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await LocalDataManager.instance.init();
    database = await SyncStateDatabase.inMemory();
    probes = [];
    credentials = _RegistrationCredentials();
    wizardNow = DateTime.now().toUtc();
    container = ProviderContainer(
      overrides: [
        backupFolderLoaderProvider.overrideWithValue(
          ({required protocol, required relativeSegments}) async => const [],
        ),
        syncStateDatabaseProvider.overrideWithValue(database),
        velockWizardClockProvider.overrideWithValue(() => wizardNow),
        credentialStoreProvider.overrideWithValue(credentials),
        syncSettingsServiceProvider.overrideWithValue(_Settings()),
        protocolConnectionProbeProvider.overrideWithValue(({
          required credentials,
          required protocol,
        }) async {
          probes.add(protocol);
          return true;
        }),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });

  Future<GoRouter> mount(
    WidgetTester tester, {
    String location = '/',
    ProviderContainer? scope,
    TargetPlatform platform = TargetPlatform.iOS,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = createAppRouter(initialLocation: location);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope ?? container,
        child: MaterialApp.router(
          locale: const Locale('zh'),
          supportedLocales: const [Locale('zh'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(platform: platform),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform direct missing detail can return to tabbed home', (
      tester,
    ) async {
      final router = await mount(
        tester,
        location: '/sync-profiles/missing',
        platform: platform,
      );
      expect(find.text('这个连接已不存在。'), findsOneWidget);
      expect(find.byType(AppBackButton), findsOneWidget);
      expect(router.canPop(), isFalse);
      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/dashboard');
      expect(
        find.byType(
          platform == TargetPlatform.iOS ? CupertinoTabBar : NavigationBar,
        ),
        findsOneWidget,
      );
    });

    for (final kind in [
      SyncDatasetKind.velockManaged,
      SyncDatasetKind.selectedFolder,
    ]) {
      testWidgets(
        '$platform standalone $kind detail returns to its product tab',
        (tester) async {
          final velock = VelockSyncProfile(
            profileId: 'nav-profile',
            datasetId: 'dataset',
            vaultId: 'vault',
            deviceId: 'device',
            displayName: 'Navigation backup',
            connectionId: 'cloud',
            pairedProducerId: 'producer',
            pairedProducerPublicKeyId: 'key-ref',
            exchangeBindingId: 'binding',
            backgroundPolicy: const SyncProfileBackgroundPolicy(),
            state: SyncProfileState.active,
            createdAt: DateTime.utc(2026, 9, 26),
          ).toEnvelope();
          final profile = kind == SyncDatasetKind.velockManaged
              ? velock
              : SyncProfileEnvelope(
                  kind: kind,
                  profileId: velock.profileId,
                  datasetId: velock.datasetId,
                  vaultId: velock.vaultId,
                  deviceId: velock.deviceId,
                  displayName: velock.displayName,
                  connectionId: velock.connectionId,
                  state: velock.state,
                  backgroundPolicy: velock.backgroundPolicy,
                  dataset: const {},
                  createdAt: velock.createdAt,
                );
          await container.read(syncProfileRepositoryProvider).save(profile);
          final scope = ProviderContainer(
            parent: container,
            overrides: [
              velockWizardReadinessServiceProvider.overrideWithValue(
                _NavigationReady(),
              ),
            ],
          );
          addTearDown(scope.dispose);
          final router = await mount(
            tester,
            location: '/sync-profiles/nav-profile',
            platform: platform,
            scope: scope,
          );
          expect(find.byType(SyncProfileDetail), findsOneWidget);
          expect(find.byType(AppBackButton), findsOneWidget);
          expect(router.canPop(), isFalse);
          await tester.tap(find.byType(AppBackButton));
          await tester.pumpAndSettle();
          expect(
            router.routeInformationProvider.value.uri.path,
            kind == SyncDatasetKind.velockManaged ? '/dashboard' : '/files',
          );
          expect(
            find.byType(
              platform == TargetPlatform.iOS ? CupertinoTabBar : NavigationBar,
            ),
            findsOneWidget,
          );
        },
      );
    }
  }

  testWidgets('cloud location opens the backup folder, not the connection root', (
    tester,
  ) async {
    final profile = VelockSyncProfile(
      profileId: 'nav-location',
      datasetId: 'dataset',
      vaultId: 'vault',
      deviceId: 'device',
      displayName: 'Navigation backup',
      connectionId: 'cloud',
      pairedProducerId: 'producer',
      pairedProducerPublicKeyId: 'key-ref',
      exchangeBindingId: 'binding',
      remoteRootSegments: const ['USB_HDD_8T', '111'],
      backgroundPolicy: const SyncProfileBackgroundPolicy(),
      state: SyncProfileState.active,
      createdAt: DateTime.utc(2026, 9, 26),
    ).toEnvelope();
    await container.read(syncProfileRepositoryProvider).save(profile);
    final scope = ProviderContainer(
      parent: container,
      overrides: [
        velockWizardReadinessServiceProvider.overrideWithValue(
          _NavigationReady(),
        ),
        connectionDetailProvider('cloud').overrideWith(_FakeConnection.new),
        remoteFileBrowserProvider(
          connectionModel: _cloudConnection,
        ).overrideWith(_FakeBrowser.new),
      ],
    );
    addTearDown(scope.dispose);

    // Start on the tabbed shell and push the detail, exactly like the app does.
    final router = await mount(tester, scope: scope);
    router.push('/sync-profiles/nav-location');
    await tester.pumpAndSettle();
    expect(find.byType(SyncProfileDetail), findsOneWidget);

    // The row names the folder that actually holds this backup.
    expect(
      tester.widget<Text>(find.byKey(const Key('backup-location-path'))).data,
      '/USB_HDD_8T/111',
    );

    final row = find.text('云端保存位置');
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    // ... and hands that folder to the browser instead of the connection root.
    expect(
      router.routerDelegate.currentConfiguration.matches
          .map((match) => match.matchedLocation)
          .last,
      '/connections/connection/cloud',
    );
    expect(find.byType(Connection), findsOneWidget);
    // The browser receives the backup's own folder, not the connection root.
    final browser = tester.widget<Connection>(find.byType(Connection));
    expect(browser.id, 'cloud');
    expect(browser.initialSegments, ['USB_HDD_8T', '111']);
  });

  testWidgets('pushed detail returns without leaving another detail behind', (
    tester,
  ) async {
    final router = await mount(tester);
    router.push('/sync-profiles/missing');
    await tester.pumpAndSettle();
    expect(router.canPop(), isTrue);
    await tester.tap(find.byType(AppBackButton));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/dashboard');
    expect(find.byType(SyncProfileDetail), findsNothing);
    expect(find.byType(CupertinoTabBar), findsOneWidget);
  });

  testWidgets('system back from detached detail reaches tabbed home', (
    tester,
  ) async {
    final router = await mount(
      tester,
      location: '/sync-profiles/missing',
      platform: TargetPlatform.android,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/dashboard');
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      '$platform real shell keeps Velock, files and settings separate',
      (tester) async {
        final router = await mount(tester, platform: platform);
        final nav = find.byType(
          platform == TargetPlatform.iOS ? CupertinoTabBar : NavigationBar,
        );
        final labels = platform == TargetPlatform.iOS
            ? tester
                  .widget<CupertinoTabBar>(nav)
                  .items
                  .map((item) => item.label)
            : tester
                  .widget<NavigationBar>(nav)
                  .destinations
                  .cast<NavigationDestination>()
                  .map((item) => item.label);
        expect(labels, ['格间', '文件同步', '设置']);
        expect(router.routeInformationProvider.value.uri.path, '/dashboard');
        expect(find.text('开始备份'), findsOneWidget);
        await tester.tap(find.descendant(of: nav, matching: find.text('文件同步')));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/files');
        // The files tab now hosts plain folder sync locations.
        expect(find.byType(PlainSyncHome), findsOneWidget);
        expect(find.text('从云端恢复'), findsNothing);
        expect(find.byKey(const Key('plain-location-create')), findsOneWidget);
        await tester.tap(find.descendant(of: nav, matching: find.text('设置')));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/settings');
        expect(find.byType(SyncSettings), findsOneWidget);
        await tester.tap(find.descendant(of: nav, matching: find.text('格间')));
        await tester.pumpAndSettle();
        expect(find.text('开始备份'), findsOneWidget);
        expect(find.byKey(const Key('plain-location-create')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('restore confirmation enters the actual restoring route', (
    tester,
  ) async {
    await mount(tester, location: '/velock/restore');
    final continueButton = find.byKey(const Key('restore-continue'));
    expect(tester.widget<BackupActionButton>(continueButton).onPressed, isNull);
    await tester.ensureVisible(
      find.byKey(const Key('restore-account-confirmed')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('restore-account-confirmed')),
        matching: find.byType(CupertinoSwitch),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(continueButton);
    await tester.pumpAndSettle();
    await tester.tap(continueButton);
    await tester.pumpAndSettle();
    expect(
      GoRouterState.of(
        tester.element(find.byType(VelockDatasetWizard)),
      ).uri.queryParameters['intent'],
      'restore',
    );
    expect(
      tester
          .widget<VelockDatasetWizard>(
            find.byType(VelockDatasetWizard, skipOffstage: false),
          )
          .restoring,
      isTrue,
    );
    expect(probes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'approved restore survives actual WebDAV save and returns to review',
    (tester) async {
      final approved = await _rememberApproval(container);
      try {
        final router = await mount(
          tester,
          location: '/sync-profiles/new/velock?intent=restore',
        );
        await tester.ensureVisible(
          find.byKey(const Key('go-create-connection')),
        );
        await tester.tap(find.byKey(const Key('go-create-connection')));
        await tester.pumpAndSettle();
        const target = '/sync-profiles/new/velock?intent=restore';
        expect(
          tester.widget<Protocols>(find.byType(Protocols)).returnTo,
          target,
        );
        await tester.tap(find.text('WebDAV'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<NewWebDav>(find.byType(NewWebDav)).returnTo,
          target,
        );
        await tester.enterText(
          find.byKey(const ValueKey('webdav_address')),
          'https://example.com',
        );
        await tester.enterText(
          find.byKey(const ValueKey('webdav_port')),
          '443',
        );
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.toString(), target);
        expect(
          tester
              .widget<VelockDatasetWizard>(
                find.byType(VelockDatasetWizard, skipOffstage: false),
              )
              .restoring,
          isTrue,
        );
        expect(
          container.read(velockWizardSessionProvider).approval,
          same(approved),
        );
        await tester.pumpAndSettle();
        expect(find.text('找到原备份文件夹'), findsOneWidget);
        await tester.tap(find.byKey(const Key('use-backup-folder')));
        await tester.pumpAndSettle();
        expect(find.text('确认恢复位置'), findsOneWidget);
        expect(find.text('查找并恢复'), findsOneWidget);
        expect(probes, isNotEmpty);
        expect(
          await container.read(connectionRepositoryProvider).loadConnections(),
          hasLength(1),
        );
        // Connection saving and returning to review must not create a profile or
        // publish anything. Signed approval and destination checks happen later.
        expect(
          await container.read(syncProfileRepositoryProvider).listSummaries(),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        // The authorization deadline is app-scoped; cancel it before the
        // widget test's pending-timer check (tearDown runs after that check).
        container.read(velockWizardSessionProvider.notifier).reset();
      }
    },
  );

  testWidgets('slow cloud setup keeps saved storage and returns to renewal', (
    tester,
  ) async {
    await _rememberApproval(container);
    try {
      final router = await mount(
        tester,
        location: '/sync-profiles/new/velock?intent=restore',
      );
      await tester.ensureVisible(find.byKey(const Key('go-create-connection')));
      await tester.tap(find.byKey(const Key('go-create-connection')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('WebDAV'));
      await tester.pumpAndSettle();
      wizardNow = wizardNow.add(const Duration(minutes: 6));
      await tester.pump(const Duration(minutes: 6));
      await tester.enterText(
        find.byKey(const ValueKey('webdav_address')),
        'https://example.com',
      );
      await tester.enterText(find.byKey(const ValueKey('webdav_port')), '443');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/sync-profiles/new/velock?intent=restore',
      );
      expect(
        tester
            .widget<VelockDatasetWizard>(
              find.byType(VelockDatasetWizard, skipOffstage: false),
            )
            .restoring,
        isTrue,
      );
      expect(
        find.byKey(const Key('renew-velock-authorization')),
        findsOneWidget,
      );
      expect(find.text('确认恢复位置'), findsNothing);
      expect(container.read(velockWizardSessionProvider).approval, isNull);
      expect(
        await container.read(connectionRepositoryProvider).loadConnections(),
        hasLength(1),
      );
      expect(
        await container.read(syncProfileRepositoryProvider).listSummaries(),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    } finally {
      container.read(velockWizardSessionProvider.notifier).reset();
    }
  });

  /// The own-key form is a lazy ListView; the longer Baidu form keeps its
  /// buttons unbuilt until scrolled to.
  Future<void> revealInOwnKeyForm(WidgetTester tester, Key key) async {
    await tester.scrollUntilVisible(
      find.byKey(key),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('oauth-own-key-form')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  /// Opens [provider] from the protocol list. Without a built-in key (as in
  /// tests) every cloud drive sits in the folded "更多云盘" section.
  Future<void> openFromProtocols(
    WidgetTester tester,
    RemoteProviderType provider,
  ) async {
    await tester.tap(find.byKey(const Key('protocols-more-toggle')));
    await tester.pumpAndSettle();
    final tile = find.byKey(Key('protocol-${provider.name}'));
    await tester.ensureVisible(tile);
    expect(
      find.descendant(of: tile, matching: find.text(_zhTileTitle[provider]!)),
      findsOneWidget,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  // Every storage type except WebDAV is an OAuth drive; each must reach
  // the real authorization page, not the router's fallback.
  for (final provider in _oauthProviders) {
    testWidgets('$provider receives the original restore return target', (
      tester,
    ) async {
      const target = '/sync-profiles/new/velock?intent=restore';
      await mount(
        tester,
        location: '/protocols?returnTo=${Uri.encodeQueryComponent(target)}',
      );
      await openFromProtocols(tester, provider);
      final page = tester.widget<NewOAuthConnection>(
        find.byType(NewOAuthConnection),
      );
      expect(page.providerType, provider);
      expect(page.returnTo, target);
      expect(
        probes,
        isEmpty,
      ); // No real authorization or cloud access in this test.
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$provider without a key offers the own-key form, not build settings',
      (tester) async {
        const target = '/sync-profiles/new/velock?intent=restore';
        final router = await mount(
          tester,
          location:
              '/protocol/oauth/${provider.name}?returnTo=${Uri.encodeQueryComponent(target)}',
        );
        expect(find.byKey(const Key('oauth-own-key-form')), findsOneWidget);
        expect(find.byKey(const Key('oauth-sign-in')), findsNothing);
        expect(find.textContaining('此版本暂未开通'), findsNothing);
        // Build-time defines are a maintainer concern, never user-facing.
        expect(find.textContaining('dart-define'), findsNothing);
        expect(find.textContaining('BAIDU_NETDISK'), findsNothing);
        expect(find.textContaining('Refresh Token'), findsNothing);
        expect(
          find.byKey(const Key('oauth-own-secret')),
          OAuthClientRegistration.acceptsSecret(provider)
              ? findsOneWidget
              : findsNothing,
        );
        await revealInOwnKeyForm(tester, const Key('oauth-choose-another'));
        await tester.tap(find.byKey(const Key('oauth-choose-another')));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/protocols');
        expect(
          tester.widget<Protocols>(find.byType(Protocols)).returnTo,
          target,
        );
        expect(credentials.registrations, isEmpty);
        expect(probes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$provider choose-another keeps the protocol list able to go back',
      (tester) async {
        const target = '/sync-profiles/new/velock?intent=restore';
        final router = await mount(tester);
        router.push('/protocols?returnTo=${Uri.encodeQueryComponent(target)}');
        await tester.pumpAndSettle();
        await openFromProtocols(tester, provider);
        await revealInOwnKeyForm(tester, const Key('oauth-choose-another'));
        await tester.tap(find.byKey(const Key('oauth-choose-another')));
        await tester.pumpAndSettle();

        expect(find.byType(NewOAuthConnection), findsNothing);
        expect(find.byType(Protocols), findsOneWidget);
        expect(
          tester.widget<Protocols>(find.byType(Protocols)).returnTo,
          target,
        );
        await tester.tap(find.bySemanticsLabel('返回'));
        await tester.pumpAndSettle();
        expect(find.byType(Protocols), findsNothing);
        expect(router.routeInformationProvider.value.uri.path, '/dashboard');
        expect(probes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('$provider own app key waits for an explicit save', (
      tester,
    ) async {
      await mount(tester, location: '/protocol/oauth/${provider.name}');
      final input = find.byKey(const Key('oauth-own-client-id'));
      await tester.ensureVisible(input);
      await tester.enterText(input, 't');
      await tester.pumpAndSettle();
      // Typing alone must neither persist anything nor swap the form away.
      expect(input, findsOneWidget);
      expect(find.byKey(const Key('oauth-sign-in')), findsNothing);
      expect(credentials.registrations, isEmpty);
      const publicId = 'test-public-client.apps.example';
      await tester.enterText(input, publicId);
      if (OAuthClientRegistration.requiresSecret(provider)) {
        await tester.enterText(
          find.byKey(const Key('oauth-own-secret')),
          'test-secret',
        );
      }
      if (OAuthClientRegistration.acceptsAppFolderName(provider)) {
        await tester.enterText(
          find.byKey(const Key('oauth-own-app-folder')),
          'Test Sync',
        );
      }
      await revealInOwnKeyForm(tester, const Key('oauth-own-save'));
      await tester.tap(find.byKey(const Key('oauth-own-save')));
      await tester.pumpAndSettle();
      expect(credentials.registrations[provider]?.clientId, publicId);
      expect(find.byKey(const Key('oauth-sign-in')), findsOneWidget);
      expect(find.text('登录并选择保存位置'), findsOneWidget);
      expect(find.byKey(const Key('oauth-root-id')), findsNothing);
      expect(find.textContaining('Refresh Token'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const Key('oauth-advanced-location')),
      );
      await tester.tap(find.text('更多设置（可选）'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('oauth-root-id')), findsOneWidget);
      expect(find.byKey(const Key('oauth-own-key-summary')), findsOneWidget);
      expect(probes, isEmpty); // No cloud sign-in is executed by a UI test.
      expect(tester.takeException(), isNull);
    });
  }

  for (final target in [
    'https://untrusted.example/receive',
    '//untrusted.example/receive',
    '/sync-profiles/new/velock?intent=restore&unexpected=1',
    '/connections/connection/delete-me',
  ]) {
    testWidgets('return target is restricted to known setup flows: $target', (
      tester,
    ) async {
      final router = await mount(
        tester,
        location: '/protocols?returnTo=${Uri.encodeQueryComponent(target)}',
      );
      expect(tester.widget<Protocols>(find.byType(Protocols)).returnTo, isNull);
      await tester.tap(find.text('WebDAV'));
      await tester.pumpAndSettle();
      expect(tester.widget<NewWebDav>(find.byType(NewWebDav)).returnTo, isNull);
      router.go(
        '/protocol/oauth/googleDrive?returnTo=${Uri.encodeQueryComponent(target)}',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<NewOAuthConnection>(find.byType(NewOAuthConnection))
            .returnTo,
        isNull,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

/// No credentials are required for this isolated test service. Any accidental
/// platform credential access fails instead of falling back to real storage.
/// Only the user's own OAuth app registrations may be touched; any other
/// credential access in these navigation tests is a bug.
class _RegistrationCredentials implements CredentialStore {
  final registrations = <RemoteProviderType, OAuthClientRegistration>{};

  @override
  Future<void> writeOAuthClientRegistration(
    RemoteProviderType type,
    OAuthClientRegistration registration,
  ) async => registrations[type] = registration;

  @override
  Future<OAuthClientRegistration?> readOAuthClientRegistration(
    RemoteProviderType type,
  ) async => registrations[type];

  @override
  Future<void> deleteOAuthClientRegistration(RemoteProviderType type) async =>
      registrations.remove(type);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings implements SyncSettingsService {
  @override
  Future<SyncSettingsSnapshot> load() async => const SyncSettingsSnapshot(
    settings: SyncGlobalSettings(),
    backgroundSupported: false,
    backgroundEligibleProfileCount: 0,
    staging: StagingSpaceSummary(),
    garbageCollection: null,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<VelockPairingControlResponse> _rememberApproval(
  ProviderContainer container,
) async {
  final now = container.read(velockWizardClockProvider)().toUtc();
  final key = await Ed25519().newKeyPairFromSeed(List.filled(32, 8));
  final descriptor = VelockPairingDescriptor(
    producerId: 'source',
    producerPublicKeyId: 'key',
    producerSigningPublicKey: base64UrlEncode(
      (await key.extractPublicKey()).bytes,
    ),
    exchangeBindingId: 'binding',
    publishedAt: now,
  );
  final request = VelockPairingControlRequest(
    requestId: 'request',
    challenge: 'challenge',
    producerId: descriptor.producerId,
    producerPublicKeyId: descriptor.producerPublicKeyId,
    exchangeBindingId: descriptor.exchangeBindingId,
    syncAppInstanceId: 'sync-test',
    createdAt: now,
    expiresAt: now.add(const Duration(minutes: 5)),
  );
  final unsigned = {
    'approvedAt': now.toIso8601String(),
    'challenge': request.challenge,
    'deviceDisplayName': 'Test device',
    'exchangeBindingId': request.exchangeBindingId,
    'expiresAt': request.expiresAt.toIso8601String(),
    'producerId': request.producerId,
    'producerPublicKeyId': request.producerPublicKeyId,
    'producerSigningPublicKey': descriptor.producerSigningPublicKey,
    'requestId': request.requestId,
    'vaultDisplayName': '我的格间',
    'vaultId': 'vault',
  };
  final signature = await Ed25519().sign(
    utf8.encode(jsonEncode(unsigned)),
    keyPair: key,
  );
  final approval = VelockPairingControlResponse.parse(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          ...unsigned,
          'signature': base64UrlEncode(signature.bytes),
        }),
      ),
    ),
  );
  final session = VelockPairingSession(
    descriptor: descriptor,
    request: request,
  );
  final controller = container.read(velockWizardSessionProvider.notifier);
  controller.sessionStarted(session);
  controller.approved(approval);
  return approval;
}

class _NavigationReady implements VelockWizardReadinessService {
  @override
  Future<VelockWizardReadiness> inspect({String? syncAppInstanceId}) async =>
      const VelockWizardReadiness(VelockWizardAvailability.ready);
}

final _cloudConnection = ConnectionModel(
  id: 'cloud',
  name: 'Cloud',
  source: 'cloud',
  target: 'cloud',
  protocol: const WebDavProtocolModel(
    protocolType: WebDavProtocolType.https,
    address: 'https://example.invalid',
    port: '443',
    path: '/',
  ),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  status: ConnectionStatus.active,
);

class _FakeConnection extends ConnectionDetail {
  @override
  Future<ConnectionModel?> build(String id) async => _cloudConnection;
}

class _FakeBrowser extends RemoteFileBrowser {
  @override
  Future<FileBrowserState> build({
    required ConnectionModel connectionModel,
  }) async => const FileBrowserState(path: '/', rootPath: '/', files: []);
  @override
  Future<void> go(String value) async {}
}
