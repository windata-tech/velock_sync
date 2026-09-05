import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Small, platform-neutral design primitives used by the adaptive UI layer.
///
/// The app deliberately keeps these values quiet and system-like. Platform
/// widgets still own typography, motion, controls and navigation behavior.
abstract final class AppColors {
  static const brand = Color(0xFF3F63D9);
  static const brandDark = Color(0xFF9DB2FF);

  static const success = Color(0xFF2E7D4F);
  static const warning = Color(0xFFB86100);
  static const danger = Color(0xFFBA1A1A);
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
  static const rowHorizontal = 12.0;

  /// Vertical inset used inside a grouped list row.
  static const rowVertical = 8.0;

  /// Fixed space between a leading icon and the text column.
  static const rowLeadingGap = 10.0;

  /// Fixed space between adjacent trailing actions.
  static const rowActionGap = 8.0;

  /// Compact gap between an iOS bottom-tab icon and its label.
  static const bottomNavigationItemGap = 2.0;

  /// Vertical distance between sibling sections.
  static const section = 12.0;

  /// Minimum height used by tappable rows and compact controls.
  static const control = 48.0;
}

abstract final class AppSizes {
  /// Shared leading slot for grouped list rows.
  static const listLeading = 36.0;

  /// Hit target reserved for compact trailing actions.
  static const listAction = 44.0;

  /// Height of a status badge, independent of its label length.
  static const statusBadge = 26.0;

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
}

abstract final class AppRadii {
  static const small = 8.0;
  static const medium = 10.0;
  static const large = 14.0;
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

  Color get appSecondaryLabel => isApplePlatform(this)
      ? CupertinoColors.secondaryLabel.resolveFrom(this)
      : Theme.of(this).colorScheme.onSurfaceVariant;

  Color get appSeparator => isApplePlatform(this)
      ? CupertinoColors.separator.resolveFrom(this)
      : Theme.of(this).colorScheme.outlineVariant;

  Color get appPrimary => isApplePlatform(this)
      ? (CupertinoTheme.of(this).brightness == Brightness.dark
            ? AppColors.brandDark
            : AppColors.brand)
      : Theme.of(this).colorScheme.primary;
}
