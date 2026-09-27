import 'package:velock_sync/l10n/sync_locale.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../appearance/design_tokens.dart';

/// Platform-adaptive dialogs.
///
/// Every dialog in the app is created here so a page can never mix a Material
/// dialog into a Cupertino tree (or the other way around):
///
/// * Apple platforms get the native presentation — [CupertinoAlertDialog] for
///   alerts and [CupertinoActionSheet] for choices.
/// * Every other platform gets the Material equivalent — [AlertDialog] or a
///   [SimpleDialog] option list.
///
/// Callers describe intent (title, message, options, fields) and never call
/// `showDialog`, `showCupertinoDialog` or build a dialog widget themselves.

/// One choice rendered by [showAdaptiveActionSheet].
@immutable
class AdaptiveAction<T> {
  const AdaptiveAction({
    required this.label,
    required this.value,
    this.caption,
    this.key,
    this.isDestructive = false,
  });

  /// Primary line of the option.
  final String label;

  /// Optional secondary line shown under [label].
  final String? caption;

  /// Value returned by [showAdaptiveActionSheet] when the option is picked.
  final T value;

  /// Optional key used by widget tests.
  final Key? key;

  /// Rendered in the platform's destructive style.
  final bool isDestructive;
}

/// One button rendered by [showAdaptiveAlert] and [showAdaptiveForm].
@immutable
class AdaptiveAlertAction<T> {
  const AdaptiveAlertAction({
    required this.label,
    this.value,
    this.key,
    this.isDefault = false,
    this.isDestructive = false,
    this.emphasized = false,
    this.enabled = true,
  });

  final String label;
  final T? value;
  final Key? key;

  /// Disabled actions are greyed out and cannot be pressed.
  final bool enabled;

  /// Apple platforms render this as the preferred action.
  final bool isDefault;

  final bool isDestructive;

  /// Material platforms render this as a filled button.
  final bool emphasized;
}

/// One text field rendered by [showAdaptiveTextInputs].
@immutable
class AdaptiveTextInput {
  const AdaptiveTextInput({
    required this.label,
    this.placeholder,
    this.obscureText = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.autocorrect = true,
  });

  final String label;
  final String? placeholder;
  final bool obscureText;
  final int minLines;
  final int maxLines;
  final bool autocorrect;
}

/// Bottom action sheet on Apple platforms, option list dialog elsewhere.
Future<T?> showAdaptiveActionSheet<T>({
  required BuildContext context,
  String? title,
  String? message,
  required List<AdaptiveAction<T>> actions,
  String? cancelLabel,
  bool barrierDismissible = true,
}) {
  if (actions.isEmpty) return Future<T?>.value();

  if (isApplePlatform(context)) {
    return showCupertinoModalPopup<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (sheetContext) => CupertinoActionSheet(
        title: title == null ? null : Text(title),
        message: message == null ? null : Text(message),
        actions: [
          for (final action in actions)
            CupertinoActionSheetAction(
              key: action.key,
              isDestructiveAction: action.isDestructive,
              onPressed: () => Navigator.of(sheetContext).pop(action.value),
              child: _SheetLabel(label: action.label, caption: action.caption),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(cancelLabel ?? syncText(context, '取消', 'Cancel')),
        ),
      ),
    );
  }

  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return SimpleDialog(
        title: title == null ? null : Text(title),
        children: [
          if (message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final action in actions)
            SimpleDialogOption(
              key: action.key,
              onPressed: () => Navigator.of(dialogContext).pop(action.value),
              child: _SheetLabel(label: action.label, caption: action.caption),
            ),
        ],
      );
    },
  );
}

/// Bottom sheet whose frame matches the host platform.
Future<void> showAdaptiveSheet(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  if (isApplePlatform(context)) {
    return showCupertinoModalPopup<void>(context: context, builder: builder);
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.appElevatedSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.sheet)),
    ),
    builder: builder,
  );
}

/// General platform-adaptive alert with any number of actions.
Future<T?> showAdaptiveAlert<T>({
  required BuildContext context,
  required String title,
  String? message,
  Widget? details,
  Widget? icon,
  required List<AdaptiveAlertAction<T>> actions,
  bool barrierDismissible = true,
}) {
  if (isApplePlatform(context)) {
    return showCupertinoDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(title),
        content: _AlertBody(message: message, details: details, icon: icon),
        actions: [
          for (final action in actions)
            CupertinoDialogAction(
              key: action.key,
              isDefaultAction: action.isDefault,
              isDestructiveAction: action.isDestructive,
              onPressed: action.enabled
                  ? () => Navigator.of(dialogContext).pop(action.value)
                  : null,
              child: Text(action.label),
            ),
        ],
      ),
    );
  }

  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (dialogContext) {
      final scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        icon: icon,
        title: Text(title),
        content: _AlertBody(message: message, details: details),
        actions: [
          for (final action in actions)
            if (action.emphasized)
              FilledButton(
                key: action.key,
                onPressed: action.enabled
                    ? () => Navigator.of(dialogContext).pop(action.value)
                    : null,
                style: action.isDestructive
                    ? FilledButton.styleFrom(
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.onError,
                      )
                    : null,
                child: Text(action.label),
              )
            else
              TextButton(
                key: action.key,
                onPressed: action.enabled
                    ? () => Navigator.of(dialogContext).pop(action.value)
                    : null,
                style: action.isDestructive
                    ? TextButton.styleFrom(foregroundColor: scheme.error)
                    : null,
                child: Text(action.label),
              ),
        ],
      );
    },
  );
}

/// Two-action confirmation. Returns `false` when dismissed.
Future<bool> showAdaptiveConfirmation(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String? cancelLabel,
  bool isDestructive = false,
  Key? confirmKey,
  Key? cancelKey,
}) async {
  final result = await showAdaptiveAlert<bool>(
    context: context,
    title: title,
    message: message,
    actions: [
      AdaptiveAlertAction<bool>(
        label: cancelLabel ?? syncText(context, '取消', 'Cancel'),
        value: false,
        key: cancelKey,
      ),
      AdaptiveAlertAction<bool>(
        label: confirmLabel,
        value: true,
        key: confirmKey,
        isDefault: true,
        isDestructive: isDestructive,
        emphasized: true,
      ),
    ],
  );
  return result ?? false;
}

/// Single-action alert used to hand information back to the user.
Future<void> showAdaptiveNotice({
  required BuildContext context,
  required String title,
  required String message,
  Widget? details,
  String? confirmLabel,
  Key? confirmKey,
}) async {
  await showAdaptiveAlert<Object?>(
    context: context,
    title: title,
    message: message,
    details: details,
    actions: [
      AdaptiveAlertAction<Object?>(
        label: confirmLabel ?? syncText(context, '好', 'OK'),
        value: null,
        key: confirmKey,
        isDefault: true,
        emphasized: true,
      ),
    ],
  );
}

/// Content and actions of one [showAdaptiveForm] build.
///
/// Returned from the form builder so content and actions are rebuilt together
/// whenever the user edits the form.
@immutable
class AdaptiveFormSpec<T> {
  const AdaptiveFormSpec({required this.content, required this.actions});

  final Widget content;
  final List<AdaptiveAlertAction<T>> actions;
}

/// Platform-adaptive form dialog.
///
/// [builder] is called on every rebuild and receives a [StateSetter] plus the
/// dialog [BuildContext]; it returns the dialog content together with its
/// actions. Because both are rebuilt together, an action can depend on the
/// values the user just entered.
Future<T?> showAdaptiveForm<T>({
  required BuildContext context,
  required String title,
  required AdaptiveFormSpec<T> Function(
    BuildContext context,
    StateSetter setDialogState,
  )
  builder,
  bool barrierDismissible = true,
}) {
  Widget dialog(BuildContext dialogContext) => StatefulBuilder(
    builder: (context, setDialogState) {
      final spec = builder(context, setDialogState);
      if (isApplePlatform(context)) {
        return CupertinoAlertDialog(
          title: Text(title),
          content: spec.content,
          actions: [
            for (final action in spec.actions)
              CupertinoDialogAction(
                key: action.key,
                isDefaultAction: action.isDefault,
                isDestructiveAction: action.isDestructive,
                onPressed: action.enabled
                    ? () => Navigator.of(context).pop(action.value)
                    : null,
                child: Text(action.label),
              ),
          ],
        );
      }
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: spec.content,
        actions: [
          for (final action in spec.actions)
            if (action.emphasized)
              FilledButton(
                key: action.key,
                onPressed: action.enabled
                    ? () => Navigator.of(context).pop(action.value)
                    : null,
                style: action.isDestructive
                    ? FilledButton.styleFrom(
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.onError,
                      )
                    : null,
                child: Text(action.label),
              )
            else
              TextButton(
                key: action.key,
                onPressed: action.enabled
                    ? () => Navigator.of(context).pop(action.value)
                    : null,
                style: action.isDestructive
                    ? TextButton.styleFrom(foregroundColor: scheme.error)
                    : null,
                child: Text(action.label),
              ),
        ],
      );
    },
  );

  if (isApplePlatform(context)) {
    return showCupertinoDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: dialog,
    );
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: dialog,
  );
}

/// Multi-field text form.
///
/// The controllers live inside the dialog's own [State], so they are disposed
/// together with the route after its exit animation — disposing them next to
/// the `await` used to trip Flutter's `_dependents.isEmpty` assertion.
///
/// Returns the entered values in field order, or `null` when cancelled.
/// [isValid] drives the confirm button's enabled state.
Future<List<String>?> showAdaptiveTextInputs({
  required BuildContext context,
  required String title,
  String? message,
  required List<AdaptiveTextInput> inputs,
  required String confirmLabel,
  String? cancelLabel,
  bool Function(List<String> values)? isValid,
  Key? confirmKey,
}) {
  Widget builder(BuildContext _) => _AdaptiveTextForm(
    title: title,
    message: message,
    inputs: inputs,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel ?? syncText(context, '取消', 'Cancel'),
    isValid: isValid,
    confirmKey: confirmKey,
  );

  if (isApplePlatform(context)) {
    return showCupertinoDialog<List<String>>(
      context: context,
      builder: builder,
    );
  }
  return showDialog<List<String>>(context: context, builder: builder);
}

/// Label + switch row that follows the host platform's control style.
class AdaptiveSwitchRow extends StatelessWidget {
  const AdaptiveSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: const TextStyle(fontSize: 14)),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              style: TextStyle(fontSize: 12, color: context.appSecondaryLabel),
            ),
          ),
      ],
    );
    if (isApplePlatform(context)) {
      return Opacity(
        opacity: onChanged == null ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(child: label),
              const SizedBox(width: 8),
              CupertinoSwitch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      );
    }
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: label,
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Compact segmented choice on Apple platforms, dropdown elsewhere.
class AdaptiveOptionPicker<T extends Object> extends StatelessWidget {
  const AdaptiveOptionPicker({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;

  /// Label + value pairs in display order.
  final List<(String, T)> options;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = options.any((option) => option.$2 == value)
        ? value
        : options.first.$2;
    if (isApplePlatform(context)) {
      return Opacity(
        opacity: onChanged == null ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 6),
              CupertinoSlidingSegmentedControl<T>(
                groupValue: selected,
                children: {
                  for (final (title, optionValue) in options)
                    optionValue: Text(
                      title,
                      style: const TextStyle(fontSize: 12),
                    ),
                },
                onValueChanged: (value) {
                  if (value != null) onChanged?.call(value);
                },
              ),
            ],
          ),
        ),
      );
    }
    return DropdownButtonFormField<T>(
      initialValue: selected,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final (title, optionValue) in options)
          DropdownMenuItem<T>(value: optionValue, child: Text(title)),
      ],
      onChanged: (value) {
        if (value != null) onChanged?.call(value);
      },
    );
  }
}

/// Single-line (or multi-line) text field styled for the host platform.
class AdaptiveTextField extends StatefulWidget {
  const AdaptiveTextField({
    super.key,
    required this.label,
    this.initialValue,
    this.placeholder,
    this.obscureText = false,
    this.maxLines = 1,
    this.maxLength,
    this.onChanged,
  });

  final String label;
  final String? initialValue;
  final String? placeholder;
  final bool obscureText;
  final int maxLines;
  final int? maxLength;
  final ValueChanged<String>? onChanged;

  @override
  State<AdaptiveTextField> createState() => _AdaptiveTextFieldState();
}

class _AdaptiveTextFieldState extends State<AdaptiveTextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (isApplePlatform(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.label, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          CupertinoTextField(
            controller: _controller,
            onChanged: widget.onChanged,
            placeholder: widget.placeholder,
            obscureText: widget.obscureText,
            maxLines: widget.maxLines,
            maxLength: widget.maxLength,
            autocorrect: false,
            style: const TextStyle(fontSize: 14),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: context.appGroupedSurface.withValues(alpha: 0.7),
              border: Border.all(
                color: context.appSeparator.withValues(alpha: 0.5),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ],
      );
    }
    return TextFormField(
      controller: _controller,
      onChanged: widget.onChanged,
      initialValue: null,
      obscureText: widget.obscureText,
      maxLines: widget.maxLines,
      maxLength: widget.maxLength,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.placeholder,
      ),
    );
  }
}

class _SheetLabel extends StatelessWidget {
  const _SheetLabel({required this.label, this.caption});

  final String label;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    if (caption == null) return Text(label);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(height: 2),
        Text(
          caption!,
          style: TextStyle(fontSize: 12, color: context.appSecondaryLabel),
        ),
      ],
    );
  }
}

class _AlertBody extends StatelessWidget {
  const _AlertBody({this.message, this.details, this.icon});

  final String? message;
  final Widget? details;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      if (icon != null)
        Padding(padding: const EdgeInsets.only(bottom: 8), child: icon),
      if (message != null)
        Text(
          message!,
          textAlign: isApplePlatform(context)
              ? TextAlign.center
              : TextAlign.start,
        ),
      if (details != null) ...[
        if (message != null) const SizedBox(height: 12),
        details!,
      ],
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) return children.single;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: isApplePlatform(context)
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _AdaptiveTextForm extends StatefulWidget {
  const _AdaptiveTextForm({
    required this.title,
    required this.message,
    required this.inputs,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.isValid,
    this.confirmKey,
  });

  final String title;
  final String? message;
  final List<AdaptiveTextInput> inputs;
  final String confirmLabel;
  final String cancelLabel;
  final bool Function(List<String> values)? isValid;
  final Key? confirmKey;

  @override
  State<_AdaptiveTextForm> createState() => _AdaptiveTextFormState();
}

class _AdaptiveTextFormState extends State<_AdaptiveTextForm> {
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = [for (final _ in widget.inputs) TextEditingController()];
    for (final controller in _controllers) {
      controller.addListener(_handleFieldChanged);
    }
  }

  void _handleFieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.removeListener(_handleFieldChanged);
      controller.dispose();
    }
    super.dispose();
  }

  List<String> get _values => [
    for (final controller in _controllers) controller.text,
  ];

  bool get _canSubmit =>
      widget.isValid?.call(_values) ?? _values.every((v) => v.isNotEmpty);

  void _submit() {
    if (!_canSubmit) return;
    Navigator.of(context).pop(_values);
  }

  @override
  Widget build(BuildContext context) {
    final fields = <Widget>[
      for (var index = 0; index < widget.inputs.length; index++)
        Padding(
          padding: EdgeInsets.only(top: index == 0 ? 0 : 10),
          child: _field(context, index),
        ),
    ];

    if (isApplePlatform(context)) {
      return CupertinoAlertDialog(
        title: Text(widget.title),
        content: _formBody(
          context,
          messageStyle: TextStyle(
            fontSize: 13,
            height: 1.35,
            color: context.appSecondaryLabel,
          ),
          fields: fields,
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.cancelLabel),
          ),
          CupertinoDialogAction(
            key: widget.confirmKey,
            isDefaultAction: true,
            onPressed: _canSubmit ? _submit : null,
            child: Text(widget.confirmLabel),
          ),
        ],
      );
    }

    return AlertDialog(
      title: Text(widget.title),
      content: _formBody(context, messageStyle: null, fields: fields),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          key: widget.confirmKey,
          onPressed: _canSubmit ? _submit : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }

  Widget _formBody(
    BuildContext context, {
    required TextStyle? messageStyle,
    required List<Widget> fields,
  }) {
    final message = widget.message;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null) ...[
            Text(message, style: messageStyle, textAlign: TextAlign.start),
            const SizedBox(height: 12),
          ],
          ...fields,
        ],
      ),
    );
  }

  Widget _field(BuildContext context, int index) {
    final input = widget.inputs[index];
    final controller = _controllers[index];

    if (isApplePlatform(context)) {
      return CupertinoTextField(
        controller: controller,
        placeholder: input.placeholder ?? input.label,
        placeholderStyle: TextStyle(
          fontSize: 14,
          color: context.appTertiaryLabel,
        ),
        obscureText: input.obscureText,
        minLines: input.minLines,
        maxLines: input.maxLines,
        autocorrect: input.autocorrect,
        style: const TextStyle(fontSize: 14),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: context.appGroupedSurface.withValues(alpha: 0.7),
          border: Border.all(
            color: context.appSeparator.withValues(alpha: 0.5),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
      );
    }

    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: input.label,
        hintText: input.placeholder,
        border: const OutlineInputBorder(),
      ),
      obscureText: input.obscureText,
      minLines: input.minLines,
      maxLines: input.maxLines,
      autocorrect: input.autocorrect,
    );
  }
}
