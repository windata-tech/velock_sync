import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/features/cloud_backup/ui/velock_recovery_guide.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/wd_routes.dart';
import 'package:velock_sync/widgets/velock_brand_mark.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:velock_sync/features/connection/ui/connections.dart';
import 'package:velock_sync/features/connection/ui/connection_guidance.dart';
import 'package:velock_sync/features/connection/ui/new_connection.dart';
import 'package:velock_sync/features/connection/ui/new_baidu_token.dart';
import 'package:velock_sync/features/connection/ui/new_oauth.dart';
import 'package:velock_sync/features/connection/ui/new_webdav.dart';
import 'package:velock_sync/features/connection/ui/protocols.dart';
import 'package:velock_sync/features/activity/ui/sync_activity.dart';
import 'package:velock_sync/features/selected_folder/ui/selected_folder_profiles.dart';
import 'package:velock_sync/features/plain_sync/ui/add_plain_location.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_location_detail.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_sync_home.dart';
import 'package:velock_sync/features/sync_profiles/ui/new_sync_profile.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_workspace.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final RouteObserver<PageRoute> routeObserver = RouteObserver<PageRoute>();
GoRouterRedirect? redirect = (context, state) {
  if (state.matchedLocation == AppRoutes.home.path) {
    // Redirect to the dashboard if the user is on the home route
    return AppRoutes.dashboard.path;
  }
  return null;
};

class AppRouteInfo {
  final String name;
  final String path;

  const AppRouteInfo(this.name, this.path);
}

class AppRoutes {
  static const ({String name, String path}) home = (name: 'home', path: '/');

  static const ({String name, String path}) dashboard = (
    name: 'dashboard',
    path: '/dashboard',
  );
  static const ({String name, String path}) files = (
    name: 'files',
    path: '/files',
  );
  static const ({String name, String path}) velockRecovery = (
    name: 'velockRecovery',
    path: '/velock/restore',
  );
  static const ({String name, String path}) connections = (
    name: 'connections',
    path: '/connections',
  );
  static const ({String name, String path}) settings = (
    name: 'settings',
    path: '/settings',
  );
  static const ({String name, String path}) activity = (
    name: 'activity',
    path: '/activity',
  );
  static const ({String name, String path}) syncProfilesNew = (
    name: 'syncProfilesNew',
    path: '/sync-profiles/new',
  );
  static const ({String name, String path}) velockDatasetWizard = (
    name: 'velockDatasetWizard',
    path: '/sync-profiles/new/velock',
  );
  static const ({String name, String path}) selectedFolderProfiles = (
    name: 'selectedFolderProfiles',
    path: '/sync-profiles/new/selected-folder',
  );
  static const ({String name, String path}) syncProfileDetail = (
    name: 'syncProfileDetail',
    path: '/sync-profiles/:profileId',
  );

  /// Plain (unencrypted) folder sync locations.
  static const ({String name, String path}) addPlainLocation = (
    name: 'addPlainLocation',
    path: '/plain-locations/new',
  );

  static const ({String name, String path}) plainLocationDetail = (
    name: 'plainLocationDetail',
    path: '/plain-locations/:profileId',
  );

  static const ({String name, String path}) about = (
    name: 'about',
    path: '/about',
  );

  static const ({String name, String path}) newConnection = (
    name: 'newConnection',
    path: '/connection/new',
  );
  static const ({String name, String path}) protocols = (
    name: 'protocols',
    path: '/protocols',
  );
  static const ({String name, String path}) connectionHelp = (
    name: 'connectionHelp',
    path: '/protocols/help',
  );
  static const ({String name, String path}) newWebDav = (
    name: 'newWebDav',
    path: '/protocol/webdav/new',
  );
  static const ({String name, String path}) newOAuth = (
    name: 'newOAuth',
    path: '/protocol/oauth/:provider',
  );
  static const ({String name, String path}) newBaiduToken = (
    name: 'newBaiduToken',
    path: '/protocol/baidu-netdisk/token',
  );
  static const ({String name, String path}) connection = (
    name: 'connectionDetail',
    path: '/connections/connection/:id',
  );
}

final goRouter = createAppRouter(
  navigatorKey: rootNavigatorKey,
  observers: [routeObserver],
);

/// Build the real route tree with an independent lifecycle for navigation tests.
/// Production keeps using [goRouter] and its app-wide navigation observer.
GoRouter createAppRouter({
  String initialLocation = '/',
  GlobalKey<NavigatorState>? navigatorKey,
  List<NavigatorObserver> observers = const [],
}) => GoRouter(
  navigatorKey: navigatorKey,
  debugLogDiagnostics: true,
  initialLocation: initialLocation,
  observers: observers,
  redirect: redirect,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return WDShellPage(navigationShell: navigationShell);
      },
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          routes: <RouteBase>[
            WdRoute(
              name: AppRoutes.dashboard.name,
              path: AppRoutes.dashboard.path,
              builder: (BuildContext context, GoRouterState state) =>
                  const SyncProfilesHome(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            WdRoute(
              name: AppRoutes.files.name,
              path: AppRoutes.files.path,
              builder: (context, state) => const PlainSyncHome(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            WdRoute(
              name: AppRoutes.settings.name,
              path: AppRoutes.settings.path,
              builder: (BuildContext context, GoRouterState state) =>
                  const SyncSettings(),
            ),
          ],
        ),
      ],
    ),
    WdRoute(
      name: AppRoutes.connections.name,
      path: AppRoutes.connections.path,
      builder: (context, state) => Connections(),
    ),
    WdRoute(
      name: AppRoutes.activity.name,
      path: AppRoutes.activity.path,
      builder: (context, state) => const SyncActivity(),
    ),
    WdRoute(
      name: AppRoutes.velockRecovery.name,
      path: AppRoutes.velockRecovery.path,
      builder: (context, state) => const VelockRecoveryGuide(),
    ),
    WdRoute(
      name: AppRoutes.syncProfilesNew.name,
      path: AppRoutes.syncProfilesNew.path,
      builder: (context, state) => const NewSyncProfile(),
    ),
    WdRoute(
      name: AppRoutes.velockDatasetWizard.name,
      path: AppRoutes.velockDatasetWizard.path,
      builder: (context, state) => VelockDatasetWizard(
        restoring: state.uri.queryParameters['intent'] == 'restore',
      ),
    ),
    WdRoute(
      name: AppRoutes.selectedFolderProfiles.name,
      path: AppRoutes.selectedFolderProfiles.path,
      builder: (context, state) => const SelectedFolderProfiles(),
    ),
    WdRoute(
      name: AppRoutes.addPlainLocation.name,
      path: AppRoutes.addPlainLocation.path,
      builder: (context, state) => const AddPlainLocation(),
    ),
    WdRoute(
      name: AppRoutes.plainLocationDetail.name,
      path: AppRoutes.plainLocationDetail.path,
      builder: (context, state) {
        final profileId = state.pathParameters['profileId'];
        if (profileId == null || profileId.isEmpty) {
          return Scaffold(
            body: Center(
              child: Text(
                syncText(context, '找不到该同步位置。', 'Sync location not found.'),
              ),
            ),
          );
        }
        return PlainLocationDetail(profileId: profileId);
      },
    ),
    WdRoute(
      name: AppRoutes.syncProfileDetail.name,
      path: AppRoutes.syncProfileDetail.path,
      builder: (context, state) {
        final profileId = state.pathParameters['profileId'];
        if (profileId == null || profileId.isEmpty) {
          return Scaffold(
            body: Center(
              child: Text(
                syncText(context, '找不到该同步配置。', "Sync profile not found."),
              ),
            ),
          );
        }
        return SyncProfileDetail(profileId: profileId);
      },
    ),
    WdRoute(
      name: AppRoutes.about.name,
      path: AppRoutes.about.path,
      builder: (context, state) => Container(),
    ),
    WdRoute(
      name: AppRoutes.newConnection.name,
      path: AppRoutes.newConnection.path,
      builder: (context, state) => NewConnection(),
    ),
    WdRoute(
      name: AppRoutes.protocols.name,
      path: AppRoutes.protocols.path,
      builder: (context, state) => Protocols(returnTo: _setupReturnTo(state)),
    ),
    WdRoute(
      name: AppRoutes.connectionHelp.name,
      path: AppRoutes.connectionHelp.path,
      builder: (context, state) {
        final providerName = state.uri.queryParameters['provider'];
        final provider = switch (providerName) {
          'webDav' => RemoteProviderType.webDav,
          'googleDrive' => RemoteProviderType.googleDrive,
          'oneDrive' => RemoteProviderType.oneDrive,
          'baiduNetdisk' => RemoteProviderType.baiduNetdisk,
          'aliyunDrive' => RemoteProviderType.aliyunDrive,
          _ => null,
        };
        return ConnectionHelpPage(providerType: provider);
      },
    ),
    WdRoute(
      name: AppRoutes.newWebDav.name,
      path: AppRoutes.newWebDav.path,
      builder: (context, state) => NewWebDav(
        replacementConnectionId: state.uri.queryParameters['replace'],
        returnTo: _setupReturnTo(state),
      ),
    ),
    WdRoute(
      name: AppRoutes.newOAuth.name,
      path: AppRoutes.newOAuth.path,
      builder: (context, state) {
        final providerName = state.pathParameters['provider'];
        final provider = RemoteProviderType.values.where(
          (value) => value.name == providerName,
        );
        if (provider.length != 1 ||
            (provider.single != RemoteProviderType.googleDrive &&
                provider.single != RemoteProviderType.oneDrive)) {
          return const Center(child: Text('Unsupported OAuth provider.'));
        }
        return NewOAuthConnection(
          providerType: provider.single,
          replacementConnectionId: state.uri.queryParameters['replace'],
          returnTo: _setupReturnTo(state),
        );
      },
    ),
    WdRoute(
      name: AppRoutes.newBaiduToken.name,
      path: AppRoutes.newBaiduToken.path,
      builder: (context, state) => const NewBaiduToken(),
    ),
    WdRoute(
      name: AppRoutes.connection.name,
      path: AppRoutes.connection.path,
      builder: (context, state) {
        final String? id = state.pathParameters['id'];
        if (id == null) {
          return Center(child: Text('404! no id parameter.'));
        }
        final String? segments = state.uri.queryParameters['segments'];
        return Connection(
          id,
          initialSegments: segments == null || segments.isEmpty
              ? const []
              : segments.split('/').where((part) => part.isNotEmpty).toList(),
        );
      },
    ),
  ],
);

class WDShellPage extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const WDShellPage({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context) {
    return AdaptiveTabScaffold(
      body: KeyedSubtree(
        // Rebuilding the shell per tab keeps each tab's own scroll position and
        // page state from leaking into the others on Apple platforms, where the
        // tab bar animates between branches.
        key: ValueKey(navigationShell.currentIndex),
        child: navigationShell,
      ),
      items: [
        BottomNavigationBarItem(
          // The real Velock mark from the Velock app, flat and tinted with
          // the bar's own selected/unselected colours.
          icon: VelockBrandMark(
            size: 24,
            flat: true,
            color: navigationShell.currentIndex == 0
                ? context.appPrimary
                : context.appSecondaryLabel,
          ),
          label: syncText(context, '格间', "Velock"),
        ),
        BottomNavigationBarItem(
          icon: Icon(CupertinoIcons.folder),
          label: syncText(context, '文件同步', "Files"),
        ),
        BottomNavigationBarItem(
          icon: Icon(CupertinoIcons.gear_alt),
          label: syncText(context, '设置', "Settings"),
        ),
      ],
      currentIndex: navigationShell.currentIndex,
      onChanged: (index) => navigationShell.goBranch(index),
    );
  }
}

// Return only to known local product flows, never arbitrary routes or URLs.
String? _setupReturnTo(GoRouterState state) {
  final target = state.uri.queryParameters['returnTo'];
  return {
        AppRoutes.velockDatasetWizard.path,
        '${AppRoutes.velockDatasetWizard.path}?intent=restore',
        AppRoutes.selectedFolderProfiles.path,
        AppRoutes.velockRecovery.path,
      }.contains(target)
      ? target
      : null;
}
