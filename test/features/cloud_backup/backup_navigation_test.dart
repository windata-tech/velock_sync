import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/local_data_manager.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';
import 'package:velock_sync/features/connection/ui/new_oauth.dart';
import 'package:velock_sync/features/connection/ui/new_webdav.dart';
import 'package:velock_sync/features/connection/ui/protocols.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/infrastructure/database/sync_state_database.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/infrastructure/staging/staging_space_manager.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/sync_profiles/model/sync_dataset_kind.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/sync_profiles/settings/sync_settings_service.dart';
import 'package:velock_sync/sync_profiles/wizard/velock_pairing_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncStateDatabase database;
  late ProviderContainer container;
  late List<ProtocolModel> probes;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await LocalDataManager.instance.init();
    database = await SyncStateDatabase.inMemory();
    probes = [];
    container = ProviderContainer(
      overrides: [
        syncStateDatabaseProvider.overrideWithValue(database),
        credentialStoreProvider.overrideWithValue(_UnusedCredentials()),
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
        container: container,
        child: PlatformProvider(
          initialPlatform: platform,
          builder: (_) => MaterialApp.router(
            locale: const Locale('zh'),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: ThemeData(platform: platform),
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

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
        expect(
          tester.widget<SyncProfilesHome>(find.byType(SyncProfilesHome)).kind,
          SyncDatasetKind.selectedFolder,
        );
        expect(find.text('从云端恢复'), findsNothing);
        expect(find.byKey(const Key('selected-folder-create')), findsOneWidget);
        await tester.tap(find.descendant(of: nav, matching: find.text('设置')));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/settings');
        expect(find.byType(SyncSettings), findsOneWidget);
        await tester.tap(find.descendant(of: nav, matching: find.text('格间')));
        await tester.pumpAndSettle();
        expect(find.text('开始备份'), findsOneWidget);
        expect(find.byKey(const Key('selected-folder-create')), findsNothing);
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
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('restore-account-confirmed')),
        matching: find.byType(CupertinoSwitch),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(continueButton);
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
          .widget<VelockDatasetWizard>(find.byType(VelockDatasetWizard))
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
      final router = await mount(
        tester,
        location: '/sync-profiles/new/velock?intent=restore',
      );
      await tester.ensureVisible(find.byKey(const Key('go-create-connection')));
      await tester.tap(find.byKey(const Key('go-create-connection')));
      await tester.pumpAndSettle();
      const target = '/sync-profiles/new/velock?intent=restore';
      expect(tester.widget<Protocols>(find.byType(Protocols)).returnTo, target);
      await tester.tap(find.text('WebDAV'));
      await tester.pumpAndSettle();
      expect(tester.widget<NewWebDav>(find.byType(NewWebDav)).returnTo, target);
      await tester.enterText(
        find.byKey(const ValueKey('webdav_address')),
        'https://example.com',
      );
      await tester.enterText(find.byKey(const ValueKey('webdav_port')), '443');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.toString(), target);
      expect(
        tester
            .widget<VelockDatasetWizard>(find.byType(VelockDatasetWizard))
            .restoring,
        isTrue,
      );
      expect(
        container.read(velockWizardSessionProvider).approval,
        same(approved),
      );
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
    },
  );

  for (final provider in [
    RemoteProviderType.googleDrive,
    RemoteProviderType.oneDrive,
  ]) {
    testWidgets('$provider receives the original restore return target', (
      tester,
    ) async {
      const target = '/sync-profiles/new/velock?intent=restore';
      await mount(
        tester,
        location: '/protocols?returnTo=${Uri.encodeQueryComponent(target)}',
      );
      await tester.tap(
        find.text(
          provider == RemoteProviderType.googleDrive
              ? 'Google Drive'
              : 'OneDrive',
        ),
      );
      await tester.pumpAndSettle();
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
  }

  for (final provider in [
    RemoteProviderType.googleDrive,
    RemoteProviderType.oneDrive,
  ]) {
    testWidgets(
      '$provider setup problems do not expose developer fields by default',
      (tester) async {
        const target = '/sync-profiles/new/velock?intent=restore';
        final router = await mount(
          tester,
          location:
              '/protocol/oauth/${provider.name}?returnTo=${Uri.encodeQueryComponent(target)}',
        );
        expect(find.textContaining('此版本暂未开通'), findsOneWidget);
        expect(find.byKey(const Key('oauth-choose-another')), findsOneWidget);
        expect(find.byKey(const Key('oauth-client-id-field')), findsNothing);
        expect(find.textContaining('Client ID'), findsNothing);
        expect(find.textContaining('Refresh Token'), findsNothing);
        await tester.tap(find.byKey(const Key('oauth-choose-another')));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/protocols');
        expect(
          tester.widget<Protocols>(find.byType(Protocols)).returnTo,
          target,
        );
        expect(probes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('$provider optional developer form waits for explicit save', (
      tester,
    ) async {
      await mount(tester, location: '/protocol/oauth/${provider.name}');
      await tester.ensureVisible(
        find.byKey(const Key('oauth-developer-settings')),
      );
      await tester.tap(find.text('开发者配置'));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('oauth-client-id-field'));
      await tester.ensureVisible(input);
      await tester.enterText(input, 't');
      await tester.pumpAndSettle();
      // The old implementation replaced this form after the very first
      // keystroke, before the user could finish or persist the configuration.
      expect(input, findsOneWidget);
      expect(find.byKey(const Key('oauth-sign-in')), findsNothing);
      const publicId = 'test-public-client.apps.example';
      await tester.enterText(input, publicId);
      await tester.ensureVisible(find.byKey(const Key('oauth-save-client-id')));
      await tester.tap(find.byKey(const Key('oauth-save-client-id')));
      await tester.pumpAndSettle();
      expect(
        await LocalDataManager.instance.getStringAsync(
          provider == RemoteProviderType.googleDrive
              ? AppKeys.googleOAuthClientId
              : AppKeys.oneDriveOAuthClientId,
        ),
        publicId,
      );
      expect(find.byKey(const Key('oauth-sign-in')), findsOneWidget);
      expect(find.text('登录并选择保存位置'), findsOneWidget);
      expect(find.byKey(const Key('oauth-root-id')), findsNothing);
      expect(find.textContaining('Refresh Token'), findsNothing);
      expect(find.textContaining('Client ID'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const Key('oauth-advanced-location')),
      );
      await tester.tap(find.text('更多设置（可选）'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('oauth-root-id')), findsOneWidget);
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
class _UnusedCredentials implements CredentialStore {
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
  final now = DateTime.now().toUtc();
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
