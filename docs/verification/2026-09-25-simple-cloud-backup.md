# 普通用户云备份 UI 第一轮重构验证记录（2026-09-25）

## 1. 基线与工作树状态

- 原 Sync `main` 备份：`a1b7c6451afa40ce1f43de056c2288daa72ab413`。
- 格间 `main` 备份：`c5ba1ba2fa34c1f8e6935c9a1515acb2d42c2691`。
- 两个仓库服务器均有 annotated tag：`backup/20260925-before-simple-sync`。
- 当前分支：`codex/simple-cloud-backup`。
- 重构交付在两个仓库的 `codex/simple-cloud-backup` 分支；原版 `main` 与备份 tag 保持不变。最终提交以对应分支记录为准。
- 本文记录的是 UI/导航与文本边界验证，不是协议、设备或真实云服务验收。

## 2. 已完成的测试证据

- Sync 相关回归 **425 项全部通过**，包括云备份状态/导航/预检、文件夹/格间入口分层、原同步核心、WebDAV/OAuth 和跨 App 原生配置契约；最终证据：`sync-regression-final-accepted.txt`。该结果来自最终样式修正后的重跑，不使用较早的 372 项或失败运行作最终结论。
- 上述套件包含 **14 项真实路由 widget 测试**：真实 `GoRouter`、三主入口分离、恢复 intent 返回、已批准授权保留、WebDAV/OAuth 返回目标和 `returnTo` 白名单。
- 上述套件包含 **11 项云位置预检测试**：碰撞不可覆盖/删除、超大读回失败关闭、连接/读取超时、只清理本轮 probe、已有备份不变、恢复发现只读和身份隔离。
- **13 项界面测试**另以中文真实字体重跑并输出四张截图，全部通过（`visual-qa-final-accepted.txt`）。这 13 项已包含在 425 项中，不重复累计。覆盖传输报错后的状态清理、失败暂停状态不丢失、重复点击门禁、后台开关持久化、技术记录下钻和 320px 中英大字布局。
- 格间 **29 项相关测试全部通过**（`companion-regression-final-accepted.txt`），包括忙碌动作门禁、无障碍展开/折叠、320px 双语大字和原有授权/页面生命周期回归。曾出现的 semantics 句柄清理问题已修复。
- 两仓库本次改动范围静态分析均为 `No issues found`（`sync-analyze-final-accepted.txt`、`companion-analyze-verified.txt`）；不是全仓库静态分析结论。
- Android manifest 与 Apple plist 结构检查、两仓库 `git diff --check` 通过；本轮新增内容的凭据检查未发现秘密，私有 NAS 环境文件保持 Git 忽略。

结果日志集中保存在项目外 `../velock_sync-artifacts/work/simple-cloud-backup-20260925/`，不把日志和测试截图提交到源码仓库。

## 3. 新增/固化的验收断言

### 导航与产品分层

- iOS 与 Android 真实 shell 的底部主入口为“格间 / 文件同步 / 设置”。
- 格间首页只显示格间 profile、云备份摘要和“从云端恢复”；文件同步页只显示文件夹 profile，不显示格间恢复入口。
- 设置页提供云账号/保存位置和所有传输记录入口，但不把内部计数放到主界面。

### 恢复与返回

- 未确认“已在格间恢复原账号”前，恢复继续按钮不可用；Sync 页面没有恢复卡秘密输入框。
- 恢复确认进入实际 `intent=restore` 路由；已有格间连接时不能静默启动第二个账号恢复。
- 从恢复设置进入 WebDAV 等新增连接页面并保存后，返回原始恢复流程，`restoring` 和已批准授权仍保留，页面自动继续。
- 恢复候选只接受签名授权中的可信 producer；空位置、其他账号、不受信 producer、只有 checkpoint/部分批次均拒绝，且探测不写远端。
- `returnTo` 对未知 URL、外部地址、带额外参数的恢复地址和任意业务路由均拒绝。

### OAuth 与云位置预检

- 普通用户默认看不到 Client ID、Token 或 root ID；未配置公开注册时显示“此版本暂未开通”和“选择其他保存位置”。
- 自定义构建的 Client ID 输入在保存前不触发页面替换，保存后才进入授权界面；Root ID 通过默认折叠的高级入口才可见。
- 预检使用随机、无敏感内容的 `ifAbsent` probe，写入后读回并逐字节校验；碰撞不删除/覆盖，失败只清理自己成功创建的 probe。
- 恢复探测不调用 `put` 或 `delete`。

### 跨 App 打开契约

- 格间新入口使用 `velocksync://app/open`；Android 精确注册 app/open 并保留原 OAuth callback；iOS/macOS 保留或新增对应 scheme。
- iOS/Android 关闭 Flutter 自动 deeplink 路由，已有 app_links 仍独立接收 OAuth callback，普通打开请求不应打断正在设置的页面。
- 本项是静态配置和 URI 契约测试，不是系统层冷/热启动、真实 OAuth 或跨 App 恢复成功证明。

### 展示状态与安全门禁

- 已保存连接、已建 profile、已上传对象或已下载批次不会被描述成完整备份/恢复成功。
- `pendingIncoming` 在下载完成后仍要求“打开格间”完成实际恢复；待上传/待下载和冲突优先级高于最近一次 runner 完成。
- 历史不完整、存储原子创建不支持、待授权和隔离 profile 均显示为需要处理，不能靠“重新同步”掩盖失败。
- 存储原子创建不支持时显示可操作文案，不向普通用户暴露 MOVE 或原始错误码。

## 4. 截图与测试边界

`../velock_sync-artifacts/work/simple-cloud-backup-20260925/screenshots/` 中的 UI 截图来自真实 widget 渲染加内存 fixture，用于检查布局、文案和状态投影；它们不是模拟器截图、不是真机截图、不是 NAS 截图，也不是 OAuth 或跨 App 恢复 E2E 证据。

本轮没有执行以下验证：

- 物理真机或模拟器端到端测试；
- 真实 OAuth 授权；
- 新 NAS 或其他远端写入；
- 跨 App 恢复 E2E；
- current-state 完整快照传输/恢复状态机；
- 六类业务内容可验证备份摘要；
- 版本选择、自动完整云端迁移或仅上传文件夹模式。

因此，本记录只能证明第一轮消费者 UI/路由和相应边界，不能证明完整云备份/恢复已经完成。

## 5. 实际执行与分工

### 回归命令

Sync 仓库：

```bash
flutter test --no-pub --reporter expanded \
  test/features/cloud_backup test/features/sync_profiles test/features/connection \
  test/l10n test/widgets test/sync_profiles test/sync_core \
  test/dataset_adapters/velock_exchange test/providers/webdav test/providers/oauth \
  test/core/app_open_contract_test.dart
```

格间仓库：

```bash
flutter test --no-pub --reporter expanded \
  test/features/settings/cloud_backup_panel_test.dart \
  test/features/settings/velock_sync_refresh_lifecycle_test.dart \
  test/l10n/sync_tutorial_localization_test.dart \
  test/sync/velock_pairing_control_plane_test.dart
```

静态分析针对本轮改动的 Dart 源码和测试执行 `flutter analyze --no-pub`，两个仓库结果均无问题；文档和源码通过 `git diff --check`。界面截图通过 `BACKUP_UI_FONT` 和 `BACKUP_UI_SCREENSHOT_DIR` 环境变量、运行 `test/features/cloud_backup/backup_ui_test.dart` 产生，不依赖真实远端。

### 主副模型分工

- 统一 worker 调度器实际使用 **DeepSeek / high** 完成边界清晰的界面回归、预检负向测试、原生打开契约/测试、设计与验证文档；两处问题分别进行了一轮定向修正。
- 副模型测试发现并修复首页刷新向 `setState` 返回 Future 的真实问题，以及原生 plist 测试辅助函数的键匹配问题。
- 主模型负责跨 App 责任与安全边界、整合关键流程、检查差异、完整运行 Flutter 测试及最终视觉验收。worker 的 SDK cache 写入限制没有通过扩权绕过，最终可执行测试由主模型统一运行。
- worker 结果、日志与调度元数据保存在上述项目外 work 目录；仅实际通过的最终结果计入本记录。

## 6. 未放宽的安全约束

原签名校验、历史连续性、blob 完整性、完成回执、恢复候选信任边界和失败关闭路径均不放宽。既有 runner 仍是双向传输路径；本轮没有把它转换为 upload-only，也没有宣称完整架构重写完成。
