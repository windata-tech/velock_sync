import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
      name: AppRoutes.velockDatasetWizard.name,
      path: AppRoutes.velockDatasetWizard.path,
      builder: (context, state) => const VelockDatasetWizard(),
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
    void selectBranch(int index) {
      navigationShell.goBranch(
        index,
        initialLocation: index == navigationShell.currentIndex,
      );
    }

    if (isApplePlatform(context)) {
      return CupertinoPageScaffold(
        backgroundColor: context.appPageBackground,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              Expanded(child: navigationShell),
              _CompactCupertinoTabBar(
                currentIndex: navigationShell.currentIndex,
                activeColor: context.appPrimary,
                inactiveColor: context.appSecondaryLabel,
                iconSize: 24,
                height: AppSizes.bottomNavigation,
                backgroundColor: context.appGroupedSurface,
                border: Border(
                  top: BorderSide(
                    color: context.appSeparator.withValues(
                      alpha: AppOpacity.navigationRule,
                    ),
                    width: 0.5,
                  ),
                ),
                onTap: selectBranch,
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(CupertinoIcons.arrow_2_circlepath),
                    label: '同步',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(CupertinoIcons.link),
                    label: '连接',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(CupertinoIcons.clock),
                    label: '活动',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(CupertinoIcons.gear_alt),
                    label: '设置',
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        height: AppSizes.materialBottomNavigation,
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: selectBranch,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.sync_outlined),
            selectedIcon: Icon(Icons.sync_rounded),
            label: '同步',
          ),
          NavigationDestination(
            icon: Icon(Icons.link_outlined),
            selectedIcon: Icon(Icons.link_rounded),
            label: '连接',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history_rounded),
            label: '活动',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

class _CompactCupertinoTabBar extends StatelessWidget {
  const _CompactCupertinoTabBar({
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.backgroundColor,
    required this.activeColor,
    required this.inactiveColor,
    required this.iconSize,
    required this.height,
    required this.border,
  });

  final List<BottomNavigationBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Color backgroundColor;
  final Color activeColor;
  final Color inactiveColor;
  final double iconSize;
  final double height;
  final Border border;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
    final labelStyle = CupertinoTheme.of(context).textTheme.tabLabelTextStyle;

    return DecoratedBox(
      decoration: BoxDecoration(color: backgroundColor, border: border),
      child: SizedBox(
        height: height + bottomPadding,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomPadding),
          child: Semantics(
            explicitChildNodes: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var index = 0; index < items.length; index++)
                  Expanded(
                    child: Semantics(
                      selected: index == currentIndex,
                      button: true,
                      label: items[index].label,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onTap(index),
                        child: Padding(
                          // Lift the icon + label group while preserving the
                          // full-height tab hit target and the home-indicator
                          // safe area.
                          padding: const EdgeInsets.only(bottom: 14),
                          child: _buildItem(
                            context,
                            items[index],
                            index == currentIndex,
                            labelStyle,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItem(
    BuildContext context,
    BottomNavigationBarItem item,
    bool active,
    TextStyle labelStyle,
  ) {
    final color = active ? activeColor : inactiveColor;
    return IconTheme.merge(
      data: IconThemeData(color: color, size: iconSize),
      child: DefaultTextStyle.merge(
        style: labelStyle.copyWith(color: color),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            active ? item.activeIcon : item.icon,
            if (item.label != null) ...[
              const SizedBox(height: AppSpacing.bottomNavigationItemGap),
              Text(item.label!, semanticsLabel: item.semanticsLabel),
            ],
          ],
        ),
      ),
    );
  }
}
