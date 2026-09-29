# 备份已完成却弹「同步失败」

## 现场与根因

用户 18:01 截图同时显示「上次备份已完成」和「同步失败 / 同步未完成，请检查同步配置后重试」。只读核对现有模拟器数据库：18:01:12、18:01:36、18:01:43 的运行均为 completed、error_code 为空；最近失败仍是 17:34:38 的历史缺失。

App 根为 MaterialApp.router，iOS 业务页面为 Cupertino scaffold。MaterialApp 仍安装 ScaffoldMessenger，但它没有可用于显示 SnackBar 的 Material Scaffold。showPlatformMessage 只检查 messenger 非空，完成提示调用 showSnackBar 时触发 `_scaffolds.isNotEmpty` 断言。首页的 try/catch 同时包住 runner 和结果展示，把提示组件异常分类为 unexpected，于是弹了同步失败。成功的数据库记录并未变为失败，形成截图里的矛盾。

## 修复与回归

Apple 页面使用 SnackBar 前还需确认有 Material Scaffold；Cupertino 页面使用已有原生 toast 通道。Material 页仍允许从自身 Scaffold 上方的 context 调用提示。没有吞掉 runner 的失败，也没有修改备份记录、授权或完整性门禁。

新回归以 MaterialApp + iOS theme + CupertinoPageScaffold 还原生产结构。修复前稳定复现上述断言，修复后确认 toast 内容。原先纯 CupertinoApp 与 Material Scaffold 的测试都不能覆盖这种混合结构。

33 项相关 widget 回归通过，两个 Dart 文件静态分析通过。证据：`ui_test_results/completion-toast-20260927/before-fix.log`、`tests.log`。

Debug 包已构建并覆盖安装到现有 iPhone 17 Pro Max（26CC5821-DEF4-47D3-978D-A11D7293AD61），未清数据。原生 XCTest 通过显式 E2E_MANUAL_BACKUP_CHECK 开关点击现有备份的「立即备份」，不更改位置或配对；结果记录在同目录 simulator-ui-test.log 与 manual-backup-completed.png。

18:06 原生 XCTest 1/1 通过，点击后等待并断言无「同步失败」，完成卡片存在；人工查看导出的实际屏幕 PNG 确认一致。最新对应运行 18:05:36 completed、error_code 为空。本次是既有备份的运行及完成提示验收，不是新设备全内容恢复验收。测试结束后重新打开已安装 App。
