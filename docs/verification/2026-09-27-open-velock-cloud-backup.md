# 「打开格间」直接进入云备份

## 原因与修复

首页「需要连接格间」卡片调用 `openVelockForBackup`，其 `velockAppLauncherProvider` 仍发出 `velock://open`，只能唤醒 App，保留先前设置页。此前只有「恢复卡与已授权设备」修成了指定云备份页面的入口。

通用备份 launcher 现复用 `velockBackupSettingsLauncherProvider`，发送 `velock://sync-settings`。首页、详情、向导及复用该 helper 的恢复引导均自动使用同一路径。该地址不带 requestId，不生成/批准请求，不改变权限。真实 pairing 请求继续使用原独立授权流程。

格间原有 `PendingSyncNavigation` 在锁定期间保留导航、解锁后单次消费，无需修改接收端。下载完成后用于唤醒格间应用数据的独立入口不在本次改动范围。

## 验证

- Sync 49项：`backup_settings_launcher_test.dart`、`backup_navigation_test.dart`、`velock_pairing_recovery_test.dart`。
- 新增真实首页/详情按钮回归，配置未启用时点击「打开格间」调用云备份 launcher，profile 状态不变；用 MethodChannel 捕获两个生产 launcher 实际发出的 URL 与外部打开模式，替换旧的源码字符串断言。
- 格间23项 `sync_navigation_intent_test.dart` 通过，含锁定保留/消费一次、旧请求与详情栈清理。
- 两个改动Dart文件静态分析 No issues found，diff whitespace检查通过。
- XcodeBuildMCP：Sync `ios/Runner.xcworkspace` / `Runner` / `Debug`，构建、安装、启动均成功；复用 iPhone 17 Pro Max `26CC5821-DEF4-47D3-978D-A11D7293AD61`，产物在项目外 `velock_sync-artifacts/DerivedData`。
- 真实GUI：新版Sync首页显示「需要连接格间」→点击「打开格间」→格间test1锁屏→解锁→自动显示「云备份」和「允许 Sync 连接」开关（关闭）。AX与实际截图均确认落点。未点击云备份开关，未授权、同步或改动远端。
- 本机无可调用原生DeepSeek GUI模型，主模型在独占GUI租约下完成该操作，验收后释放租约。
