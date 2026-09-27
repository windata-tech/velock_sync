# 上线标准复查：明文同步的安全与错误路径（2026-09-27 夜）

用户要求以「格间项目的上线标准」再自查一遍，两个轴：流程是否最小但完整（没有学习负担）、
是否还有大 bug。四路只读审计并行进行（引擎正确性 / 失败与健壮性 / 上线就绪与本地化 /
跨 App 安全），随后按审计结论修复并逐条回归。

**结论摘要**：明文同步的**主路径**（列表 → 三步向导 → 卡片立即同步 → 详情）本来就是最小且完整的，
不需要学习成本；问题全部集中在**中段与边缘**——远端消失时静默删本机、确认删除点了没反应、
进程被杀后永久卡死、网络黑洞无限挂起、错误码直接怼到用户脸上、英文界面一半中文。
这些已全部修复；剩余的已知边界写在本文件末尾。

## 一、数据安全（最高优先级）

| 问题 | 现场后果 | 修复 | 回归 |
| --- | --- | --- | --- |
| 远端列不出来被当成「远端是空的」 | 远端共享未挂载 / 目录被改名 / 代理丢掉 href 时，plan 出 `deleteLocalEntry`，运行**成功完成并报告「删除 N 项」**，本机文件静默消失（基线 <5 条时连 20% 阈值保护都不生效） | `WebDavObjectStore.list` 对 PROPFIND 404 抛 `RemoteObjectNotFoundException`；引擎映射 `plain_folder.remote_folder_missing`；远端空 + 本机非空 + 有基线 ⇒ 直接失败不删；`MirrorListingScope` 只允许删除**本次真正列过**的目录下面的路径；深度截断报 `plain_folder.remote_too_deep` | `plain_folder_sync_service_test.dart`、`mirror_planner_test.dart`、`webdav_object_store_keys_test.dart` |
| 「确认删除并继续」什么都不做，再点一次未经复核就删 | `_busy` 为真时递归调用 `_run`，第二次运行被守卫直接返回；用户再点一次时走的是**新的、没看过的计划** | 删除批准改为携带路径集合：`runConfirmedDeletions(profileId, confirmedPaths)`；`MirrorHeldDeletions.paths` 是唯一可批准的集合，计划变大就重新扣下；界面在同一 busy 窗口内「跑 → 列路径 → 只批准这些路径再跑」 | `plain_sync_home_test.dart`（列出路径 / 只批准这些路径 / 取消不删）、`mirror_planner_test.dart` |
| 上传不校验 | 服务器保留被截断的 PUT 正文时，残件成为基线，下一轮把好的本机文件覆盖，或改名成「本机冲突」后让残件占用原名 | PUT 后 `stat` 比对远端大小与本机长度；不一致则 best-effort 删除残件、报 `plain_folder.upload_incomplete`、**不写基线** | `plain_folder_sync_service_test.dart` |
| 文件/目录同名冲突被判定为「一致」 | 计划里进 `inSyncPaths`，子项上传 409，被翻译成「远端文件夹不存在或不能写入，请重新选择」，位置永久卡死且建议是错的 | 类型不一致 ⇒ 可见冲突（`bothModified`/`keepBoth`）、不进 `inSyncPaths`、整棵子树扣下、不再映射成文件夹级错误 | planner ×3 + service ×1 |
| 换文件夹是两步写 | 第一步成功第二步失败 ⇒ 提示「没有保存成功」（撒谎），旧基线指向新文件夹 ⇒ 下一轮删远端文件 | `PlainFolderSyncProfileRepository.relocate(...)`：租约内先远端可写预检，然后**一个事务**保存并清 `mirror_entries`/`mirror_conflicts`/`mirror_run_stats` | `plain_folder_sync_profile_test.dart` ×4 |
| 明文位置与格间备份/另一个位置重叠 | 明文镜像会把加密对象当普通文件读；两个位置互相包含时各自用独立基线互相删 | `assertPlainScopeAvoidsBackups` + `assertPlainScopeAvoidsOtherLocations`（等值/祖先/后代、大小写不敏感）；**同一远端 + 不同本机仍允许**（多设备是文档化用法），同一本机 + 同一远端属重复绑定；`backups` 参数改为 required，守卫在写探针**之前** | `plain_folder_scope_guard_test.dart`、`plain_folder_provisioner_test.dart` |
| 本机替换先删目标 | 删除与 rename 之间被杀 ⇒ 真名消失、内容藏在 `.velock-tmp`（扫描器忽略），下一轮连远端一起删 | Dart/桌面只做 `rename`（本身即覆盖）；Android SAF 因 provider 会把 rename 变成 `name (1).ext` 副本，改为原地写回已有文档；失败返回 `provider.saf.replace_failed` 且不删暂存件 | `selected_folder_storage_test.dart`（含反向验证） |
| 带 `#`/`?` 的文件名写到别的路径 | `Uri.resolve('a#b.png')` 把 `#` 当 fragment：写错对象、两个名字互相覆盖、基线记在错对象上 | key 视为**解码后的相对路径**，逐段编码（`_objectUriFor`）；MOVE 的 Destination 始终是编码 path | `webdav_object_store_keys_test.dart`、`webdav_destination_path_test.dart` |

## 二、状态机与失败路径

- **进程被杀后永久卡死**（审计标为最高价值修复）：`sync_runs` 的 `state='running'` 孤儿行让位置永久显示「正在同步」，
  并让改方向/冲突与删除永久失败（`hasRunningSyncRun` 不设时限）。现在 `main.dart` 与后台 isolate 启动时调用
  `SyncStateDatabase.failInterruptedSyncRuns()`：写 `sync.interrupted` + 清死进程的 `profile_locks`。
  回归 `sync_state_interrupted_runs_test.dart`（4 项，含幂等与租约清理）。
- **无限挂起**：所有同步客户端（共享工厂、明文、格间）现在都带 `connectTimeout 30s` / `receiveTimeout 5min` / `sendTimeout 5min`。
- **错误文案只有一份、且不含错误码**：`plainFailureMessage(context, code, {connectionName})` 覆盖 38 个码 + 家族回退
  （离线、超时、证书、401/403/404/409/412/429/507、本机空间不足、远端文件夹消失、上传不完整、运行中、被系统中断…），
  正文永不出现 `sync.unexpected` 这类内部码；原始异常先经 `SyncFailureClassifier.classify`（丢包 → `network.offline`，
  超时 → `network.timeout`，取消 → `remote.operation_cancelled`，状态码 → `provider.http.<code>`）；
  `AppFormat.errorSummary` 补 507 与离线，格间域共用。
- **认证失败不再被折叠成「文件夹不存在或不能写入」**（那会把用户引去换一个本来好好的文件夹）。
- **失败不再撒谎**：下载字节只在写成功后计数；失败运行保留「有删除等待确认」计数；`skippedCount > 0` 时
  不再输出「两边内容已经一致。」；profile 解码失败会记 id + 类型而不是静默消失。

## 三、流程与界面

- 三步向导在没有 WebDAV 连接时**不再是死路**：空状态直接给「添加 WebDAV 连接」（key `plain-add-connection`），
  从表单返回后原地刷新连接列表；文案改成指向真实存在的入口。
- 删除确认表现在**列出具体路径**（前 20 条 + 剩余数量、可滚动、destructive 按钮），不再只给一个数字。
- 导航栏标题允许两行、高度用 `minHeight`；返回键后面不再补 8pt（会把 leading 槽撑到 52pt 溢出）；
  向导的「第 N 步，共 3 步」移到正文并固定在列表上方——放在导航栏 trailing 槽时，路由转场逐帧收窄会让它溢出。
- 英文界面补齐：设置页（61 处）、连接说明（210 处）、活动记录（53 处）、连接详情（46 处）、百度 token 页（26 处）、
  文件同步页 6 处（含会被**存进数据库**的默认名字）。`sync_settings_english_test.dart` /
  `sync_english_pages_test.dart` / `plain_sync_english_test.dart` 会逐屏（含 Semantics 标签）扫描，发现中文即失败。
- 设置页「新配置默认策略」不再承诺做不到的事：新同步位置默认**关闭**后台同步，页脚现在明说要到详情页打开该开关。

## 四、上架材料

- `ios/Runner/PrivacyInfo.xcprivacy`（DiskSpace / FileTimestamp / UserDefaults required-reason）并已加入 Xcode 工程。
- `docs/release/app-review-notes.md`：ATS（`NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking`）的书面理由、
  后台模式用途、无账号无分析、以及评审如何在没有 NAS 的情况下看到文件同步。
- Android 启动器名称改为 `@string/app_name`（"Velock Sync"，原先显示包名 `velock_sync`）。
- 删除空包依赖 `sqlite3_flutter_libs`；`_provisionNasConnection` 与 `VELOCK_SYNC_EVENT` 只在 debug 生效。

## 五、验证

- `flutter analyze lib test` → No issues found。
- `flutter test` → **1085 项全部通过**（新增/改写：`sync_state_interrupted_runs_test.dart`、
  `plain_folder_scope_guard_test.dart`、`webdav_object_store_keys_test.dart`、`plain_sync_home_test.dart`
  的确认删除两项、以及各 agent 的引擎/存储/本地化回归）。
- 未跑真实 NAS：本轮全部使用内存数据库、假远端与本地 WsgiDAV；未对用户 NAS 写入或删除任何内容。

## 六、已知未完成（不影响主路径，但要在上线前决定）

1. **iOS「打开本机文件夹」用的是未公开的 `shareddocuments://`**（AGENTS 已有标注）。上架标准建议换成
   文档化的 `UIDocumentPickerViewController.directoryURL`（打开的是选择器而非文件 App）；需要真机确认。
2. **运行中不能取消**：`RemoteOperationCancellation` 仍未接到界面；断网现在会因超时失败，但大文件传输中途无法主动停止。
3. **>64MiB 的「同尺寸、时间不同」文件**按延迟校验处理：不会误删，但两边不会自动收敛（结果页现在会说明有 N 项本次没有比较）。
4. **`flutter_platform_widgets` 已停止维护**（无替代包），全部页面依赖它；无法通过升级解决，只能在未来迁移。
5. **明文位置只支持 WebDAV**（云盘不支持），向导与错误文案已如实说明。
6. 审计中发现但未修：`velock_sync` 只丢弃 `screen`/`lock` 意图；`webdav_client_plus` 仍停在 1.x；
  设置页显示的版本号来自 dart-define，发布脚本没有传，bump 版本后会显示旧值。
