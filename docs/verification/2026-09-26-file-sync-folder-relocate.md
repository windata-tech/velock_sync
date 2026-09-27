# 文件同步任务更换可写目录（2026-09-26）

## 问题

用户报告：文件同步任务在云端位置安全检查失败后，页面只给出「重新检查此位置」。检查结果已经明确写出“当前位置不能新建备份文件夹 / 需要使用可写的实际文件夹”，却没有任何解决问题的入口；同时页面底部还在说“当前尚不支持直接迁移此文件同步任务的目录”，把用户堵在死路上。

上一轮（`docs/verification/2026-09-26-storage-error-action.md`）只修好了“从首页/详情一步进入检查页”，当时把目录迁移记为功能缺口。本轮补上该缺口。上一轮结束时正给副模型下发实现任务，会话因 429 中断，工作区没有留下该任务的任何改动；本轮由主模型重新实现并验证。

## 修改

- **数据模型**：`SelectedFolderSyncProfile` 增加 `remoteRootSegments`（decoded 相对路径段，默认空 = 连接根）。
  - 旧 profile（含 flat legacy JSON）没有该字段时仍按连接根解码，行为不变。
  - `toJson` 与两处解码都做校验；非列表、非字符串、空段、`.`/`..`、`/`、`\`、控制字符一律 `FormatException`，不会被静默当成连接根。
  - 校验实现抽到 `lib/sync_profiles/model/remote_root_segments.dart`，与 `VelockSyncProfile` 共用同一规则（方法保留，委托到新函数）。
- **同步服务**：`SelectedFolderSyncService.inspectInitialSync` 与 `run` 都用该 profile 自己的 scope 构造远端（`RemoteObjectStoreFactory.scopeProtocol`），并整体包在既有的 `withVelockLocationGuard` 内。
  - 锁在读 profile **之前**获取，覆盖预检与整个 run，避免“读到旧 scope / 写到新 scope”。
  - 未选目录（空 scope）时原样返回连接协议，与改动前完全一致（`path` 仍由默认工厂解析）。
  - 释放行为不变：下载/上传的存储会话仍由原 `finally` 释放；测试断言 run 结束后 location 锁可被再获取。
- **保存路径**：`SelectedFolderSyncProfileRepository.selectSyncFolder` 在 location 锁内重读并校验：profile 必须存在、`active`、与页面持有副本逐字节一致、且没有 running run；否则 `StateError`，不覆盖新状态。
- **界面**：`BackupStorageHelp`（文件同步任务）
  - 新增“选择可写入文件夹 / 更改可写入文件夹”（key `storage-change-folder`），仅 WebDAV 连接显示（OAuth 仍不支持子目录 scope）。
  - 只读浏览可新建空目录 → “使用这个文件夹” → 确认弹窗（key `storage-confirm-folder`，文案明确“只改这个任务的位置、不改连接、不删除或迁移旧数据、保存后仍需另行同步”）→ “保存位置”。
  - 选中连接根（空段）被拒绝并说明原因，不静默保存成“根”。
  - 保存成功后位置文本立即显示新路径，反馈为“保存位置已更新，请重新检查；本次只保存目录，尚未同步”，**不**自动同步、不出现传输结果弹窗。
  - 失败时保留旧 scope 并提示“位置未保存…确认这个任务没有正在运行”。
  - 读取 typed profile 失败时页面仍可用于检查，并说明为什么不能在此改位置，不再无限显示“正在读取…”。
  - 删除“尚不支持迁移”的过时说明；检查失败时直接指向新入口。

## 验证

- 新增 `test/dataset_adapters/selected_folder/selected_folder_sync_profile_scope_test.dart`（12 项）：默认根、往返、legacy、非法段拒绝（含存储侧）、copyWith 保留、落盘重开、确认保存、陈旧页面拒绝、running 拒绝、他页持锁拒绝、键序无关。
- 新增 `test/dataset_adapters/selected_folder/selected_folder_remote_scope_test.dart`（7 项）：空 scope 保持连接协议、带 scope 的 inspect（用真实 `InitialSyncAssessor` 命中预期 vault）、run 使用 scope、run/inspect 在他页持锁时 `SyncRunBusyException` 且不发远端、run 结束释放锁、改目录后下一次 run 使用新 scope。
- 新增 `test/features/cloud_backup/backup_storage_help_folder_test.dart`（6 项）：打开不探测、检查失败给出新入口且无过时文案、选目录+确认后只保存（`check` 调用数不变、无进度弹窗、连接与本地路径未动）、取消不改动、选根被拒、已选目录按自身 scope 检查、保存被拒时保留旧 scope。
- 全量回归：`flutter test` 811 项全部通过；改动范围 `flutter analyze` 无问题。

## 文字按时机出现（2026-09-26 后续）

用户看到成品页后指出“整页文字太多”，并明确要求**不是删文字，而是让文字在该出现的时候出现**。因此按阶段重排了这一页：

- 打开时只说当前状态：卡片标题改为“保存位置”，下面是连接名、实际路径、主按钮“检查此位置”，以及两行入口（选择可写入文件夹 / 浏览此连接的文件夹）。打开时不再出现“云端能否安全写入”“不需要改后台/蜂窝/恢复包”这类前置解释。
- 失败后才出现原因与下一步：检查结果（持久、红色、liveRegion）+ 一句可执行提示“用下面的‘选择可写入文件夹’换一个可写的实际文件夹。”；此时不再重复整段只读入口/NAS 原理说明。真正无法提供入口（配置读不出、OAuth）时才显示完整说明。
- 长说明收进“关于这次检查”卡片：默认只显示一句“只写入并清理一个临时测试文件。”，点“它具体做什么？”才展开完整三条（含“不代表文件已经备份成功”）；同时写明“不会改动后台同步、蜂窝网络或恢复包，也不会修改格间共用的连接”。
- 检查通过后主按钮变为“重新检查此位置”，并另给“开始同步”，保持“检查通过 ≠ 已同步”。
- 文案没有删除，只是改变出现时机；`storage-fix-hint`、`storage-detail-toggle`、`storage-detail-text` 提供可断言锚点。

回归：`flutter test` 812 项全部通过（新增“长说明要用户点开才出现”一项）；改动文件 analyze 无问题。真机侧重新构建安装并重跑 `testFileSyncStorageFolderEntryIsUsable`，通过（33.1 秒），新首屏截图 `ui-storage-help-open.png` 可见：首屏只有标题/连接/路径/主按钮/两行入口/一句可展开说明。

## 提示改为供应商中立（2026-09-26 后续）

用户指出该页把供应商写死成 NAS，而 App 面向的是各种 WebDAV 服务（自建 NAS、Nextcloud、云盘、FN Connect 之类的网关），提示必须通用。

- 失败提示原来两处各写一份（`AppFormat.errorSummary` 与 `backupFailureMessage`），措辞为“请打开共享文件夹…不要只选 NAS 入口”。现在合并为一个共用函数 `uncreatableFolderMessage(BuildContext?)`，只描述用户真正要找的东西：
  - 中：当前选中的位置无法创建文件夹。请进入服务里一个真实存在、且这个账号有权限写入的文件夹；只读入口、共享入口或聚合视图都不行。
  - 英：The selected location cannot create folders. Open a real folder in the service that this account may write to; read-only entry points, share entries and aggregate views will not work.
- 同页可执行提示改为“…换一个这个账号能写入的文件夹。”；非文件同步任务的失败卡片改为“请确认这是服务里一个真实存在、且这个账号有权限写入的文件夹，而不只是只读入口或共享入口。”
- 格间向导的 WebDAV 说明由“网盘或 NAS”扩写为“网盘、NAS 或其他 WebDAV 服务”（该处本来就在 WebDAV 语境，保留 NAS 作为例子）。
- 其余 NAS 字样只出现在 WebDAV 连接表单/连接说明/内部注释等技术语境，不冒充对某个供应商的检测结果。
- 回归：`backup_failure_message_test` 除断言新文案外，额外断言中英文界面里**不再出现 NAS／共享文件夹**字样；`backup_storage_help_test` 与界面回归同步更新。`flutter test` 812 项全部通过（新增 2 条中立性断言），改动文件 analyze 无问题；真机侧重新构建安装并重跑 `testFileSyncStorageFolderEntryIsUsable` 通过（33.1 秒），确认换目录与确认弹窗路径未受影响。

## 真机/现场边界

- 用户当前 iPhone 17 Pro Max 模拟器（`26CC5821-DEF4-47D3-978D-A11D7293AD61`）已安装新版 Debug 包，保留原有配置与 111 目录，没有修改用户任何 profile。
- 本机没有 Simulator GUI（`xcodebuildmcp` brew 版参数面已变更，`Simulator.app` 不存在），因此用 XCUITest 新增 `testFileSyncStorageFolderEntryIsUsable` 驱动**真实已安装应用**核对这条路径，已通过（33.2 秒）：
  - 现场文件同步页 → “检查保存位置” → 真实页面可见“选择可写入文件夹”，且**不再出现**“尚不支持直接迁移”的过时文案（无障碍树实测）。
  - 只读浏览真实 NAS：连接根可见 `USB_HDD_8T`、`Photos`、`System`、`来自：百度网盘`；进入 `USB_HDD_8T` 后可见用户自己的 `111` 与 `222`。
  - 选中 `111` → “使用这个文件夹” → 真实确认弹窗显示 `新建连接 /USB_HDD_8T/111`、“不改动连接本身，也不会删除或迁移旧文件夹里的数据。保存后仍需另行开始同步。”；测试点“取消”，未保存、未同步、未写远端。
  - 截图与结果：`../velock_sync-artifacts/work/folder-relocate/`（`ui-storage-help-open.png`、`ui-writable-folder-connection-root.png`、`ui-writable-folder-inside-share.png`、`ui-relocation-confirmation.png`、`ui-relocation-cancelled.png`、`result.xcresult`）。
- **未在真实 NAS 上完成一次“换目录后同步成功”**：本轮没有替用户保存新位置、没有点“开始同步”、没有做内容级恢复验收。换到新空目录等于从该位置重新开始，旧目录数据不会自动迁移；`remote.velock_history_incomplete` 等历史完整性门禁没有放宽。

## 用户接下来的操作

1. 文件同步页 → “检查保存位置” → “选择可写入文件夹”。
2. 进入 `USB_HDD_8T`（不要再进入 `velock-sync`），选择 111 或新建一个空文件夹。
3. “使用这个文件夹” → 确认路径 → “保存位置”（只保存位置，不会同步）。
4. 回到本页点“重新检查此位置”；通过后再单独点“开始同步”，此时是从新位置重新开始传输。
