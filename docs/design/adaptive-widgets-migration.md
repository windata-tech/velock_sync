# 迁移计划：脱离 flutter_platform_widgets（并接住 Material/Cupertino 解耦）

## 为什么必须动

上游在 pub.dev 上写明：

> ⚠️ **Package Discontinued** — Due to Flutter's decision to split out Material and Cupertino
> widgets into their own packages, this project is now no longer supported.
> No further bug fixes or compatibility updates will be provided.

也就是说：Flutter 官方把 Material / Cupertino 两个设计库从 SDK 里拆出去，变成独立的
`package:material_ui` 与 `package:cupertino_ui`（Flutter 3.47 起可用，SDK 内的
`flutter/material.dart`、`flutter/cupertino.dart` 自 3.44 起冻结贡献，后续稳定版正式弃用）。
`flutter_platform_widgets` 的全部价值就是「在同一棵树上按平台在 Material 与 Cupertino 之间切换」，
基础被搬走之后维护者不再跟进，10.0.1 是最后一个版本。

**关键风险**：官方提供的兼容桥（`MaterialUiCompatibilityBridge`）只注入主题与本地化，
**不能解决跨库的类型不匹配**。`flutter_platform_widgets` 的公开 API 大量出现 SDK 内部类型
（`MaterialScaffoldData(appBar: AppBar?)`、`CupertinoIconButtonData`、`ThemeData` 等），
所以我们一旦把 App 迁到 `material_ui` / `cupertino_ui`，这个包会直接编译不过。
结论：**要么在迁移设计库之前把它清掉，要么把它 vendor 进仓库自己打补丁。**

## 现状盘点（本仓库实测）

- 12 个文件 import 该包；调用点：
  `PlatformScaffold` 12、`PlatformTextButton` 10、`PlatformIconButton` 6、
  `PlatformTextFormField` 5、`PlatformCircularProgressIndicator` 3、
  `PlatformElevatedButton` 2、`PlatformSwitch` 1、`PlatformNavBar` 1，
  以及 `main.dart` 的 `PlatformProvider` / `PlatformTheme` / `PlatformApp.router`，
  和四个 `*.material` / `*.cupertino` 数据类。
- 好消息：`isApplePlatform(context)` 已经是我们自己的（`lib/appearance/design_tokens.dart:151`），
  56 处调用**不**依赖该包。
- 好消息：包装层已经存在一大半——`AdaptiveScaffold`、`AdaptiveSliverScaffold`、`WDAppBar`、
  `AdaptiveIconButton`、`AdaptiveListSection/Tile/SwitchListTile`、`AdaptiveLoadingState/ErrorState`、
  `AdaptiveActionMenu`。迁移主要是把上面那 40 个调用点**改走我们自己的包装**，
  而不是从零写一套平台抽象。
- 测试兜底很厚：1087 项 widget/单元测试，且多数界面测试同时跑 `TargetPlatform.iOS` 与
  `TargetPlatform.android`，每换一个包装都能立刻验证两种平台。

## 分阶段

### 阶段 0（已做）钉死版本，别在迁移前被动升级

- `pubspec.yaml` 从 `^10.0.1` 改为 `10.0.1`，并写明原因。
- 触发迁移的条件写在这里：**升级 Flutter 大版本之前，先跑一次全量测试 + 两台设备的
  `flutter build ios/android`；一旦出现该包的编译/运行错误，直接进入阶段 2。**

### 阶段 1（半天，低风险）先把「入口级」三件套换成我们自己的

1. `main.dart`：`PlatformProvider` + `PlatformTheme` + `PlatformApp.router`
   → `MaterialApp.router`（主题继续用 `lib/appearance/theme.dart` 里已有的四个 ThemeData；
   注意 iOS 分支需要 `CupertinoThemeData` 包装或直接用 Material 主题 + Cupertino 页面组件，
   这一步要人工看一遍 iOS 观感）。
2. `app_router.dart` 的 `PlatformNavBar` → 新增 `AdaptiveNavBar`（内部按 `isApplePlatform` 分支，
   Cupertino 用 `CupertinoTabScaffold`，Material 用 `NavigationBar`）。
3. `PlatformScaffold` → 已有的 `AdaptiveScaffold` / `AdaptiveSliverScaffold`
   （12 处，逐页替换；`*.material`/`*.cupertino` 数据类改成我们自己的参数）。

做完这一步，包就只剩「控件级」耦合。

### 阶段 2（1 天）控件级替换，然后删依赖

在 `lib/widgets/adaptive_widgets.dart` 补齐这几个，然后把调用点逐个换过去：

| 现在 | 换成 |
| --- | --- |
| `PlatformTextButton` | `AdaptiveTextButton`（已有 Cupertino/Material 两分支语义） |
| `PlatformIconButton` | 已有 `AdaptiveIconButton`（禁用只降透明度，不复灰） |
| `PlatformElevatedButton` | `AdaptivePrimaryButton`（或 `BackupActionButton`，本项目主按钮已经统一） |
| `PlatformTextFormField` | `AdaptiveTextFormField`（复用 `AppFormRow` 的标签列） |
| `PlatformSwitch` | `AdaptiveSwitch` |
| `PlatformCircularProgressIndicator` | `AdaptiveSpinner`（Cupertino 用 `CupertinoActivityIndicator`） |

每换一个跑：`flutter test test/widgets test/features`，最后 `flutter pub remove flutter_platform_widgets`
再跑全量 1087 项 + 两台设备构建。

### 阶段 3（可选，视时间）真正迁移到 material_ui / cupertino_ui

等阶段 2 完成后，业务页面只 import 我们自己的 `adaptive_widgets.dart`，
于是 `dart fix --apply --code=migrate_design_widgets` 只需作用在**包装层那几个文件**上，
再 `flutter pub add material_ui cupertino_ui` 即可。注意本地化写法同步改为：

```dart
localizationsDelegates: GlobalMaterialLocalizations.delegates,
```

### 备选方案：vendor（半天，最省事的保险）

包是 MIT、纯 Dart（约 9.5k 行，无原生代码）。如果不想现在做阶段 1/2，可以直接把
`~/.pub-cache/hosted/pub.dev/flutter_platform_widgets-10.0.1` 复制成
`packages/flutter_platform_widgets`，用 path 依赖引用，之后 SDK 破坏兼容时我们自己改。
代价是仓库里多一份第三方源码要跟着看。

## 建议

1. 现在：只做阶段 0（已完成）。
2. 上线前：做阶段 1——**这一步把风险从「全站」缩到「几个控件」**，而且是入口层的改动，
   最容易在两台设备上看清楚。
3. 上线后有空：阶段 2 → 删依赖；再谈阶段 3。
