import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';

class WDAppBar extends PlatformAppBar {
  WDAppBar({super.key, super.title, super.trailingActions, super.leading})
    : super(
        // backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        material: (_, __) => MaterialAppBarData(
          centerTitle: true,
          titleTextStyle: const TextStyle(color: Colors.white, fontSize: 20), //
        ),
        cupertino: (_, __) => CupertinoNavigationBarData(
          // padding: EdgeInsetsDirectional.zero
        ),
      );
}