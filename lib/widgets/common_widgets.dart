import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/l10n/sync_locale.dart';

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

/// Shared back affordance used by Sync page headers.
///
/// The button deliberately renders only a chevron: it does not include a
/// previous-page title, an arrow stem, or a circular background. Callers can
/// pass `null` to render the same affordance in a disabled state.
class AppBackButton extends StatelessWidget {
  const AppBackButton({super.key, required this.onPressed, this.semanticLabel});

  static const double touchTargetSize = 44;
  static const double iconSize = 20;

  final VoidCallback? onPressed;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final label = semanticLabel ?? syncText(context, '返回', 'Back');
    final enabled = onPressed != null;
    final iconColor = context.appPrimary.withValues(alpha: enabled ? 1 : 0.35);
    final icon = Icon(
      Icons.chevron_left_rounded,
      color: iconColor,
      size: iconSize,
    );

    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        enabled: enabled,
        onTap: onPressed,
        excludeSemantics: true,
        child: SizedBox.square(
          dimension: touchTargetSize,
          child: PlatformIconButton(
            padding: EdgeInsets.zero,
            icon: icon,
            onPressed: onPressed,
            material: (context, platform) => MaterialIconButtonData(
              constraints: const BoxConstraints.tightFor(
                width: touchTargetSize,
                height: touchTargetSize,
              ),
              iconSize: iconSize,
            ),
            cupertino: (context, platform) => CupertinoIconButtonData(
              minimumSize: const Size.square(touchTargetSize),
              foregroundColor: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

class WDAppBar extends PlatformAppBar {
  WDAppBar({
    super.key,
    Widget? title,
    super.trailingActions,
    super.leading,
    bool showTitle = true,
  }) : super(
         automaticallyImplyLeading: false,
         title: showTitle ? title : null,
         material: (context, _) => MaterialAppBarData(
           leading: _leadingFor(context, leading),
           automaticallyImplyLeading: false,
           centerTitle: false,
           elevation: 0,
           scrolledUnderElevation: 0,
           surfaceTintColor: Colors.transparent,
           backgroundColor: context.appNavigationBarBackground,
         ),
         cupertino: (context, _) => CupertinoNavigationBarData(
           leading: _leadingFor(context, leading),
           automaticallyImplyLeading: false,
           backgroundColor: context.appNavigationBarBackground,
           border: Border(
             bottom: BorderSide(
               color: context.appSeparator.withValues(alpha: 0.6),
               width: 0.5,
             ),
           ),
         ),
       );

  static Widget? _leadingFor(BuildContext context, Widget? leading) {
    if (leading != null) {
      return leading;
    }
    if (ModalRoute.of(context)?.canPop != true) {
      return null;
    }
    return AppBackButton(onPressed: () => Navigator.of(context).maybePop());
  }
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
