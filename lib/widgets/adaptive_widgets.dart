import 'package:velock_sync/l10n/sync_locale.dart';
import 'dart:ui' show ImageFilter;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../appearance/design_tokens.dart';
import 'adaptive_dialogs.dart';
import 'automation_id.dart';
import 'app_components.dart';
import 'common_widgets.dart';

export 'adaptive_dialogs.dart'
    show showAdaptiveConfirmation, showAdaptiveNotice;

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
    final backButton = ModalRoute.of(context)?.canPop == true
        ? AppBackButton(onPressed: () => Navigator.of(context).maybePop())
        : null;
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
                      automaticallyImplyLeading: false,
                      leading: backButton,
                      padding: backButton == null
                          ? null
                          : const EdgeInsetsDirectional.only(
                              start: AppBackButton.headerInset,
                              end: AppSpacing.page,
                            ),
                      largeTitle: Text(title),
                      trailing: trailing,
                      backgroundColor: CupertinoColors.systemGroupedBackground,
                      transitionBetweenRoutes: false,
                    )
                  : SliverPersistentHeader(
                      pinned: true,
                      delegate: _CompactCupertinoTopBarDelegate(
                        leading: backButton,
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
                automaticallyImplyLeading: false,
                leading: backButton,
                leadingWidth: backButton == null
                    ? null
                    : AppBackButton.touchTargetSize,
                title: Text(title),
                pinned: true,
                actions: actions,
                backgroundColor: context.appPageBackground,
                surfaceTintColor: Colors.transparent,
              )
            : SliverAppBar(
                automaticallyImplyLeading: false,
                leading: backButton,
                leadingWidth: backButton == null
                    ? null
                    : AppBackButton.touchTargetSize,
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
    this.leading,
    required this.title,
    required this.actions,
    required this.topPadding,
  });

  final Widget? leading;
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
              padding: EdgeInsetsDirectional.only(
                top: topPadding,
                start: leading is AppBackButton ? AppBackButton.headerInset : 8,
                // The back button is already a 44pt touch target whose ink sits
                // at the page edge; adding the usual 8pt gap after it made the
                // leading slot 52pt wide and overflowed the navigation bar (the
                // debug stripes) for some fonts and text scales.
                end: leading is AppBackButton ? 0 : 8,
              ),
              child: ConstrainedBox(
                // A minimum height, not a fixed one: at accessibility text
                // sizes a 17pt title needs more than 44pt and used to be
                // clipped, and long titles were ellipsised where the user most
                // needs to know where they are.
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(
                  children: [
                    ?leading,
                    if (title != null)
                      Expanded(
                        child: Text(
                          title!,
                          // Two lines, so a long title or a large accessibility
                          // text size still tells the user where they are.
                          maxLines: 2,
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
      oldDelegate.leading != leading ||
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
  Widget build(BuildContext context) => AdaptivePageScaffold(
    appBar: WDAppBar(
      title: Text(title),
      showTitle: showTitle,
      trailingActions: actions,
      leading: leading,
    ),
    body: body,
    floatingActionButton: floatingActionButton,
  );
}

/// A page shell that picks the platform's own scaffold and navigation bar.
///
/// Replaces `flutter_platform_widgets`' `PlatformScaffold` (discontinued
/// upstream). `CupertinoPageScaffold` already lays the body out below its
/// navigation bar — adding the bar height again produced the large empty band
/// that used to show on every pushed page, so no extra inset is applied.
class AdaptivePageScaffold extends StatelessWidget {
  const AdaptivePageScaffold({
    super.key,
    required this.appBar,
    required this.body,
    this.backgroundColor,
    this.floatingActionButton,
    this.resizeToAvoidBottomInset,
  });

  final WDAppBar appBar;
  final Widget body;
  final Color? backgroundColor;
  final Widget? floatingActionButton;
  final bool? resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    final background = backgroundColor ?? context.appPageBackground;
    if (isApplePlatform(context)) {
      return CupertinoPageScaffold(
        backgroundColor: background,
        navigationBar: appBar,
        // Unlike CupertinoApp, MaterialApp supplies a diagnostic text style.
        // CupertinoPageScaffold does not replace it for its body.
        child: DefaultTextStyle(
          style: CupertinoTheme.of(context).textTheme.textStyle,
          child: body,
        ),
      );
    }
    return Scaffold(
      backgroundColor: background,
      appBar: appBar,
      body: body,
      floatingActionButton: floatingActionButton,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    );
  }
}

/// The bottom tab shell for the three product entries.
///
/// The bar itself is the platform's own widget; the page content is the router
/// shell, so no nested navigator is introduced (that would break the shell
/// routes).
class AdaptiveTabScaffold extends StatelessWidget {
  const AdaptiveTabScaffold({
    super.key,
    required this.body,
    required this.items,
    required this.currentIndex,
    required this.onChanged,
  });

  final Widget body;
  final List<BottomNavigationBarItem> items;
  final int currentIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    if (isApplePlatform(context)) {
      return CupertinoPageScaffold(
        backgroundColor: context.appPageBackground,
        child: Column(
          children: [
            Expanded(
              child: DefaultTextStyle(
                style: CupertinoTheme.of(context).textTheme.textStyle,
                child: body,
              ),
            ),
            CupertinoTabBar(
              items: items,
              currentIndex: currentIndex,
              onTap: onChanged,
              backgroundColor: context.appGroupedSurface,
              activeColor: context.appPrimary,
              inactiveColor: context.appSecondaryLabel,
              iconSize: 24,
            ),
          ],
        ),
      );
    }
    // Material 3's own NavigationBar, which is what this shell rendered before
    // the migration (it kept the same destinations, index and callback).
    return Scaffold(
      backgroundColor: context.appPageBackground,
      body: body,
      bottomNavigationBar: NavigationBar(
        destinations: [
          for (final item in items)
            NavigationDestination(
              icon: item.icon,
              selectedIcon: item.activeIcon,
              label: item.label ?? '',
              tooltip: item.tooltip,
            ),
        ],
        selectedIndex: currentIndex,
        onDestinationSelected: onChanged,
        backgroundColor: context.appGroupedSurface,
        elevation: 2,
      ),
    );
  }
}

class AdaptiveListSection extends StatelessWidget {
  const AdaptiveListSection({
    super.key,
    required this.children,
    this.header,
    this.headerTrailing,
    this.headerDetail,
    this.emptyContent,
    this.footer,
    this.topPadding = AppSpacing.xs,
  });

  final String? header;
  final Widget? headerTrailing;

  /// Optional state line rendered directly under the header.
  ///
  /// Section-level state (is this domain on? what happened last?) belongs to
  /// the header, not to the grouped surface below: a status is not a list item,
  /// so it must not sit in the same card, dividers and row rhythm as the
  /// entries and records the user can actually open.
  final Widget? headerDetail;

  /// Rendered instead of the grouped surface while [children] is empty.
  ///
  /// An empty domain is not a list yet: reusing the grouped row surface made
  /// 「新建文件夹同步」look like an item that already exists, so sections hand in
  /// a single action instead. Sections without one keep collapsing as before.
  final Widget? emptyContent;
  final Widget? footer;
  final List<Widget> children;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty && emptyContent == null) {
      return const SizedBox.shrink();
    }

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
          if (header != null || headerDetail != null)
            Padding(
              padding: const EdgeInsets.only(
                bottom: AppSpacing.sectionHeaderGap,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (header != null)
                    Row(
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
                  if (headerDetail != null) ...[
                    if (header != null)
                      const SizedBox(height: AppSpacing.xxs + 2),
                    headerDetail!,
                  ],
                ],
              ),
            ),
          if (children.isEmpty)
            emptyContent!
          else
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
              // Full width so a caller can centre its footnote (empty domains
              // centre the action and the sentence under it).
              child: SizedBox(
                width: double.infinity,
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.bodySmall!.copyWith(
                    color: context.appSecondaryLabel,
                    height: 1.35,
                  ),
                  child: footer!,
                ),
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

/// Runs a row callback without handing its future to the widget that owns the
/// pressed highlight.
///
/// `CupertinoListTile` clears its highlight only after `await widget.onTap!()`
/// resolves (`list_tile.dart`). Rows here start routes (`context.push`) and
/// async saves whose futures belong to the router or the page — never to the
/// row. Passing them through kept the row grey until that future finished, or
/// forever when it never did: a route dropped by `go()` instead of popped, or
/// an async save that throws. The callback still runs, its result is just not
/// what decides whether the row springs back.
VoidCallback? _rowTapHandler(VoidCallback? callback) => callback == null
    ? null
    : () {
        callback();
      };

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

    final tapHandler = _rowTapHandler(onTap);

    if (isApplePlatform(context)) {
      return withAutomationId(
        widgetKey,
        Opacity(
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
            onTap: enabled ? tapHandler : null,
          ),
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

    return withAutomationId(
      widgetKey,
      ListTile(
        key: widgetKey,
        title: title,
        subtitle: subtitle,
        leading: leading,
        trailing: materialTrailing,
        enabled: enabled,
        onTap: tapHandler,
        isThreeLine: isThreeLine,
        contentPadding: contentPadding,
        minVerticalPadding: 0,
        horizontalTitleGap: leadingToTitle,
      ),
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
      return withAutomationId(
        widgetKey,
        CupertinoListTile(
          key: widgetKey,
          title: title,
          subtitle: subtitle,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.rowHorizontal,
            vertical: AppSpacing.rowVertical,
          ),
          leadingSize: AppSizes.listLeading,
          leadingToTitle: AppSpacing.rowLeadingGap,
          onTap: _rowTapHandler(
            onChanged == null ? null : () => onChanged!(!value),
          ),
          trailing: CupertinoSwitch(value: value, onChanged: onChanged),
        ),
      );
    }
    return withAutomationId(
      widgetKey,
      SwitchListTile.adaptive(
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
      ),
    );
  }
}

class AdaptiveIconButton extends StatelessWidget {
  const AdaptiveIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.materialIcon,
    this.tooltip,
    this.semanticLabel,
  });

  /// The Apple glyph. [materialIcon] is the Material one when the two design
  /// languages use different drawings (a pencil vs a filled pencil); it falls
  /// back to [icon] when they do not.
  final Widget icon;
  final Widget? materialIcon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => withAutomationId(key, _build(context));

  Widget _build(BuildContext context) {
    if (isApplePlatform(context)) {
      // A disabled CupertinoButton repaints its child with
      // `CupertinoColors.quaternaryLabel`, which strips the icon's own colour
      // (a green shield or a blue glyph turns grey). Keep the glyph as it is
      // and dim the whole control with opacity instead — that is what the
      // system does for inactive artwork.
      final button = CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size.square(AppSizes.listAction),
        onPressed: onPressed,
        child: onPressed == null
            ? Opacity(opacity: AppOpacity.disabled, child: icon)
            : icon,
      );
      final labelled = semanticLabel == null
          ? button
          : Semantics(label: semanticLabel, child: button);
      return tooltip == null
          ? labelled
          : Tooltip(message: tooltip!, child: labelled);
    }
    return IconButton(
      tooltip: tooltip ?? semanticLabel,
      onPressed: onPressed,
      icon: materialIcon ?? icon,
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
              child: Icon(icon, size: 30, color: tone.color(context)),
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
    this.title,
    this.details,
    this.retryLabel,
    this.secondaryAction,
  });

  final String? title;
  final String message;
  final String? details;
  final String? retryLabel;
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
                widget.title ?? syncText(context, '暂时无法加载', 'Unable to load'),
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
                  label: widget.retryLabel ?? syncText(context, '重试', 'Retry'),
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
                  label: Text(
                    _showDetails
                        ? syncText(context, '收起错误详情', 'Hide error details')
                        : syncText(context, '查看错误详情', 'Show error details'),
                  ),
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
                  syncText(context, '技术详情', 'Technical details'),
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
                    showPlatformMessage(
                      context,
                      syncText(context, '错误详情已复制。', 'Error details copied.'),
                    );
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: Text(syncText(context, '复制', 'Copy')),
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
    this.appleIcon,
    this.isDestructive = false,
    this.enabled = true,
  });

  final T value;
  final String label;
  final IconData? icon;

  /// Symbol in the Apple menu; falls back to [icon].
  final Widget? appleIcon;
  final bool isDestructive;
  final bool enabled;
}

class AdaptiveActionMenu<T> extends StatelessWidget {
  const AdaptiveActionMenu({
    super.key,
    required this.items,
    required this.onSelected,
    this.tooltip,
    this.enabled = true,
    this.icon,
  });

  final List<AdaptiveActionItem<T>> items;
  final ValueChanged<T> onSelected;
  final String? tooltip;
  final bool enabled;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    if (isApplePlatform(context)) {
      return Semantics(
        label: tooltip ?? syncText(context, '更多操作', 'More actions'),
        button: true,
        child: ExcludeSemantics(
          child: CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size.square(AppSizes.listAction),
            onPressed: enabled ? () => _showCupertinoActions(context) : null,
            // Same rule as AdaptiveIconButton: disabled artwork is faded, not
            // repainted grey by the button.
            child: Opacity(
              opacity: enabled ? 1 : AppOpacity.disabled,
              child: icon ?? const Icon(CupertinoIcons.ellipsis_circle),
            ),
          ),
        ),
      );
    }
    return SizedBox.square(
      dimension: AppSizes.listAction,
      child: PopupMenuButton<T>(
        tooltip: tooltip ?? syncText(context, '更多操作', 'More actions'),
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
    final selected = await showAdaptiveActionSheet<T>(
      context: context,
      title: tooltip,
      actions: [
        for (final item in items.where((item) => item.enabled))
          AdaptiveAction<T>(
            label: item.label,
            value: item.value,
            icon:
                item.appleIcon ?? (item.icon == null ? null : Icon(item.icon)),
            isDestructive: item.isDestructive,
          ),
      ],
    );
    if (selected != null) onSelected(selected);
  }
}

/// A text button that keeps the platform's own control.
///
/// Replaces `flutter_platform_widgets`' `PlatformTextButton` (discontinued
/// upstream). A disabled button dims its content instead of repainting it in the
/// system's disabled grey, matching the rule established for icons.
class AdaptiveTextButton extends StatelessWidget {
  const AdaptiveTextButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.padding = EdgeInsets.zero,
    this.textAlign,
    this.color,
    this.fontWeight,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final EdgeInsetsGeometry padding;
  final TextAlign? textAlign;
  final Color? color;
  final FontWeight? fontWeight;

  @override
  Widget build(BuildContext context) => withAutomationId(key, _build(context));

  Widget _build(BuildContext context) {
    // The label may be a Text or a composed row (icon + label); render it as it
    // is and only change colour/opacity, so nothing is re-laid out.
    final label = DefaultTextStyle.merge(
      style: TextStyle(
        color: color ?? context.appPrimary,
        fontWeight: fontWeight,
      ),
      child: child,
    );
    if (isApplePlatform(context)) {
      return CupertinoButton(
        padding: padding,
        minimumSize: Size.zero,
        onPressed: onPressed,
        child: onPressed == null
            ? Opacity(opacity: AppOpacity.disabled, child: label)
            : label,
      );
    }
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: padding,
        foregroundColor: color ?? context.appPrimary,
        textStyle: TextStyle(fontWeight: fontWeight),
        minimumSize: const Size(0, AppSizes.listAction),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: label,
    );
  }
}

/// A primary (filled) button for both platforms.
class AdaptiveElevatedButton extends StatelessWidget {
  const AdaptiveElevatedButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.padding,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => withAutomationId(key, _build(context));

  Widget _build(BuildContext context) {
    if (isApplePlatform(context)) {
      // Disabled keeps the fill and fades the whole button; the default grey
      // disabled fill left a white label on near-white.
      return Opacity(
        opacity: onPressed == null ? AppOpacity.disabled : 1,
        child: CupertinoButton.filled(
          padding: padding,
          disabledColor: CupertinoTheme.of(context).primaryColor,
          onPressed: onPressed,
          child: child,
        ),
      );
    }
    return ElevatedButton(
      onPressed: onPressed,
      style: padding == null
          ? null
          : ElevatedButton.styleFrom(padding: padding),
      child: child,
    );
  }
}

/// A switch that keeps the platform's own control.
class AdaptiveSwitch extends StatelessWidget {
  const AdaptiveSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) => withAutomationId(key, _build(context));

  Widget _build(BuildContext context) {
    if (isApplePlatform(context)) {
      return CupertinoSwitch(
        value: value,
        onChanged: onChanged,
        activeTrackColor: activeColor,
      );
    }
    return Switch(
      value: value,
      onChanged: onChanged,
      activeThumbColor: activeColor,
    );
  }
}

/// A progress indicator that keeps the platform's own control.
class AdaptiveSpinner extends StatelessWidget {
  const AdaptiveSpinner({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => isApplePlatform(context)
      ? const CupertinoActivityIndicator()
      : CircularProgressIndicator(padding: padding);
}

/// A labelled text field for both platforms.
///
/// One [label] serves both design languages: the Material branch uses it as the
/// floating label, the Apple branch as the row prefix. No call site has to
/// describe the same field twice, and long labels wrap instead of being
/// ellipsised.
class AdaptiveTextFormField extends StatelessWidget {
  const AdaptiveTextFormField({
    super.key,
    required this.label,
    required this.controller,
    this.validator,
    this.hint,
    this.obscureText = false,
    this.maxLines = 1,
    this.keyboardType,
    this.textInputAction,
    this.autocorrect,
    this.enableSuggestions,
    this.autofocus = false,
    this.enabled,
    this.onChanged,
    this.onFieldSubmitted,
    this.focusNode,
  });

  final String label;
  final TextEditingController controller;
  final FormFieldValidator<String>? validator;
  final String? hint;
  final bool obscureText;
  final int? maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool? autocorrect;
  final bool? enableSuggestions;
  final bool autofocus;
  final bool? enabled;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => withAutomationId(key, _build(context));

  Widget _build(BuildContext context) {
    if (isApplePlatform(context)) {
      return CupertinoTextFormFieldRow(
        controller: controller,
        validator: validator,
        placeholder: hint ?? label,
        obscureText: obscureText,
        maxLines: maxLines,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        autocorrect: autocorrect ?? true,
        enableSuggestions: enableSuggestions ?? true,
        autofocus: autofocus,
        enabled: enabled,
        onChanged: onChanged,
        onFieldSubmitted: onFieldSubmitted,
        focusNode: focusNode,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        prefix: AdaptiveFieldPrefix(label: label),
      );
    }
    return TextFormField(
      controller: controller,
      validator: validator,
      obscureText: obscureText,
      maxLines: maxLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autocorrect: autocorrect ?? true,
      enableSuggestions: enableSuggestions ?? true,
      autofocus: autofocus,
      enabled: enabled,
      onChanged: onChanged,
      onFieldSubmitted: onFieldSubmitted,
      focusNode: focusNode,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
  }
}

/// The label shown before an Apple-style form row.
///
/// A minimum width rather than a fixed one: the English labels ("Server
/// Address") are wider than the Chinese and used to overflow a hard 112pt box.
class AdaptiveFieldPrefix extends StatelessWidget {
  const AdaptiveFieldPrefix({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 112),
    child: Text(
      label,
      style: AppType.rowTitle.copyWith(color: context.appSecondaryLabel),
    ),
  );
}
