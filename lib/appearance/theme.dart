import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part '../generated/appearance/theme.g.dart';

final materialLightTheme = ThemeData.light().copyWith(
  cupertinoOverrideTheme: const CupertinoThemeData(primaryColor: Colors.purple, primaryContrastingColor: Colors.green),
);
final materialDarkTheme = ThemeData.dark().copyWith(
  cupertinoOverrideTheme: const CupertinoThemeData(primaryColor: Colors.red, primaryContrastingColor: Colors.green),
);
final cupertinoLightTheme = MaterialBasedCupertinoThemeData(materialTheme: materialLightTheme);
final cupertinoDarkTheme = MaterialBasedCupertinoThemeData(materialTheme: materialDarkTheme);

@Riverpod(dependencies: [])
ThemeData theme(Ref ref) {
  throw UnimplementedError();
}

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
