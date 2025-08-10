import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

extension CancelTokenX on Ref {
  CancelToken cancelToken() {
    final cancelToken = CancelToken();
    onDispose(cancelToken.cancel);
    return cancelToken;
  }
}

// 为 BuildContext 创建一个名为 AppTheme 的扩展
extension AppTheme on BuildContext {
  T _resolvePlatformValue<T>({required T Function(ThemeData materialTheme) material, required T Function(CupertinoThemeData cupertinoTheme) cupertino}) {
    return isMaterial(this) ? material(Theme.of(this)) : cupertino(CupertinoTheme.of(this));
  }

  /// 获取主色调
  Color get primaryColor => _resolvePlatformValue(material: (theme) => theme.colorScheme.primary, cupertino: (theme) => theme.primaryColor);

  /// 获取背景色
  Color get backgroundColor => _resolvePlatformValue(material: (theme) => theme.colorScheme.background, cupertino: (theme) => theme.scaffoldBackgroundColor);

  /// 获取 Scafflod 的背景色 (通常和 backgroundColor 一样，但可以分开定义)
  Color get scaffoldBackgroundColor =>
      _resolvePlatformValue(material: (theme) => theme.scaffoldBackgroundColor, cupertino: (theme) => theme.scaffoldBackgroundColor);

  /// 获取文字主色 (用在背景色之上的颜色)
  Color get onBackgroundColor =>
      _resolvePlatformValue(material: (theme) => theme.colorScheme.onSurface, cupertino: (theme) => theme.textTheme.textStyle.color!);

  /// 获取次要文字颜色 (例如灰色、用于提示)
  Color get secondaryTextColor => _resolvePlatformValue(
    material: (theme) => theme.colorScheme.onSurface.withValues(alpha: 0.6),
    cupertino: (theme) => CupertinoColors.secondaryLabel.resolveFrom(this),
  );

  /// 获取分割线颜色
  Color get dividerColor => _resolvePlatformValue(material: (theme) => theme.dividerColor, cupertino: (theme) => CupertinoColors.separator.resolveFrom(this));

  /// 获取页面大标题的样式
  TextStyle? get headlineStyle =>
      _resolvePlatformValue(material: (theme) => theme.textTheme.headlineSmall, cupertino: (theme) => theme.textTheme.navLargeTitleTextStyle);
}
