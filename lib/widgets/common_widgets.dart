import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/l10n/sync_locale.dart';

/// Shows transient operation feedback without assuming a Material widget tree.
///
/// MaterialApp installs a [ScaffoldMessenger] even when its pages only contain
/// Cupertino scaffolds. A messenger alone cannot present a SnackBar: require a
/// Material scaffold on Apple pages as well, otherwise use the platform toast
/// channel. Material pages can call from above their own descendant Scaffold.
void showPlatformMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger != null &&
      (!isApplePlatform(context) || Scaffold.maybeOf(context) != null)) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
    return;
  }
  unawaited(Fluttertoast.showToast(msg: message));
}

/// Shared back affordance used by Sync page headers.
///
/// The button deliberately renders only a chevron: it does not include a
/// previous-page title, an arrow stem, or a circular background. The rounded
/// Material glyph carries internal whitespace inside its design grid, so the
/// icon box is 32 to keep the visible chevron legible; the 44px touch target
/// around it stays unchanged. Callers can pass `null` to render the same
/// affordance in a disabled state.
class AppBackButton extends StatelessWidget {
  const AppBackButton({super.key, required this.onPressed, this.semanticLabel});

  static const double touchTargetSize = 44;
  static const double iconSize = 32;

  // The 32px glyph's visible tip is ~16px inside the 44px target.
  // Headers must start this target at the safe-area edge, NOT add another
  // 16px navigation inset. This aligns the ink with AppSpacing.page.
  static const double headerInset = 0;

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
          child: isApplePlatform(context)
              ? CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size.square(touchTargetSize),
                  onPressed: onPressed,
                  child: icon,
                )
              : IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: touchTargetSize,
                    height: touchTargetSize,
                  ),
                  iconSize: iconSize,
                  icon: icon,
                  onPressed: onPressed,
                ),
        ),
      ),
    );
  }
}

/// The app's own platform-adaptive navigation bar.
///
/// Replaces `flutter_platform_widgets`' `PlatformAppBar`, which is discontinued
/// upstream (Flutter is moving Material/Cupertino out of the SDK). The two
/// branches keep exactly the layout rules established for Sync headers: the
/// leading slot holds a 44pt [AppBackButton] whose ink sits at the page edge
/// (no extra 8pt after it), the title may wrap to two lines, and the trailing
/// actions are laid out with `MainAxisSize.min`.
class WDAppBar extends StatelessWidget
    implements ObstructingPreferredSizeWidget {
  const WDAppBar({
    super.key,
    this.title,
    this.trailingActions,
    this.leading,
    this.showTitle = true,
  });

  final Widget? title;
  final List<Widget>? trailingActions;
  final Widget? leading;
  final bool showTitle;

  static const double _barHeight = 44;

  @override
  Size get preferredSize => const Size.fromHeight(_barHeight);

  /// The bar paints an opaque background, so content behind it is hidden.
  @override
  bool shouldFullyObstruct(BuildContext context) => true;

  @override
  Widget build(BuildContext context) {
    final resolvedLeading = _leadingFor(context, leading);
    final resolvedTitle = showTitle ? title : null;
    final resolvedTrailing = trailingActions == null || trailingActions!.isEmpty
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: trailingActions!,
          );

    if (isApplePlatform(context)) {
      return CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        leading: resolvedLeading,
        middle: resolvedTitle,
        trailing: resolvedTrailing,
        backgroundColor: context.appNavigationBarBackground,
        // The back button is already a 44pt touch target whose ink sits at the
        // page edge; adding the usual trailing gap after it overflowed the
        // leading slot (debug stripes) for some fonts and text scales.
        padding: resolvedLeading is AppBackButton
            ? const EdgeInsetsDirectional.only(
                start: AppBackButton.headerInset,
                end: AppSpacing.page,
              )
            : null,
        border: Border(
          bottom: BorderSide(
            color: context.appSeparator.withValues(alpha: 0.6),
            width: 0.5,
          ),
        ),
      );
    }

    return AppBar(
      leading: resolvedLeading,
      leadingWidth: resolvedLeading is AppBackButton
          ? AppBackButton.touchTargetSize
          : null,
      automaticallyImplyLeading: false,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: context.appNavigationBarBackground,
      title: resolvedTitle,
      actions: trailingActions,
    );
  }

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
