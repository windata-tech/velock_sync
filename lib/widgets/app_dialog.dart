import 'dart:ui' show ImageFilter;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:velock_sync/l10n/sync_locale.dart';

import '../appearance/design_tokens.dart';
import 'automation_id.dart';

/// How a dialog button reads.
enum AppDialogButtonRole {
  /// Quiet grey capsule: cancel, back, later.
  neutral,

  /// Filled with the brand colour: the action the dialog is about.
  primary,

  /// Filled red: the action removes or discards something.
  destructive,

  /// Grey capsule with red text: a removal that is not the suggested answer.
  destructiveQuiet,
}

/// One capsule button at the bottom of an [AppDialog].
@immutable
class AppDialogButton {
  const AppDialogButton({
    required this.label,
    required this.onPressed,
    this.role = AppDialogButtonRole.neutral,
    this.key,
  });

  final String label;

  /// `null` dims the button (it keeps its colour) and ignores taps.
  final VoidCallback? onPressed;
  final AppDialogButtonRole role;
  final Key? key;
}

/// The app's dialog on Apple platforms.
///
/// The system alert of older iOS versions (centred text, hairline-separated
/// blue words) looked bare next to the rest of the app. This is a floating
/// card in the current iOS style instead: large corners, a left-aligned title
/// with an optional tinted symbol, the body on a frosted surface, and capsule
/// buttons that sit side by side when both labels fit and stack otherwise.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.buttons,
    this.icon,
    this.tint,
    this.content,
  });

  final String title;
  final Widget? icon;

  /// Colour of the symbol badge; defaults to the brand colour.
  final Color? tint;
  final Widget? content;
  final List<AppDialogButton> buttons;

  static const _maxWidth = 344.0;
  static const _radius = 30.0;

  static const _surface = CupertinoDynamicColor.withBrightness(
    color: Color(0xF5FFFFFF),
    darkColor: Color(0xF0222225),
  );

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final label = CupertinoColors.label.resolveFrom(context);
    final card = Container(
      decoration: BoxDecoration(
        color: _surface.resolveFrom(context),
        borderRadius: BorderRadius.circular(_radius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  _SymbolBadge(tint: tint ?? context.appPrimary, child: icon!),
                  const SizedBox(height: 14),
                ],
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 19,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                      color: label,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (content != null)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: DefaultTextStyle.merge(
                  style: TextStyle(fontSize: 15, height: 1.42, color: label),
                  child: content!,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 16),
            child: _ButtonBar(buttons: buttons),
          ),
        ],
      ),
    );

    return AnimatedPadding(
      // Stay above the keyboard while a field is being edited.
      duration: AppMotion.standard,
      curve: Curves.easeOutCubic,
      padding: media.viewInsets + const EdgeInsets.all(24),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_radius),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x2E000000),
                    blurRadius: 48,
                    offset: Offset(0, 18),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_radius),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                  child: Material(
                    type: MaterialType.transparency,
                    child: DefaultTextStyle(
                      style: CupertinoTheme.of(
                        context,
                      ).textTheme.textStyle.copyWith(color: label),
                      child: card,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Presents an [AppDialog] (or anything built around one) with a soft dim and
/// a short settle-in, the way iOS presents its own alerts.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: syncText(context, '关闭', 'Dismiss'),
    barrierColor: CupertinoTheme.brightnessOf(context) == Brightness.dark
        ? const Color(0x80000000)
        : const Color(0x4D000000),
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (dialogContext, _, _) => builder(dialogContext),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 1.08, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Filled, borderless text field for dialogs: the field reads as a soft well
/// in the card and gains a brand-coloured edge while it is being edited.
class AppDialogTextField extends StatefulWidget {
  const AppDialogTextField({
    super.key,
    this.controller,
    this.placeholder,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.obscureText = false,
    this.autocorrect = true,
    this.minLines = 1,
    this.maxLines = 1,
    this.invalid = false,
  });

  final TextEditingController? controller;
  final String? placeholder;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool obscureText;
  final bool autocorrect;
  final int minLines;
  final int maxLines;

  /// Draws the edge in red, next to an error message below the field.
  final bool invalid;

  @override
  State<AppDialogTextField> createState() => _AppDialogTextFieldState();
}

class _AppDialogTextFieldState extends State<AppDialogTextField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() => setState(() {});

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final edge = widget.invalid
        ? context.appDanger
        : _focus.hasFocus
        ? context.appPrimary
        : const Color(0x00000000);
    return CupertinoTextField(
      controller: widget.controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      placeholder: widget.placeholder,
      placeholderStyle: TextStyle(
        fontSize: 16,
        color: context.appTertiaryLabel,
      ),
      obscureText: widget.obscureText,
      autocorrect: widget.autocorrect,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      clearButtonMode: OverlayVisibilityMode.editing,
      style: TextStyle(
        fontSize: 16,
        color: CupertinoColors.label.resolveFrom(context),
      ),
      cursorColor: context.appPrimary,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: edge, width: 1.5),
      ),
    );
  }
}

class _SymbolBadge extends StatelessWidget {
  const _SymbolBadge({required this.tint, required this.child});

  final Color tint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: IconTheme.merge(
        data: IconThemeData(color: tint, size: 26),
        child: child,
      ),
    );
  }
}

/// Side by side when there are two buttons whose labels both fit on one line;
/// stacked otherwise, with the main answer on top and the way out at the
/// bottom, as iOS orders stacked alert buttons.
class _ButtonBar extends StatelessWidget {
  const _ButtonBar({required this.buttons});

  final List<AppDialogButton> buttons;

  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) {
    if (buttons.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final half = (constraints.maxWidth - _gap) / 2;
        final textScaler = MediaQuery.textScalerOf(context);
        final fits =
            buttons.length <= 2 &&
            buttons.every((button) {
              final painter = TextPainter(
                text: TextSpan(text: button.label, style: _CapsuleButton.style),
                textDirection: Directionality.of(context),
                textScaler: textScaler,
                maxLines: 1,
              )..layout();
              final width = painter.width;
              painter.dispose();
              return width + _CapsuleButton.horizontalPadding * 2 <= half;
            });
        if (fits) {
          return Row(
            children: [
              for (final (index, button) in buttons.indexed) ...[
                if (index > 0) const SizedBox(width: _gap),
                Expanded(child: _CapsuleButton(button: button)),
              ],
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, button) in buttons.reversed.indexed) ...[
              if (index > 0) const SizedBox(height: _gap),
              _CapsuleButton(button: button),
            ],
          ],
        );
      },
    );
  }
}

class _CapsuleButton extends StatefulWidget {
  const _CapsuleButton({required this.button});

  final AppDialogButton button;

  static const style = TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
  static const horizontalPadding = 16.0;

  @override
  State<_CapsuleButton> createState() => _CapsuleButtonState();
}

class _CapsuleButtonState extends State<_CapsuleButton> {
  var _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final button = widget.button;
    final enabled = button.onPressed != null;
    final grey = CupertinoColors.tertiarySystemFill.resolveFrom(context);
    final (fill, ink) = switch (button.role) {
      AppDialogButtonRole.primary => (
        context.appPrimary,
        const Color(0xFFFFFFFF),
      ),
      AppDialogButtonRole.destructive => (
        context.appDanger,
        const Color(0xFFFFFFFF),
      ),
      AppDialogButtonRole.destructiveQuiet => (grey, context.appDanger),
      AppDialogButtonRole.neutral => (
        grey,
        CupertinoColors.label.resolveFrom(context),
      ),
    };
    final capsule = Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: button.onPressed,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: AppMotion.quick,
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            // Disabled keeps its colour and only fades, like the rest of the app.
            opacity: !enabled
                ? AppOpacity.disabled
                : _pressed
                ? 0.75
                : 1,
            duration: AppMotion.quick,
            child: Container(
              constraints: const BoxConstraints(minHeight: 50),
              padding: const EdgeInsets.symmetric(
                horizontal: _CapsuleButton.horizontalPadding,
                vertical: 12,
              ),
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                color: fill,
                shape: const StadiumBorder(),
              ),
              child: Text(
                button.label,
                textAlign: TextAlign.center,
                style: _CapsuleButton.style.copyWith(color: ink),
              ),
            ),
          ),
        ),
      ),
    );
    return withAutomationId(
      button.key,
      KeyedSubtree(key: button.key, child: capsule),
    );
  }
}

/// One row of an [AppActionSheet].
@immutable
class AppSheetOption {
  const AppSheetOption({
    required this.label,
    required this.onPressed,
    this.caption,
    this.icon,
    this.isDestructive = false,
    this.key,
  });

  final String label;
  final String? caption;

  /// Leading symbol, tinted with the brand colour (red when destructive).
  final Widget? icon;
  final VoidCallback onPressed;
  final bool isDestructive;
  final Key? key;
}

/// The app's choice menu on Apple platforms, in the same family as
/// [AppDialog]: a frosted card floating above the bottom edge, options as
/// rounded rows with their symbols, and the way out as a separate capsule.
class AppActionSheet extends StatelessWidget {
  const AppActionSheet({
    super.key,
    required this.options,
    required this.cancelLabel,
    required this.onCancel,
    this.title,
    this.message,
  });

  final String? title;
  final String? message;
  final List<AppSheetOption> options;
  final String cancelLabel;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final label = CupertinoColors.label.resolveFrom(context);
    final hasHeader = title != null || message != null;
    final card = Container(
      color: AppDialog._surface.resolveFrom(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasHeader)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (title != null)
                    Semantics(
                      header: true,
                      child: Text(
                        title!,
                        style: TextStyle(
                          fontSize: 17,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                          color: label,
                        ),
                      ),
                    ),
                  if (message != null) ...[
                    if (title != null) const SizedBox(height: 4),
                    Text(
                      message!,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: context.appSecondaryLabel,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (index, option) in options.indexed) ...[
                    if (index > 0) const SizedBox(height: 8),
                    _SheetRow(option: option),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
            child: _CapsuleButton(
              button: AppDialogButton(label: cancelLabel, onPressed: onCancel),
            ),
          ),
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        10,
        media.padding.top + 24,
        10,
        media.padding.bottom > 0 ? media.padding.bottom : 10,
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppDialog._radius),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x2E000000),
                  blurRadius: 48,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppDialog._radius),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: Material(
                  type: MaterialType.transparency,
                  child: DefaultTextStyle(
                    style: CupertinoTheme.of(
                      context,
                    ).textTheme.textStyle.copyWith(color: label),
                    child: card,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Presents an [AppActionSheet]: the card rises from the bottom edge while
/// the page dims, and a tap outside it cancels.
Future<T?> showAppActionSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: syncText(context, '关闭', 'Dismiss'),
    barrierColor: CupertinoTheme.brightnessOf(context) == Brightness.dark
        ? const Color(0x80000000)
        : const Color(0x4D000000),
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (sheetContext, _, _) => builder(sheetContext),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.18),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _SheetRow extends StatefulWidget {
  const _SheetRow({required this.option});

  final AppSheetOption option;

  @override
  State<_SheetRow> createState() => _SheetRowState();
}

class _SheetRowState extends State<_SheetRow> {
  var _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final option = widget.option;
    final tint = option.isDestructive ? context.appDanger : context.appPrimary;
    final ink = option.isDestructive
        ? context.appDanger
        : CupertinoColors.label.resolveFrom(context);
    final row = Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: option.onPressed,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1,
          duration: AppMotion.quick,
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: _pressed ? 0.7 : 1,
            duration: AppMotion.quick,
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  if (option.icon != null) ...[
                    IconTheme.merge(
                      data: IconThemeData(color: tint, size: 22),
                      child: SizedBox.square(
                        dimension: 24,
                        child: Center(child: option.icon),
                      ),
                    ),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          option.label,
                          style: TextStyle(
                            fontSize: 17,
                            height: 1.25,
                            fontWeight: FontWeight.w500,
                            color: ink,
                          ),
                        ),
                        if (option.caption != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            option.caption!,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.35,
                              color: context.appSecondaryLabel,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return withAutomationId(
      option.key,
      KeyedSubtree(key: option.key, child: row),
    );
  }
}
