# 建立新备份完成页返回导航修复（2026-09-27）

用户在更换远端目录并完成新备份后，点击「返回备份」仍停留在完成页。

## 原因与修复

`BackupHistoryHelp` 和 `VelockBackupRebuildPage` 通过 `Navigator.push` 叠加在当前页面上；从首页进入时，GoRouter 的地址仍是 `/`。原按钮只执行 `context.go('/')`，不会移除保留在 StatefulShellBranch 上的命令式路由。

按钮现在先保留 GoRouter 引用，使用当前 Navigator 的 `popUntil(route.isFirst)` 关闭该层流程，再 `go('/')` 返回备份首页。仍保留上传/校验期间的 busy 门禁。本次仅修复返回导航，不改变快照上传、校验和配置切换逻辑。

## 验证

- 新增四个真实 GoRouter + StatefulShellRoute widget 场景：iOS/Android × 首页/详情入口；按生产方式连续 push 帮助页与重建页，通过服务替身完成上传，再实际点击返回。
- 修复前：首页入口两项稳定失败，完成页仍挡住首页；详情入口两项通过。
- 修复后：四项全部通过；连同原重建 UI、历史帮助和备份导航，共 48 项测试通过。
- 两个改动 Dart 文件 `flutter analyze --no-pub`：No issues found。
- 测试验证页面导航，未重复执行真实 NAS 重建/上传。
- `flutter build ios --simulator --debug --no-pub` 构建成功；经 xcodebuildmcp 安装并启动在现有 iPhone 17 Pro Max（26CC5821-DEF4-47D3-978D-A11D7293AD61）。未新建/擦除模拟器。完成页点击由 widget 回归验证，本轮未重跑设备上的 NAS 全流程。
