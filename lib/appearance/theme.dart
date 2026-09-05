import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'design_tokens.dart';

part '../generated/appearance/theme.g.dart';

final materialLightTheme = _materialTheme(Brightness.light);
final materialDarkTheme = _materialTheme(Brightness.dark);

/// Cupertino receives a real iOS theme instead of a Material-derived theme.
/// This is the key distinction that lets system labels, bars and controls keep
/// their native contrast and dynamic colors on Apple platforms.
const cupertinoLightTheme = CupertinoThemeData(
  brightness: Brightness.light,
  primaryColor: AppColors.brand,
  primaryContrastingColor: CupertinoColors.white,
  barBackgroundColor: CupertinoColors.systemBackground,
  scaffoldBackgroundColor: CupertinoColors.systemGroupedBackground,
  selectionHandleColor: AppColors.brand,
  applyThemeToAll: true,
);

const cupertinoDarkTheme = CupertinoThemeData(
  brightness: Brightness.dark,
  primaryColor: AppColors.brandDark,
  primaryContrastingColor: CupertinoColors.white,
  barBackgroundColor: CupertinoColors.systemBackground,
  scaffoldBackgroundColor: CupertinoColors.systemGroupedBackground,
  selectionHandleColor: AppColors.brandDark,
  applyThemeToAll: true,
);

ThemeData _materialTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: isDark ? AppColors.brandDark : AppColors.brand,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: isDark ? AppColors.brandDark : AppColors.brand,
      scaffoldBackgroundColor: scheme.surface,
      applyThemeToAll: true,
    ),
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: AppSizes.materialBottomNavigation,
      elevation: 0,
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        return base.textTheme.labelMedium?.copyWith(
          color: states.contains(WidgetState.selected)
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
        );
      }),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.large),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(
            alpha: AppOpacity.groupedBorder,
          ),
        ),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.rowHorizontal,
        vertical: AppSpacing.rowVertical,
      ),
      minVerticalPadding: 0,
      horizontalTitleGap: AppSpacing.rowLeadingGap,
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: base.textTheme.bodyLarge?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      subtitleTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        height: 1.35,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: AppOpacity.groupedDivider),
      space: 1,
      thickness: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.small),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.small),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.small),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.small),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.small),
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 1,
      focusElevation: 2,
      hoverElevation: 2,
      highlightElevation: 2,
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.medium),
      ),
    ),
    dialogTheme: DialogThemeData(
      elevation: 2,
      surfaceTintColor: Colors.transparent,
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.large),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      elevation: 2,
      surfaceTintColor: Colors.transparent,
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.small),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.small),
      ),
    ),
  );
}

@Riverpod(dependencies: [])
ThemeData theme(Ref ref) => materialLightTheme;

@riverpod
class VSThemeMode extends _$VSThemeMode {
  @override
  ThemeMode build() {
    return ThemeMode.system;
  }

  void setThemeMode(ThemeMode mode) {
    state = mode;
  }
}
