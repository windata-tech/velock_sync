import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';

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
      return SizedBox.shrink();
    }
    return switch (status!) {
      ConnectionStatus.pending => SizedBox.fromSize(
        size: Size(pendingProgressSize ?? dotSize * 2, pendingProgressSize ?? dotSize * 2),
        child: CircularProgressIndicator(padding: EdgeInsets.all(0), strokeWidth: strokeWidth),
      ),
      ConnectionStatus.active => ColoredDot(size: dotSize, color: Colors.green),
      ConnectionStatus.inactive => ColoredDot(size: dotSize, color: Colors.grey),
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
      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.green),
    );
  }
}
