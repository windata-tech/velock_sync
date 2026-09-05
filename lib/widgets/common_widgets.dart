import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';

/// Shows transient operation feedback without assuming a Material widget tree.
///
/// [PlatformApp] builds a Cupertino tree on Apple platforms, where a
/// [ScaffoldMessenger] is intentionally absent. Material pages retain the
/// standard SnackBar while Cupertino pages use the platform toast channel.
void showPlatformMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger != null) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
    return;
  }
  unawaited(Fluttertoast.showToast(msg: message));
}

class WDAppBar extends PlatformAppBar {
  WDAppBar({
    super.key,
    Widget? title,
    super.trailingActions,
    super.leading,
    bool showTitle = false,
  }) : super(
         title: showTitle ? title : null,
         material: (_, _) => MaterialAppBarData(
           centerTitle: false,
           elevation: 0,
           scrolledUnderElevation: 0,
           surfaceTintColor: Colors.transparent,
         ),
         cupertino: (_, _) => CupertinoNavigationBarData(
           border: const Border(
             bottom: BorderSide(color: CupertinoColors.separator, width: 0),
           ),
         ),
       );
}

/// 连接状态指示器
class ConnectStatusIndicator extends StatelessWidget {
  final ConnectionStatus? status;

  const ConnectStatusIndicator({
    super.key,
    required this.status,
    this.dotSize = 10,
    this.pendingProgressSize,
    this.strokeWidth = 2.5,
  });

  final double dotSize;
  final double? pendingProgressSize;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    if (status == null) {
      return const SizedBox.shrink();
    }
    return switch (status!) {
      ConnectionStatus.pending => SizedBox.fromSize(
        size: Size(
          pendingProgressSize ?? dotSize * 2,
          pendingProgressSize ?? dotSize * 2,
        ),
        child: CircularProgressIndicator(
          padding: const EdgeInsets.all(0),
          strokeWidth: strokeWidth,
        ),
      ),
      ConnectionStatus.active => ColoredDot(size: dotSize, color: Colors.green),
      ConnectionStatus.inactive => ColoredDot(
        size: dotSize,
        color: Colors.grey,
      ),
      ConnectionStatus.failed => ColoredDot(size: dotSize, color: Colors.red),
    };
  }
}

/// A colored dot with a given size.
class ColoredDot extends StatelessWidget {
  final double size;
  final Color color;

  const ColoredDot({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}
