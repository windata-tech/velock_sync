import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:velock_sync/core/extensions.dart';
import 'package:velock_sync/core/wd_routes.dart';
import 'package:velock_sync/features/connection/ui/connection.dart';
import 'package:velock_sync/features/connection/ui/connections.dart';
import 'package:velock_sync/features/connection/ui/new_connection.dart';
import 'package:velock_sync/features/connection/ui/new_webdav.dart';
import 'package:velock_sync/features/connection/ui/protocols.dart';
import 'package:velock_sync/features/dashboard/ui/dashboard.dart';

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
  static const ({String name, String path}) newWebDav = (
    name: 'newWebDav',
    path: '/protocol/webdav/new',
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
                  Dashboard(),
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
              name: AppRoutes.settings.name,
              path: AppRoutes.settings.path,
              builder: (BuildContext context, GoRouterState state) =>
                  Container(),
            ),
          ],
        ),
      ],
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
      name: AppRoutes.newWebDav.name,
      path: AppRoutes.newWebDav.path,
      builder: (context, state) => NewWebDav(),
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
      widgetKey:
          (Theme.of(context).platform == TargetPlatform.iOS ||
              Theme.of(context).platform == TargetPlatform.macOS)
          ? ValueKey(navigationShell.currentIndex)
          : null,
      bottomNavBar: PlatformNavBar(
        backgroundColor: context.backgroundColor,
        items: [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard)),
          BottomNavigationBarItem(icon: Icon(Icons.cable)),
          BottomNavigationBarItem(icon: Icon(Icons.settings)),
        ],
        currentIndex: navigationShell.currentIndex,
        itemChanged: (int index) {
          navigationShell.goBranch(index /*, initialLocation: true*/);
        },
        material: (context, platform) {
          // TODO：Material颜色需要后面的theme覆盖或在theme中设置。
          return MaterialNavBarData(
            selectedLabelStyle: const TextStyle(
              fontWeight: FontWeight.w500,
            ) /*文字style，颜色被selectedItemColor覆盖，所以设置后无效。*/,
            unselectedLabelStyle: const TextStyle(
              fontWeight: FontWeight.normal,
            ),
            selectedFontSize: 14.0,
            unselectedFontSize: 13.0,
            selectedIconTheme: IconThemeData(
              color: Colors.grey[700],
              opacity: 1,
              size: 21,
            ),
            unselectedIconTheme: IconThemeData(
              color: Colors.grey[500],
              opacity: 0.9,
              size: 20,
            ),
            selectedItemColor: Colors.grey[700],
            unselectedItemColor: Colors.grey[500],
            showSelectedLabels: true,
            showUnselectedLabels: true,
            type: BottomNavigationBarType.fixed,
            // landscapeLayout: BottomNavigationBarLandscapeLayout.linear
            elevation: 2.0,
          );
        },
        cupertino: (context, platform) {
          return CupertinoTabBarData(
            iconSize: 24,
            // height: 55
            // activeColor: Colors.grey[700],
            // inactiveColor: Colors.grey[500],
          );
        },
      ),
    );
  }
}
