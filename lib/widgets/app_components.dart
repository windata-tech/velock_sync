import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../appearance/design_tokens.dart';

/// Components shared by every page of Velock Sync.
///
/// These sit on top of the adaptive primitives and own the *product* look:
/// semantic status, section rhythm, form rows and modal detail sheets. Keeping
/// them in one file is what makes page-by-page cleanups converge instead of
/// drifting again.

/// A quiet inline message: what happened, why it matters, what to do next.
class AppNotice extends StatelessWidget {
  const AppNotice({
    super.key,
    required this.tone,
    required this.title,
    this.message,
    this.action,
    this.icon,
  });

  final AppTone tone;
  final String title;
  final String? message;
  final Widget? action;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = tone.color(context);
    final resolvedIcon =
        icon ??
        switch (tone) {
          AppTone.ok => CupertinoIcons.check_mark_circled,
          AppTone.attention => CupertinoIcons.exclamationmark_triangle,
          AppTone.danger => CupertinoIcons.exclamationmark_circle,
          AppTone.brand => CupertinoIcons.info_circle,
          AppTone.neutral => CupertinoIcons.info_circle,
        };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.appGroupedSurface,
        borderRadius: BorderRadius.circular(AppRadii.large),
        border: Border.all(
          color: context.appSeparator.withValues(
            alpha: AppOpacity.groupedBorder,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm + 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: AppSizes.listLeadingCompact,
              height: AppSizes.listLeadingCompact,
              decoration: BoxDecoration(
                color: tone.surface(context),
                borderRadius: BorderRadius.circular(AppRadii.medium),
              ),
              alignment: Alignment.center,
              child: Icon(resolvedIcon, size: 18, color: color),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppType.rowTitleStrong.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  if (message != null && message!.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      message!,
                      style: AppType.rowSubtitle.copyWith(
                        color: context.appSecondaryLabel,
                      ),
                    ),
                  ],
                  if (action != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    action!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppMetric {
  const AppMetric({
    required this.value,
    required this.label,
    this.tone = AppTone.neutral,
  });

  final String value;
  final String label;
  final AppTone tone;
}

/// Metric row used by overview surfaces. Values keep their own tone so a
/// non-zero problem count reads as a problem instead of plain black text.
class AppMetricGrid extends StatelessWidget {
  const AppMetricGrid({super.key, required this.metrics});

  final List<AppMetric> metrics;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var index = 0; index < metrics.length; index++) ...[
        if (index > 0) const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                metrics[index].value,
                style: AppType.metric.copyWith(
                  color: metrics[index].tone == AppTone.neutral
                      ? Theme.of(context).colorScheme.onSurface
                      : metrics[index].tone.color(context),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                metrics[index].label,
                style: AppType.rowSubtitle.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
            ],
          ),
        ),
      ],
    ],
  );
}

/// Primary call to action. One per screen.
class AppPrimaryButton extends StatelessWidget {
  const AppPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: CupertinoColors.white),
          const SizedBox(width: AppSpacing.xs),
        ],
        Text(
          label,
          style: const TextStyle(
            color: CupertinoColors.white,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );

    return Opacity(
      opacity: enabled ? 1 : AppOpacity.disabled,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: SizedBox(
          width: expand ? double.infinity : null,
          height: AppSizes.primaryButton,
          child: CupertinoButton(
            padding: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(AppRadii.medium),
            color: context.appPrimary,
            onPressed: onPressed,
            child: content,
          ),
        ),
      ),
    );
  }
}

/// Secondary action rendered as a quiet, tonal pill.
class AppSecondaryButton extends StatelessWidget {
  const AppSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : AppOpacity.disabled,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          minimumSize: const Size(0, AppSpacing.control),
          borderRadius: BorderRadius.circular(AppRadii.medium),
          color: context.appPrimary.withValues(alpha: 0.12),
          onPressed: onPressed,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: context.appPrimary),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: context.appPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Vertical action stack used by empty, error and blocking states.
///
/// Actions share one width so a short label like「重试」never renders as a
/// stubby, disproportionate pill next to a plain text link.
class AppActionStack extends StatelessWidget {
  const AppActionStack({
    super.key,
    this.primary,
    this.secondary,
    this.maxWidth = 320,
  });

  final Widget? primary;
  final Widget? secondary;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (primary == null && secondary == null) return const SizedBox.shrink();
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?primary,
            if (primary != null && secondary != null)
              const SizedBox(height: AppSpacing.sm),
            ?secondary,
          ],
        ),
      ),
    );
  }
}

/// Label/value row used inside forms and detail sheets.
///
/// The label column is a fixed width so values line up across every row — the
/// misalignment seen on the WebDAV screen came from sizing labels ad hoc.
class AppFormRow extends StatelessWidget {
  const AppFormRow({
    super.key,
    required this.label,
    this.value,
    this.child,
    this.errorText,
    this.trailing,
    this.onTap,
  });

  final String label;
  final String? value;
  final Widget? child;
  final String? errorText;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.rowHorizontal,
        vertical: AppSpacing.rowVertical,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: AppSpacing.labelColumn,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                label,
                style: AppType.rowTitle.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
          Expanded(
            child:
                child ??
                (value == null
                    ? const SizedBox.shrink()
                    : Text(
                        value!,
                        style: AppType.rowTitle.copyWith(
                          color: context.appSecondaryLabel,
                          fontWeight: FontWeight.w400,
                        ),
                      )),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.xs),
            trailing!,
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onTap == null)
          content
        else
          CupertinoButton(
            padding: EdgeInsets.zero,
            pressedOpacity: 0.6,
            onPressed: onTap,
            child: content,
          ),
        if (errorText != null && errorText!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.rowHorizontal + AppSpacing.labelColumn,
              0,
              AppSpacing.rowHorizontal,
              AppSpacing.xs,
            ),
            child: Text(
              errorText!,
              style: AppType.rowSubtitle.copyWith(color: context.appDanger),
            ),
          ),
      ],
    );
  }
}

/// Inset segmented control used by the sync profile workspace.
///
/// Hand-rolled so the control keeps the same rhythm on Cupertino and Material,
/// and so 5 segments stay readable without the platform widgets squeezing the
/// labels into ellipses.
class AppSegmentedTabs extends StatelessWidget {
  const AppSegmentedTabs({
    super.key,
    required this.tabs,
    required this.index,
    required this.onChanged,
  });

  final List<String> tabs;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // In dark mode the grouped surface is black, which would make the selected
    // segment disappear against the track — use a light overlay instead.
    final selectedColor = isDark
        ? CupertinoColors.white.withValues(alpha: 0.22)
        : context.appGroupedSurface;
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isApplePlatform(context)
            ? CupertinoColors.tertiarySystemFill.resolveFrom(context)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadii.medium),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == index,
                label: tabs[i],
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(i),
                  child: AnimatedContainer(
                    duration: AppMotion.quick,
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == index ? selectedColor : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadii.small),
                      boxShadow: i == index && !isDark
                          ? [
                              BoxShadow(
                                color: CupertinoColors.black.withValues(
                                  alpha: 0.10,
                                ),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      tabs[i],
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: AppType.rowSubtitle.copyWith(
                        fontSize: 13,
                        fontWeight: i == index
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: i == index
                            ? Theme.of(context).colorScheme.onSurface
                            : context.appSecondaryLabel,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class AppDetailSheetRow {
  const AppDetailSheetRow({
    required this.label,
    required this.value,
    this.tone = AppTone.neutral,
    this.monospace = false,
  });

  final String label;
  final String value;
  final AppTone tone;
  final bool monospace;
}

/// Bottom sheet used for read-only record details (history entry, technical
/// detail). Keeps raw codes out of the list while staying reachable.
Future<void> showAppDetailSheet(
  BuildContext context, {
  required String title,
  required List<AppDetailSheetRow> rows,
  String? footnote,
  String closeLabel = '关闭',
}) {
  final content = _AppDetailSheetBody(
    title: title,
    rows: rows,
    footnote: footnote,
    closeLabel: closeLabel,
  );
  if (isApplePlatform(context)) {
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => content,
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.appElevatedSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.sheet)),
    ),
    builder: (context) => content,
  );
}

class _AppDetailSheetBody extends StatelessWidget {
  const _AppDetailSheetBody({
    required this.title,
    required this.rows,
    required this.closeLabel,
    this.footnote,
  });

  final String title;
  final List<AppDetailSheetRow> rows;
  final String closeLabel;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: height * 0.82),
      decoration: BoxDecoration(
        color: context.appElevatedSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheet),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: context.appSeparator,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                title,
                style: AppType.cardTitle.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              for (final row in rows) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: AppSpacing.labelColumn,
                        child: Text(
                          row.label,
                          style: AppType.rowSubtitle.copyWith(
                            color: context.appSecondaryLabel,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          row.value,
                          style: (row.monospace ? AppType.mono : AppType.body)
                              .copyWith(
                                color: row.tone == AppTone.neutral
                                    ? Theme.of(context).colorScheme.onSurface
                                    : row.tone.color(context),
                                fontWeight: row.tone == AppTone.neutral
                                    ? FontWeight.w400
                                    : FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (footnote != null && footnote!.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  footnote!,
                  style: AppType.footnote.copyWith(
                    color: context.appSecondaryLabel,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                width: double.infinity,
                child: AppPrimaryButton(
                  label: closeLabel,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small disclosure used to reveal technical detail inline.
class AppDetailDisclosure extends StatefulWidget {
  const AppDetailDisclosure({
    super.key,
    this.label = '技术详情',
    required this.detail,
  });

  final String label;
  final String detail;

  @override
  State<AppDetailDisclosure> createState() => _AppDetailDisclosureState();
}

class _AppDetailDisclosureState extends State<AppDetailDisclosure> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(0, AppSpacing.control),
        onPressed: () => setState(() => _expanded = !_expanded),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _expanded
                  ? CupertinoIcons.chevron_up
                  : CupertinoIcons.chevron_down,
              size: 14,
              color: context.appPrimary,
            ),
            const SizedBox(width: 4),
            Text(
              widget.label,
              style: AppType.rowSubtitle.copyWith(
                color: context.appPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      if (_expanded)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: AppSpacing.xs),
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: context.appPageBackground,
            borderRadius: BorderRadius.circular(AppRadii.medium),
            border: Border.all(
              color: context.appSeparator.withValues(
                alpha: AppOpacity.groupedBorder,
              ),
            ),
          ),
          child: SelectableText(
            widget.detail,
            style: AppType.mono.copyWith(color: context.appSecondaryLabel),
          ),
        ),
    ],
  );
}

/// Copy-to-clipboard helper used by detail sheets and disclosures.
Future<void> copyAppText(
  BuildContext context,
  String value,
  String message,
) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }
}
