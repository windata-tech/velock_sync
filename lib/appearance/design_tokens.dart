import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Small, platform-neutral design primitives used by the adaptive UI layer.
///
/// The app deliberately keeps these values quiet and system-like. Platform
/// widgets still own typography, motion, controls and navigation behavior.
abstract final class AppColors {
  static const brand = Color(0xFF3F63D9);
  static const brandDark = Color(0xFF9DB2FF);

  static const success = Color(0xFF1E8E4E);
  static const successDark = Color(0xFF4CD07D);

  static const warning = Color(0xFFB26A00);
  static const warningDark = Color(0xFFFFB95E);

  static const danger = Color(0xFFC62828);
  static const dangerDark = Color(0xFFFF6B6B);
}

/// Semantic meaning of a status or emphasis. Colors are derived from the tone
/// so a status can never be rendered with a contradicting palette.
///
/// [ok] covers healthy/positive states (enabled, connected, completed).
/// [attention] covers states the user should look at but that are not broken.
/// [danger] covers failures and destructive affordances.
/// [brand] is reserved for tappable/brand emphasis.
/// [neutral] is for inactive or unavailable states.
enum AppTone { ok, attention, danger, neutral, brand }

extension AppToneColor on AppTone {
  Color color(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isApplePlatform(context)) {
      return switch (this) {
        AppTone.ok => AppColors.success,
        AppTone.attention => AppColors.warning,
        AppTone.danger => CupertinoColors.systemRed.resolveFrom(context),
        AppTone.neutral => CupertinoColors.secondaryLabel.resolveFrom(context),
        AppTone.brand => context.appPrimary,
      };
    }
    return switch (this) {
      AppTone.ok => isDark ? AppColors.successDark : AppColors.success,
      AppTone.attention => isDark ? AppColors.warningDark : AppColors.warning,
      AppTone.danger => isDark ? AppColors.dangerDark : AppColors.danger,
      AppTone.neutral => Theme.of(context).colorScheme.onSurfaceVariant,
      AppTone.brand => Theme.of(context).colorScheme.primary,
    };
  }

  /// Soft container used behind text badges and status icons.
  Color surface(BuildContext context) =>
      color(context).withValues(alpha: 0.12);
}

abstract final class AppSpacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 20.0;
  static const xl = 28.0;

  /// Horizontal inset used by every page section and grouped surface.
  static const page = 16.0;

  /// Horizontal inset used inside a grouped list row.
  static const rowHorizontal = 14.0;

  /// Vertical inset used inside a grouped list row.
  static const rowVertical = 10.0;

  /// Fixed space between a leading icon and the text column.
  static const rowLeadingGap = 12.0;

  /// Fixed space between adjacent trailing actions.
  static const rowActionGap = 8.0;

  /// Compact gap between an iOS bottom-tab icon and its label.
  static const bottomNavigationItemGap = 2.0;

  /// Vertical distance between sibling sections.
  static const section = 24.0;

  /// Distance between a section header and the grouped surface below it.
  static const sectionHeaderGap = 8.0;

  /// Minimum height used by tappable rows and compact controls.
  static const control = 44.0;

  /// Minimum height of a grouped list row.
  static const row = 52.0;

  /// Label column used by label/value rows and form rows.
  static const labelColumn = 96.0;
}

abstract final class AppSizes {
  /// Shared leading slot for grouped list rows.
  static const listLeading = 36.0;

  /// Compact leading slot used by dense secondary lists.
  static const listLeadingCompact = 32.0;

  /// Hit target reserved for compact trailing actions.
  static const listAction = 44.0;

  /// Height of a status badge, independent of its label length.
  static const statusBadge = 26.0;

  /// Height of the primary action button on a page footer.
  static const primaryButton = 50.0;

  /// Extra vertical room for the iOS tab bar so labels do not crowd its top
  /// rule or the bottom safe area.
  static const bottomNavigation = 64.0;

  /// Material counterpart to the iOS tab bar rhythm.
  static const materialBottomNavigation = 72.0;
}

/// Low-contrast rules used to separate grouped surfaces without making the
/// page feel boxed in.
abstract final class AppOpacity {
  // Apple separators already carry a fairly strong base color. Keeping the
  // alpha low makes grouped surfaces read as one quiet system surface instead
  // of a stack of outlined cards.
  static const groupedBorder = 0.07;
  static const groupedDivider = 0.08;
  static const navigationRule = 0.12;
  static const disabled = 0.45;
}

abstract final class AppRadii {
  static const small = 8.0;
  static const medium = 10.0;
  static const large = 16.0;
  static const sheet = 20.0;
}

abstract final class AppMotion {
  static const quick = Duration(milliseconds: 150);
  static const standard = Duration(milliseconds: 200);
  static const sheet = Duration(milliseconds: 300);
}

bool isApplePlatform(BuildContext context) {
  final platform = Theme.of(context).platform;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
}

extension AdaptiveColors on BuildContext {
  Color get appPageBackground => isApplePlatform(this)
      ? CupertinoColors.systemGroupedBackground.resolveFrom(this)
      : Theme.of(this).colorScheme.surface;

  Color get appGroupedSurface => isApplePlatform(this)
      ? CupertinoColors.systemBackground.resolveFrom(this)
      : Theme.of(this).colorScheme.surfaceContainerLow;

  Color get appElevatedSurface => isApplePlatform(this)
      ? CupertinoColors.secondarySystemGroupedBackground.resolveFrom(this)
      : Theme.of(this).colorScheme.surfaceContainerHigh;

  Color get appSecondaryLabel => isApplePlatform(this)
      ? CupertinoColors.secondaryLabel.resolveFrom(this)
      : Theme.of(this).colorScheme.onSurfaceVariant;

  Color get appTertiaryLabel => isApplePlatform(this)
      ? CupertinoColors.tertiaryLabel.resolveFrom(this)
      : Theme.of(this).colorScheme.outline;

  Color get appSeparator => isApplePlatform(this)
      ? CupertinoColors.separator.resolveFrom(this)
      : Theme.of(this).colorScheme.outlineVariant;

  Color get appPrimary => isApplePlatform(this)
      ? (CupertinoTheme.of(this).brightness == Brightness.dark
            ? AppColors.brandDark
            : AppColors.brand)
      : Theme.of(this).colorScheme.primary;

  Color get appDanger => isApplePlatform(this)
      ? CupertinoColors.systemRed.resolveFrom(this)
      : Theme.of(this).colorScheme.error;
}

/// Type ramp shared by every page. Sizes are explicit so iOS and Material read
/// the same rhythm, while platform text scaling still applies.
abstract final class AppType {
  static const largeTitle = TextStyle(
    fontSize: 30,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
  );

  static const navTitle = TextStyle(
    fontSize: 17,
    height: 1.25,
    fontWeight: FontWeight.w600,
  );

  static const cardTitle = TextStyle(
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  static const rowTitle = TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w500,
  );

  static const rowTitleStrong = TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w600,
  );

  static const rowSubtitle = TextStyle(fontSize: 13, height: 1.38);

  static const body = TextStyle(fontSize: 15, height: 1.47);

  static const footnote = TextStyle(fontSize: 13, height: 1.4);

  static const caption = TextStyle(
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );

  static const metric = TextStyle(
    fontSize: 28,
    height: 1.15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
  );

  static const mono = TextStyle(
    fontSize: 13,
    height: 1.4,
    fontFamily: 'Menlo',
    fontFamilyFallback: ['Courier'],
  );
}
