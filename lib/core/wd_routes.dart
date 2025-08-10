import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

mixin WDResultProviderMixin<T> on PageRoute<T> {
  T? _currentResult;

  void setCurrentResult(T? result) {
    _currentResult = result;
  }

  @override
  T? get currentResult => _currentResult;
}

class WDMaterialPageRoute<T> extends MaterialPageRoute<T> with WDResultProviderMixin<T> {
  final Duration? customTransitionDuration;

  WDMaterialPageRoute({
    required super.builder,
    super.settings,
    super.requestFocus,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.barrierDismissible,
    super.traversalEdgeBehavior,
    super.directionalTraversalEdgeBehavior,
    this.customTransitionDuration,
  });

  @override
  Duration get transitionDuration => customTransitionDuration ?? super.transitionDuration;
}

class WDCupertinoPageRoute<T> extends CupertinoPageRoute<T> with WDResultProviderMixin<T> {
  final Duration? customTransitionDuration;

  WDCupertinoPageRoute({
    required super.builder,
    super.title,
    super.settings,
    super.requestFocus,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.barrierDismissible,
    this.customTransitionDuration,
  });

  @override
  Duration get transitionDuration => customTransitionDuration ?? super.transitionDuration;
}

class WDMaterialPage<T> extends MaterialPage<T> {
  final bool? requestFocus;
  final bool barrierDismissible;
  final TraversalEdgeBehavior? traversalEdgeBehavior;
  final TraversalEdgeBehavior? directionalTraversalEdgeBehavior;
  final Duration? transitionDuration;

  const WDMaterialPage({
    required super.child,
    super.maintainState = true,
    super.fullscreenDialog = false,
    super.allowSnapshotting = true,
    super.canPop,
    super.onPopInvoked,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
    this.requestFocus,
    this.barrierDismissible = false,
    this.traversalEdgeBehavior,
    this.directionalTraversalEdgeBehavior,
    this.transitionDuration,
  });

  @override
  Route<T> createRoute(BuildContext context) {
    return WDMaterialPageRoute<T>(
      builder: (BuildContext context) => child,
      settings: this,
      requestFocus: requestFocus,
      maintainState: maintainState,
      fullscreenDialog: fullscreenDialog,
      allowSnapshotting: allowSnapshotting,
      barrierDismissible: barrierDismissible,
      traversalEdgeBehavior: traversalEdgeBehavior,
      directionalTraversalEdgeBehavior: directionalTraversalEdgeBehavior,
      customTransitionDuration: transitionDuration,
    );
  }
}

class WDCupertinoPage<T> extends CupertinoPage<T> {
  final bool? requestFocus;
  final bool barrierDismissible;
  final Duration? transitionDuration;

  const WDCupertinoPage({
    required super.child,
    super.maintainState = true,
    super.title,
    super.fullscreenDialog = false,
    super.allowSnapshotting = true,
    super.canPop,
    super.onPopInvoked,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
    this.requestFocus,
    this.barrierDismissible = false,
    this.transitionDuration,
  });

  @override
  Route<T> createRoute(BuildContext context) {
    return WDCupertinoPageRoute<T>(
      builder: (BuildContext context) => child,
      settings: this,
      requestFocus: requestFocus,
      maintainState: maintainState,
      fullscreenDialog: fullscreenDialog,
      allowSnapshotting: allowSnapshotting,
      barrierDismissible: barrierDismissible,
      customTransitionDuration: transitionDuration,
    );
  }
}

void _defaultPopInvokedHandler(bool didPop, Object? result) {}

Page<T> platformWDPage<T>({
  required Widget child,
  LocalKey? key,
  bool maintainState = true,
  String? title,
  String? name,
  Object? arguments,
  String? restorationId,
  bool fullscreenDialog = false,
  bool allowSnapshotting = true,
  bool canPop = true,
  PopInvokedWithResultCallback<T> onPopInvoked = _defaultPopInvokedHandler,
  bool barrierDismissible = false,
  bool? requestFocus,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  TraversalEdgeBehavior? directionalTraversalEdgeBehavior,
  Duration? transitionDuration,
}) {
  if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS) {
    return WDCupertinoPage<T>(
      child: child,
      title: title,
      fullscreenDialog: fullscreenDialog,
      allowSnapshotting: allowSnapshotting,
      maintainState: maintainState,
      canPop: canPop,
      onPopInvoked: onPopInvoked,
      key: key,
      name: name,
      restorationId: restorationId,
      requestFocus: requestFocus,
      barrierDismissible: barrierDismissible,
      arguments: arguments,
      transitionDuration: transitionDuration,
    );
  } else {
    return WDMaterialPage<T>(
      child: child,
      maintainState: maintainState,
      fullscreenDialog: fullscreenDialog,
      allowSnapshotting: allowSnapshotting,
      canPop: canPop,
      onPopInvoked: onPopInvoked,
      key: key,
      name: name,
      arguments: arguments,
      restorationId: restorationId,
      requestFocus: requestFocus,
      barrierDismissible: barrierDismissible,
      traversalEdgeBehavior: traversalEdgeBehavior,
      directionalTraversalEdgeBehavior: directionalTraversalEdgeBehavior,
      transitionDuration: transitionDuration,
    );
  }
}

class WdRoute<T> extends GoRoute {
  WdRoute({
    required super.path,
    required Widget Function(BuildContext context, GoRouterState state) builder,
    super.name,
    super.routes = const <GoRoute>[],
    super.parentNavigatorKey,
    super.redirect,
    super.onExit,
    super.caseSensitive = true,
    String? title,
    bool fullscreenDialog = false,
    bool allowSnapshotting = true,
    bool maintainState = true,
    bool canPop = true,
    PopInvokedWithResultCallback<T> onPopInvoked = _defaultPopInvokedHandler,
    Object? originalArguments,
    bool? requestFocus,
    bool barrierDismissible = false,
    TraversalEdgeBehavior? traversalEdgeBehavior,
    TraversalEdgeBehavior? directionalTraversalEdgeBehavior,
    Duration? transitionDuration,
  }) : super(pageBuilder: (context, state) {
          return platformWDPage<T>(
            child: builder(context, state),
            title: title,
            fullscreenDialog: fullscreenDialog,
            allowSnapshotting: allowSnapshotting,
            maintainState: maintainState,
            canPop: canPop,
            onPopInvoked: onPopInvoked,
            key: state.pageKey,
            name: state.name,
            arguments: originalArguments ?? state.extra,
            restorationId: state.pageKey.value,
            requestFocus: requestFocus,
            barrierDismissible: barrierDismissible,
            traversalEdgeBehavior: traversalEdgeBehavior,
            directionalTraversalEdgeBehavior: directionalTraversalEdgeBehavior,
            transitionDuration: transitionDuration,
          );
        });
}
