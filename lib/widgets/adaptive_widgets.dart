import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';

import '../appearance/design_tokens.dart';
import 'app_components.dart';
import 'common_widgets.dart';

IconData adaptiveIcon(
  BuildContext context, {
  required IconData material,
  required IconData cupertino,
}) => isApplePlatform(context) ? cupertino : material;

class AdaptiveSliverScaffold extends StatelessWidget {
  const AdaptiveSliverScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.actions = const [],
    this.floatingActionButton,
    this.onRefresh,
    this.useLargeTitle = true,
    this.showTitle = true,
  });

  final String title;
  final List<Widget> slivers;
  final List<Widget> actions;
  final Widget? floatingActionButton;
  final Future<void> Function()? onRefresh;
  final bool useLargeTitle;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    if (isApplePlatform(context)) {
      final trailing = actions.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: actions);
      final useExpandedTitle = showTitle && useLargeTitle;
      return CupertinoPageScaffold(
        backgroundColor: context.appPageBackground,
        child: Material(
          type: MaterialType.transparency,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              useExpandedTitle
                  ? CupertinoSliverNavigationBar(
                      largeTitle: Text(title),
                      trailing: trailing,
                      backgroundColor: CupertinoColors.systemGroupedBackground,
                      transitionBetweenRoutes: false,
                    )
                  : SliverPersistentHeader(
                      pinned: true,
                      delegate: _CompactCupertinoTopBarDelegate(
                        title: showTitle ? title : null,
                        actions: actions,
                        topPadding: MediaQuery.paddingOf(context).top,
                      ),
                    ),
              if (onRefresh != null)
                CupertinoSliverRefreshControl(onRefresh: onRefresh),
              ...slivers,
              const SliverPadding(
                padding: EdgeInsets.only(bottom: AppSpacing.xl + 50),
              ),
            ],
          ),
        ),
      );
    }

    final scrollView = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        showTitle && useLargeTitle
            ? SliverAppBar.large(
                title: Text(title),
                pinned: true,
                actions: actions,
                backgroundColor: context.appPageBackground,
                surfaceTintColor: Colors.transparent,
              )
            : SliverAppBar(
                title: showTitle ? Text(title) : null,
                pinned: true,
                actions: actions,
                backgroundColor: context.appPageBackground,
                surfaceTintColor: Colors.transparent,
              ),
        ...slivers,
        const SliverPadding(
          padding: EdgeInsets.only(bottom: AppSpacing.xl + 72),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: context.appPageBackground,
      body: onRefresh == null
          ? scrollView
          : RefreshIndicator(onRefresh: onRefresh!, child: scrollView),
      floatingActionButton: floatingActionButton,
    );
  }
}

/// Pinned, translucent top bar used by secondary Cupertino pages.
///
/// It stays on screen while the page scrolls so grouped content never slides
/// under the status bar (the previous implementation scrolled away with the
/// list, which made scrolled headers collide with the clock).
class _CompactCupertinoTopBarDelegate extends SliverPersistentHeaderDelegate {
  _CompactCupertinoTopBarDelegate({
    required this.title,
    required this.actions,
    required this.topPadding,
  });

  final String? title;
  final List<Widget> actions;
  final double topPadding;

  double get _height => topPadding + 44;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final showRule = overlapsContent;
    return SizedBox(
      height: _height,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: CupertinoColors.systemGroupedBackground
                  .resolveFrom(context)
                  .withValues(alpha: overlapsContent ? 0.86 : 1),
              border: Border(
                bottom: BorderSide(
                  color: showRule
                      ? CupertinoColors.separator.resolveFrom(context)
                      : CupertinoColors.separator
                            .resolveFrom(context)
                            .withValues(alpha: 0),
                  width: 0.5,
                ),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.only(top: topPadding, left: 8, right: 8),
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    if (title != null)
                      Expanded(
                        child: Text(
                          title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CupertinoTheme.of(
                            context,
                          ).textTheme.navTitleTextStyle,
                        ),
                      )
                    else
                      const Spacer(),
                    if (actions.isNotEmpty)
                      Row(mainAxisSize: MainAxisSize.min, children: actions),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _CompactCupertinoTopBarDelegate oldDelegate) =>
      oldDelegate.title != title ||
      oldDelegate.actions != actions ||
      oldDelegate.topPadding != topPadding;
}

class AdaptiveScaffold extends StatelessWidget {
  const AdaptiveScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.floatingActionButton,
    this.leading,
    this.showTitle = true,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? floatingActionButton;
  final Widget? leading;
  final bool showTitle;

  @override
  Widget build(BuildContext context) => PlatformScaffold(
    backgroundColor: context.appPageBackground,
    // CupertinoPageScaffold already lays the body out below its navigation
    // bar. Adding the navigation-bar height again here creates the large
    // empty band visible on every pushed page.
    iosContentPadding: false,
    appBar: WDAppBar(
      title: Text(title),
      showTitle: showTitle,
      trailingActions: actions,
      leading: leading,
    ),
    body: body,
    material: (_, _) =>
        MaterialScaffoldData(floatingActionButton: floatingActionButton),
  );
}

class AdaptiveListSection extends StatelessWidget {
  const AdaptiveListSection({
    super.key,
    required this.children,
    this.header,
    this.headerTrailing,
    this.footer,
    this.topPadding = AppSpacing.xs,
  });

  final String? header;
  final Widget? headerTrailing;
  final Widget? footer;
  final List<Widget> children;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.page,
        topPadding,
        AppSpacing.page,
        AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sectionHeaderGap),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      header!,
                      style: AppType.caption.copyWith(
                        color: context.appSecondaryLabel,
                      ),
                    ),
                  ),
                  if (headerTrailing != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    headerTrailing!,
                  ],
                ],
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: context.appGroupedSurface,
              borderRadius: BorderRadius.circular(AppRadii.large),
              border: Border.all(
                color: context.appSeparator.withValues(
                  alpha: AppOpacity.groupedBorder,
                ),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.large),
              child: Material(
                type: MaterialType.transparency,
                child: Column(children: _withDividers(context, children)),
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, AppSpacing.xs, 0, 0),
              child: DefaultTextStyle(
                style: Theme.of(context).textTheme.bodySmall!.copyWith(
                  color: context.appSecondaryLabel,
                  height: 1.35,
                ),
                child: footer!,
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _withDividers(BuildContext context, List<Widget> items) {
    return [
      for (var index = 0; index < items.length; index++) ...[
        items[index],
        if (index != items.length - 1)
          Container(
            height: 0.5,
            color: context.appSeparator.withValues(
              alpha: AppOpacity.groupedDivider,
            ),
          ),
      ],
    ];
  }
}

class AdaptiveListTile extends StatelessWidget {
  const AdaptiveListTile({
    super.key,
    this.widgetKey,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.additionalInfo,
    this.onTap,
    this.enabled = true,
    this.showChevron = false,
    this.isThreeLine = false,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.rowHorizontal,
      vertical: AppSpacing.rowVertical,
    ),
    this.leadingSize = AppSizes.listLeading,
    this.leadingToTitle = AppSpacing.rowLeadingGap,
  });

  final Key? widgetKey;
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? additionalInfo;
  final VoidCallback? onTap;
  final bool enabled;
  final bool showChevron;
  final bool isThreeLine;
  final EdgeInsetsGeometry contentPadding;
  final double leadingSize;
  final double leadingToTitle;

  @override
  Widget build(BuildContext context) {
    final chevron = showChevron && onTap != null
        ? (isApplePlatform(context)
              ? const CupertinoListTileChevron()
              : const Icon(Icons.chevron_right_rounded))
        : null;

    if (isApplePlatform(context)) {
      return Opacity(
        opacity: enabled ? 1 : 0.45,
        child: CupertinoListTile(
          key: widgetKey,
          title: title,
          subtitle: subtitle,
          leading: leading,
          trailing: trailing ?? chevron,
          additionalInfo: additionalInfo,
          padding: contentPadding,
          leadingSize: leadingSize,
          leadingToTitle: leadingToTitle,
          onTap: enabled ? onTap : null,
        ),
      );
    }

    final materialTrailing =
        trailing ??
        (additionalInfo == null && chevron == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?additionalInfo,
                  if (additionalInfo != null && chevron != null)
                    const SizedBox(width: AppSpacing.xs),
                  ?chevron,
                ],
              ));

    return ListTile(
      key: widgetKey,
      title: title,
      subtitle: subtitle,
      leading: leading,
      trailing: materialTrailing,
      enabled: enabled,
      onTap: onTap,
      isThreeLine: isThreeLine,
      contentPadding: contentPadding,
      minVerticalPadding: 0,
      horizontalTitleGap: leadingToTitle,
    );
  }
}

class AdaptiveSwitchListTile extends StatelessWidget {
  const AdaptiveSwitchListTile({
    super.key,
    this.widgetKey,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final Key? widgetKey;
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    if (isApplePlatform(context)) {
      return CupertinoListTile(
        key: widgetKey,
        title: title,
        subtitle: subtitle,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.rowHorizontal,
          vertical: AppSpacing.rowVertical,
        ),
        leadingSize: AppSizes.listLeading,
        leadingToTitle: AppSpacing.rowLeadingGap,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: CupertinoSwitch(value: value, onChanged: onChanged),
      );
    }
    return SwitchListTile.adaptive(
      key: widgetKey,
      title: title,
      subtitle: subtitle,
      value: value,
      onChanged: onChanged,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.rowHorizontal,
        vertical: AppSpacing.rowVertical,
      ),
      minVerticalPadding: 0,
    );
  }
}

class AdaptiveIconButton extends StatelessWidget {
  const AdaptiveIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (isApplePlatform(context)) {
      final button = CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size.square(AppSizes.listAction),
        onPressed: onPressed,
        child: icon,
      );
      return tooltip == null
          ? button
          : Semantics(label: tooltip, child: button);
    }
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: icon,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(
        width: AppSizes.listAction,
        height: AppSizes.listAction,
      ),
    );
  }
}

class AdaptiveIconBadge extends StatelessWidget {
  const AdaptiveIconBadge({
    super.key,
    required this.icon,
    this.color,
    this.size = 40,
  });

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ?? context.appPrimary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: resolvedColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.small),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.52, color: resolvedColor),
    );
  }
}

/// Status pill.
///
/// Prefer [tone]: the semantic tone is what keeps "已启用" green and
/// "需处理" orange instead of letting both render in the same warning色.
class AdaptiveStatusBadge extends StatelessWidget {
  const AdaptiveStatusBadge({
    super.key,
    required this.label,
    this.tone,
    this.color,
    this.icon,
  }) : assert(tone != null || color != null, 'Provide a tone or a color');

  final String label;
  final AppTone? tone;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final resolved = tone?.color(context) ?? color!;
    return Container(
      constraints: const BoxConstraints(minHeight: AppSizes.statusBadge),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tone?.surface(context) ?? resolved.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: resolved),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: resolved,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps a row's trailing controls on one predictable rhythm.
class AdaptiveTrailingGroup extends StatelessWidget {
  const AdaptiveTrailingGroup({
    super.key,
    required this.children,
    this.gap = AppSpacing.rowActionGap,
  });

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      for (var index = 0; index < children.length; index++) ...[
        if (index > 0) SizedBox(width: gap),
        children[index],
      ],
    ],
  );
}

class AdaptiveSummaryMetric {
  const AdaptiveSummaryMetric({required this.value, required this.label});

  final String value;
  final String label;
}

/// One quiet, reusable summary surface for dashboard-like pages.
class AdaptiveSummaryCard extends StatelessWidget {
  const AdaptiveSummaryCard({
    super.key,
    required this.icon,
    required this.color,
    required this.eyebrow,
    required this.title,
    required this.metrics,
    this.status,
  });

  final IconData icon;
  final Color color;
  final String eyebrow;
  final String title;
  final List<AdaptiveSummaryMetric> metrics;
  final AdaptiveStatusBadge? status;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(
      AppSpacing.md,
      AppSpacing.page,
      AppSpacing.page,
      AppSpacing.xs,
    ),
    padding: const EdgeInsets.all(AppSpacing.sm),
    decoration: BoxDecoration(
      color: context.appGroupedSurface,
      borderRadius: BorderRadius.circular(AppRadii.large),
      border: Border.all(
        color: context.appSeparator.withValues(alpha: AppOpacity.groupedBorder),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            AdaptiveIconBadge(icon: icon, color: color, size: 36),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    eyebrow,
                    style: TextStyle(
                      color: context.appSecondaryLabel,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            ?status,
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            for (var index = 0; index < metrics.length; index++) ...[
              if (index > 0) const SizedBox(width: AppSpacing.sm),
              Expanded(child: _SummaryMetric(metric: metrics[index])),
            ],
          ],
        ),
      ],
    ),
  );
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({required this.metric});

  final AdaptiveSummaryMetric metric;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        metric.value,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          height: 1.05,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        metric.label,
        style: TextStyle(
          color: context.appSecondaryLabel,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    ],
  );
}

class AdaptiveEmptyState extends StatelessWidget {
  const AdaptiveEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.secondaryAction,
    this.tone = AppTone.brand,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final Widget? secondaryAction;
  final AppTone tone;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: tone.surface(context),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 30,
                color: tone.color(context),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: isApplePlatform(context)
                  ? CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    )
                  : Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.appSecondaryLabel, height: 1.4),
            ),
            if (action != null || secondaryAction != null) ...[
              const SizedBox(height: AppSpacing.md),
              AppActionStack(primary: action, secondary: secondaryAction),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Friendly, full-page error presentation.
///
/// The primary message stays human-readable; raw exception text is collapsed
/// behind an optional details panel so a failed request never replaces the
/// page with a wall of stack-trace text.
class AdaptiveErrorState extends StatefulWidget {
  const AdaptiveErrorState({
    super.key,
    required this.message,
    required this.onRetry,
    this.title = '暂时无法加载',
    this.details,
    this.retryLabel = '重试',
    this.secondaryAction,
  });

  final String title;
  final String message;
  final String? details;
  final String retryLabel;
  final VoidCallback onRetry;
  final Widget? secondaryAction;

  @override
  State<AdaptiveErrorState> createState() => _AdaptiveErrorStateState();
}

class _AdaptiveErrorStateState extends State<AdaptiveErrorState> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final errorColor = isApplePlatform(context)
        ? CupertinoColors.systemRed.resolveFrom(context)
        : Theme.of(context).colorScheme.error;
    final titleStyle = isApplePlatform(context)
        ? CupertinoTheme.of(context).textTheme.textStyle.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w600,
          )
        : Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600);
    final details = widget.details?.trim();

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: errorColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  adaptiveIcon(
                    context,
                    material: Icons.cloud_off_outlined,
                    cupertino: CupertinoIcons.exclamationmark_triangle,
                  ),
                  size: 30,
                  color: errorColor,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: titleStyle,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                widget.message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.appSecondaryLabel,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              // Match the message column width so the buttons line up with the
              // copy instead of floating as a narrower block inside it.
              AppActionStack(
                maxWidth: 420 - AppSpacing.xl * 2,
                primary: AppPrimaryButton(
                  label: widget.retryLabel,
                  onPressed: widget.onRetry,
                ),
                secondary: widget.secondaryAction,
              ),
              if (details != null && details.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                TextButton.icon(
                  onPressed: () => setState(() => _showDetails = !_showDetails),
                  icon: Icon(
                    _showDetails
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                  ),
                  label: Text(_showDetails ? '收起错误详情' : '查看错误详情'),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  alignment: Alignment.topCenter,
                  child: _showDetails
                      ? _ErrorDetailsPanel(details: details)
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorDetailsPanel extends StatelessWidget {
  const _ErrorDetailsPanel({required this.details});

  final String details;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: context.appGroupedSurface,
        borderRadius: BorderRadius.circular(AppRadii.medium),
        border: Border.all(
          color: context.appSeparator.withValues(
            alpha: AppOpacity.groupedBorder,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '技术详情',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.appSecondaryLabel,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: details));
                  if (context.mounted) {
                    showPlatformMessage(context, '错误详情已复制。');
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xxs),
          SelectableText(
            details,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11.5,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class AdaptiveLoadingState extends StatelessWidget {
  const AdaptiveLoadingState({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      label: label,
      child: isApplePlatform(context)
          ? const CupertinoActivityIndicator(radius: 14)
          : const CircularProgressIndicator(),
    ),
  );
}

class AdaptiveActionItem<T> {
  const AdaptiveActionItem({
    required this.value,
    required this.label,
    this.icon,
    this.isDestructive = false,
    this.enabled = true,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool isDestructive;
  final bool enabled;
}

class AdaptiveActionMenu<T> extends StatelessWidget {
  const AdaptiveActionMenu({
    super.key,
    required this.items,
    required this.onSelected,
    this.tooltip = '更多操作',
    this.enabled = true,
    this.icon,
  });

  final List<AdaptiveActionItem<T>> items;
  final ValueChanged<T> onSelected;
  final String tooltip;
  final bool enabled;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    if (isApplePlatform(context)) {
      return Semantics(
        label: tooltip,
        button: true,
        child: ExcludeSemantics(
          child: CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size.square(AppSizes.listAction),
            onPressed: enabled ? () => _showCupertinoActions(context) : null,
            child: icon ?? const Icon(CupertinoIcons.ellipsis_circle),
          ),
        ),
      );
    }
    return SizedBox.square(
      dimension: AppSizes.listAction,
      child: PopupMenuButton<T>(
        tooltip: tooltip,
        enabled: enabled,
        icon: icon ?? const Icon(Icons.more_horiz_rounded),
        padding: EdgeInsets.zero,
        iconSize: 22,
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final item in items)
            PopupMenuItem<T>(
              value: item.value,
              enabled: item.enabled,
              child: Row(
                children: [
                  if (item.icon != null) ...[
                    Icon(
                      item.icon,
                      size: 20,
                      color: item.isDestructive
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  Text(
                    item.label,
                    style: item.isDestructive
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showCupertinoActions(BuildContext context) async {
    final selected = await showCupertinoModalPopup<T>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          for (final item in items.where((item) => item.enabled))
            CupertinoActionSheetAction(
              isDestructiveAction: item.isDestructive,
              onPressed: () => Navigator.of(sheetContext).pop(item.value),
              child: Text(item.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected != null) onSelected(selected);
  }
}

Future<bool> showAdaptiveConfirmation(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = '取消',
  bool isDestructive = false,
}) async {
  if (isApplePlatform(context)) {
    return await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(cancelLabel),
              ),
              CupertinoDialogAction(
                isDestructiveAction: isDestructive,
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(cancelLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: isDestructive
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    )
                  : null,
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;
}

void showAdaptiveBlockingProgress(
  BuildContext context, {
  required String message,
  Key? key,
}) {
  if (isApplePlatform(context)) {
    unawaited(
      showCupertinoDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: CupertinoAlertDialog(
            key: key,
            content: Column(
              children: [
                const CupertinoActivityIndicator(radius: 14),
                const SizedBox(height: AppSpacing.md),
                Text(message),
              ],
            ),
          ),
        ),
      ),
    );
    return;
  }

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          key: key,
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: AppSpacing.md),
              Text(message),
            ],
          ),
        ),
      ),
    ),
  );
}
