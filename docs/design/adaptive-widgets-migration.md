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

---

# 执行结果（2026-09-27，三阶段全部完成）

## 阶段 1：入口三件套（已完成）

- `lib/main.dart`：`PlatformProvider` + `PlatformTheme` + `PlatformApp.router`
  → 单个 `MaterialApp.router`（iOS/Android 同一入口），主题仍用 `appearance/theme.dart` 的
  Material 明暗主题，并在 `builder` 里套一层 `CupertinoTheme`（同一个明暗判断），
  Toast 仍在最外层。
- `lib/widgets/common_widgets.dart`：`WDAppBar` 由 `extends PlatformAppBar` 改为**我们自己的
  `StatelessWidget implements ObstructingPreferredSizeWidget`**，内部只分两支：
  `CupertinoNavigationBar`（leading/title/trailing + 底部 1px 分隔线）与 `AppBar`（Material）。
  保持既有规则：44pt 返回键、返回键后不再补 8pt、标题可两行、trailing 用 `MainAxisSize.min`。
- `lib/core/app_router.dart`：`WDShellPage` 改用新的 `AdaptiveTabScaffold`；
  Material 分支保持 HEAD 的 **Material 3 `NavigationBar`**（这是子代理发现并修正的一次偏差：
  我最初写成 Material 2 的 `BottomNavigationBar`，会让 Android 视觉语言和既有测试都变），
  Apple 分支 `CupertinoTabBar`。
- 新增 `AdaptivePageScaffold`（CupertinoPageScaffold / Scaffold 两支），12 处页面 scaffold
  从 `PlatformScaffold` 迁移过来，`iosContentPadding` 参数自然消失（我们的 Cupertino 分支
  本来就不额外加导航栏高度）。

## 阶段 2：控件级替换 + 删除依赖（已完成）

- `lib/widgets/adaptive_widgets.dart` 新增自家原语（每个都自己分两支，调用方不再写两套参数）：
  `AdaptiveTextButton`、`AdaptiveElevatedButton`、`AdaptiveSwitch`、`AdaptiveSpinner`、
  `AdaptiveTextFormField`（**一个 `label` 同时服务两端**，Apple 用 `prefix`、Material 用
  floating label）、`AdaptiveFieldPrefix`（最小宽度 112pt 取代固定 112pt，英文标签不再溢出）；
  `AdaptiveIconButton` 增加 `materialIcon`（两端图形不同时用，如铅笔/刷新/省略号）。
- 替换点：`PlatformScaffold` 12、`PlatformTextButton` 10、`PlatformIconButton` 6、
  `PlatformTextFormField` 5、`PlatformCircularProgressIndicator` 3、`PlatformElevatedButton` 2、
  `PlatformSwitch` 1、`PlatformNavBar` 1，以及 `main.dart` 的三个入口组件。
- 删除死代码：`new_webdav.dart` 的 `PrefixWrapper`（固定 112pt）。
- `pubspec.yaml`：`flutter_platform_widgets` **已删除**（并留注释说明为什么不许再加回来）。
- 测试侧：`PlatformProvider/PlatformApp` 的测试外壳全部替换为
  `MaterialApp(theme: ThemeData(platform: …))`，**每个测试驱动的平台保持不变**（iOS 仍是
  Cupertino 分支，Android 仍是 Material 分支）；没有任何断言被削弱。

## 阶段 3：迁移到 material_ui / cupertino_ui（已完成）

- `pubspec.yaml`：`material_ui: ^1.4.0`、`cupertino_ui: ^1.1.1`；`flutter_localizations`
  不再需要（设计库的本地化 delegate 已随包走，`GlobalMaterialLocalizations.delegates`
  同时包含 Cupertino 与 Widgets）。
- `dart fix --apply --code=migrate_design_widgets`：96 个文件、144 处 import 改写。
- 自动迁移后的收尾（都是机械问题，均已修完）：
  1. `GlobalMaterialLocalizations` / `GlobalCupertinoLocalizations` 与 `flutter_localizations`
     重名 → 统一改用新包的 `delegates`，剩余的 `flutter_localizations` import 全部删除（41 个文件）；
  2. `delegates` 是 List 而 `delegate` 是单值 → 列表处用 `...GlobalMaterialLocalizations.delegates`，
     直接赋值处不加 spread；
  3. `const <LocalizationsDelegate>[...]` 不再成立（新包用 getter 暴露 delegate）→ 去掉 `const`；
  4. `dart format` 之后 `mirror_models.dart` 出现 3 处 `if (...) return ...;` 缺少花括号 → 补上。
- **结果：`lib/` 与 `test/` 中 0 个文件再 import `package:flutter/material.dart` 或
  `package:flutter/cupertino.dart`**（88 个文件用 material_ui、55 个用 cupertino_ui）。

## 验收

| 项目 | 结果 |
| --- | --- |
| `flutter analyze lib test` | No issues found |
| `flutter test` | **1111 项全部通过**（迁移前 1087；子代理新增 24 项） |
| `flutter build ios --debug --simulator` | ✓ 构建、安装、启动 |
| `flutter build apk --debug` | ✓ app-debug.apk |
| 模拟器实测 | 文件同步 tab、同步位置详情、连接列表、新建 WebDAV 表单（见 `ui_audit/plain-sync-20260927/stage1_*.png`、`stage3_*.png`） |

## 仍需注意

- 迁移后我们自己的包装层（`adaptive_widgets.dart` / `common_widgets.dart`）是**唯一**接触设计库的地方；
  业务页面只 import 我们的组件，将来设计库再变（例如 Material 4）只需要改这两三个文件。
- `flutter build ios --release`（真机/上架）本轮没有跑，需要用户用自己的签名环境验证一次。
- 设计库现在是**独立发版**的 pub 包（周更），可以单独升级；升级后请重跑 `flutter test` 与两端构建。
