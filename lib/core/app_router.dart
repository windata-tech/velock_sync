import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/wd_routes.dart';
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

final goRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  debugLogDiagnostics: true,
  initialLocation: AppRoutes.home.path,
  observers: [routeObserver],
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
              name: AppRoutes.connections.name,
              path: AppRoutes.connections.path,
              builder: (BuildContext context, GoRouterState state) =>
                  Connections(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: <RouteBase>[
            WdRoute(
              name: AppRoutes.activity.name,
              path: AppRoutes.activity.path,
              builder: (BuildContext context, GoRouterState state) =>
                  const SyncActivity(),
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
      name: AppRoutes.syncProfilesNew.name,
      path: AppRoutes.syncProfilesNew.path,
      builder: (context, state) => const NewSyncProfile(),
    ),
    WdRoute(
      name: AppRoutes.velockDatasetWizard.name,
      path: AppRoutes.velockDatasetWizard.path,
      builder: (context, state) => const VelockDatasetWizard(),
    ),
    WdRoute(
      name: AppRoutes.selectedFolderProfiles.name,
      path: AppRoutes.selectedFolderProfiles.path,
      builder: (context, state) => const SelectedFolderProfiles(),
    ),
    WdRoute(
      name: AppRoutes.syncProfileDetail.name,
      path: AppRoutes.syncProfileDetail.path,
      builder: (context, state) {
        final profileId = state.pathParameters['profileId'];
        if (profileId == null || profileId.isEmpty) {
          return const Scaffold(body: Center(child: Text('找不到该同步配置。')));
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
      builder: (context, state) => Protocols(),
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
        return Connection(id);
      },
    ),
  ],
);

class WDShellPage extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const WDShellPage({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context) {
    return PlatformScaffold(
      body: navigationShell,
      widgetKey: isApplePlatform(context)
          ? ValueKey(navigationShell.currentIndex)
          : null,
      bottomNavBar: PlatformNavBar(
        backgroundColor: context.appGroupedSurface,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.arrow_2_circlepath),
            label: '同步',
          ),
          BottomNavigationBarItem(icon: Icon(CupertinoIcons.link), label: '连接'),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.clock),
            label: '活动',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.gear_alt),
            label: '设置',
          ),
        ],
        currentIndex: navigationShell.currentIndex,
        itemChanged: (index) => navigationShell.goBranch(index),
        material: (_, _) => MaterialNavBarData(
          type: BottomNavigationBarType.fixed,
          showSelectedLabels: true,
          showUnselectedLabels: true,
          selectedItemColor: context.appPrimary,
          unselectedItemColor: context.appSecondaryLabel,
          elevation: 2,
        ),
        cupertino: (_, _) => CupertinoTabBarData(
          activeColor: context.appPrimary,
          inactiveColor: context.appSecondaryLabel,
          iconSize: 24,
        ),
      ),
    );
  }
}
