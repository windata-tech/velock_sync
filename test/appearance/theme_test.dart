import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/appearance/theme.dart';

void main() {
  test('dark theme exposes a dark color scheme', () {
    expect(materialDarkTheme.brightness, Brightness.dark);
    expect(materialDarkTheme.colorScheme.brightness, Brightness.dark);
  });
}
