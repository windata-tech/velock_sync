# 文件同步改为普通明文镜像：实现与验证（2026-09-27）

状态：本轮为**架构方向纠正 + 第一版实现**。设计与语义见 `docs/design/plain-folder-sync.md`；本文件只记录做了什么、验证到什么程度、以及**不能据此宣称什么**。

## 1. 用户明确要求

用户在看到旧的「检查云端位置 / 保存位置」页面后指出功能设计错误：

> 「我要的是用户可以添加多个同步位置（可能是多远程位置），然后每个里面都是跟本地的某个目录进行绑定起来的……比如用户手机里有一个文件夹 A，然后给他绑定远程的某个目录 B，然后他们俩可以进行同步」

并在澄清问题中明确：

> 「错了啊，这里根本不需要加密啊。。。就单纯的同步软件啊，你加密搞什么啊」

用户同时同意按市面默认处理方向与冲突：双向同步（默认）/ 仅上传 / 仅下载；冲突默认保留两份；首次绑定两边都有内容时让用户选择合并 / 本机覆盖 / 远端覆盖。

## 2. 本轮实现范围

- **新数据模型**：`SyncDatasetKind.plainFolder`（持久化 `plain-folder`）+ `PlainFolderSyncProfile`
  （本机文件夹引用与显示名、连接、远端子路径、方向、冲突策略、首次同步策略、后台策略）。
  明文同步没有 vault/密钥，`vaultId` 为空是该 kind 的正确表示；envelope 现在按 kind 校验 vaultId。
- **新引擎**（`lib/dataset_adapters/plain_folder/`）：
  - `mirror_models.dart`：纯逻辑 planner（本地/远端/基线三方比较、方向、冲突、删除保护、目录规则）。
  - `plain_folder_sync_service.dart`：扫描两端 → 内容同一性核对 → 计划 → 执行（建目录/删除/上传/下载）→ 写基线 → 统计与冲突记录；失败写 `sync_runs` 失败态。
  - `plain_folder_provisioner.dart`、`plain_folder_sync_profile_executor.dart`（注册进共用 dispatcher，前台/后台同一条执行路径）。
- **远端能力补齐**：`RemoteObjectMetadata.isDirectory`（WebDAV 解析 `<resourcetype><collection/>`）、可选 `RemoteCollectionCreator.createCollection`（单次 MKCOL，405/409 不当作成功）、集合 DELETE 接受 200/202/204/404。
- **本机能力补齐**：可选 `StreamingSelectedFolderStorage.writeFileFromStream`（临时文件 + 原子替换，失败不留残件）；Android SAF 明确**不支持**流式写（不假装支持，回退为整文件写入）。
- **数据库 schema v12**：`mirror_entries`（每路径基线：大小/时间/etag）、`mirror_conflicts`（冲突记录，有上限裁剪）、`mirror_run_stats`（每次运行计数）。运行记录复用 `sync_runs`。
- **界面**：`/files` 改为 `PlainSyncHome`（同步位置列表 + 「添加同步位置」+ 折叠的旧版加密同步区域）；新增 `/plain-locations/new`（三步向导：本机文件夹 → 远端文件夹 → 方向/冲突/名称）与 `/plain-locations/:profileId`（详情：两端位置可更换、方向与冲突可改、最近一次同步、冲突记录、后台策略、删除）。
- **旧加密配置**：协议与数据不动，继续可运行，只在列表里单独折叠展示，并保留进入旧页面管理/加入的入口。

## 3. 关键安全语义（实现即约束）

| 语义 | 实现位置 |
| --- | --- |
| 没有基线的路径**永不判为删除**（首次同步只合并） | `mirror_models.dart` planner：删除分支都要求 `baseline != null` |
| 删除超阈值（>1000 项或基线 20%，基线 <5 条时只看 1000）时扣下全部删除，且**保留基线行** | `_heldDeletions` + `effectiveRemovedBaselinePaths` |
| 只有用户确认的那次运行（`allowDeletions: true`）才真正删除 | `plan(allowDeletions:)`；UI 在结果弹窗确认后重跑一次 |
| 冲突默认保留两份，不静默覆盖 | `keepBoth` → 本机版本另存 `名称 (本机冲突 日期 时间).扩展名`，远端版本写回原名 |
| 一边删除、另一边修改时不丢数据 | `deleteVersusModify` → 恢复被修改的一方并记录冲突 |
| 上传后回读远端时间/etag 再写基线，避免“刚上传又被当成远端改动下载回来” | `_recordBaselineAfterUpload` |
| 下载后重新扫描本机元数据再写基线 | `_apply` 末尾的定向重扫 |
| 只读/不可写远端在向导阶段就暴露 | `checkRemoteWritable`（写一个探针并读回校验，随即删除） |

## 4. 验证结果（本轮实际执行）

- `flutter analyze lib` → **No issues found!**
- `flutter test`（全仓库）→ **964 项全部通过**（含新增的明文同步测试与一次真实 WsgiDAV 往返）。
- 新增测试：
  - `test/dataset_adapters/plain_folder/mirror_planner_test.dart`：36 项，覆盖方向 × 冲突 × 删除保护 × 首次同步 × 目录规则 × 统计口径。
  - `test/dataset_adapters/plain_folder/plain_folder_sync_profile_test.dart`：25 项（序列化、默认值、拒绝非法值、仓库读写/暂停/移除/受保护更新）。
  - `test/infrastructure/database/sync_state_mirror_test.dart`：10 项（基线、冲突、运行统计、v11→v12 升级）。
  - `test/dataset_adapters/plain_folder/plain_folder_sync_service_test.dart`：16 项，端到端引擎测试（假远端树 + 真实临时目录）。
  - `test/dataset_adapters/plain_folder/plain_folder_webdav_integration_test.dart`：1 项，真实 WsgiDAV 往返（服务未启动时自动 skip）。
  - `test/providers/webdav/webdav_object_store_test.dart`：新增根目录列举与空 key 拒绝回归。
  - `test/features/plain_sync/*`：22 项界面测试 + 1 项截图/视觉 QA（列表、添加向导三步、详情、删除、方向/冲突切换）。
- 由测试暴露并**本轮修掉**的真实缺陷：
  1. `allowDeletions` 参数被接收但从未使用 → 「待确认删除」永远无法收敛（planner 现在在确认运行时真正放行）。
  2. 被扣下的删除仍然删除基线行 → 下一次运行会把文件当新文件重新下载，等于静默撤销用户的删除（现在保留基线行）。
  3. 「已验证相同」的配对从不写基线行 → 每次运行都重新读远端内容比对、永不收敛（现在 planner 返回 `inSyncPaths`，只对这些**被证明**相同的路径写基线；被延后或方向跳过的路径明确不写，避免把内容不同的文件误记成一致）。
  4. `_recordBaselineAfterUpload` 在远端 `stat` 失败时用本机时间伪造远端元数据 → 下一次正常运行会把刚上传的文件再下载回来（现在失败就不写该行，留给下次的内容比对确认）。
  5. 方向跳过的路径同时被计为「未变化」，目录跳过则完全不计（现在只计为跳过）。
- 由测试暴露并**本轮修掉**的健壮性问题：`PlainFolderSyncProfileRepository._decode` 的 JSON 解析在 try 之外（一行坏数据会让整个列表抛错）；`remove()` 未与运行加同一把 per-profile 锁。

## 5. 真实 WebDAV 服务端到端验证

`tool/local_webdav/start_local_webdav.sh start` 起本机 WsgiDAV（不碰用户 NAS），再跑
`flutter test test/dataset_adapters/plain_folder/plain_folder_webdav_integration_test.dart`：

一次真实 HTTP 往返里验证了：MKCOL 建远端目录 → 上传嵌套文件（PUT 201）→ 第二次运行零传输 → 远端新增文件下载到本机 → 本机修改后覆盖上传（PUT 204）→ 本机删除同步删除远端 → 两边同时改同一文件时按“保留两份”处理（远端版本留在原名、本机版本另存 `本机冲突` 副本），最后只删除本测试自己创建的目录。

**这次真机验证发现并修掉了一个既有 provider 缺陷**：`WebDavObjectStore.list(prefix: '')` 一直抛 `must be a normalised relative key`（空 key 被 `split('/')` 判成非法段），也就是说**列连接根/同步位置根目录从来就不可能成功**，此前没有调用方用空 prefix 所以没暴露。现在 `allowEmpty` 时空 key 放行（仅此一种），其余空 key 与越界 key 仍 fail closed，并在 `test/providers/webdav/webdav_object_store_test.dart` 补了根目录列举与空 key 拒绝的回归。

服务未启动时该测试自动 skip，所以常规 `flutter test` 仍然是无网络依赖的。

## 6. 界面人工核对（真实字体渲染）

`test/features/plain_sync/plain_sync_visual_qa_test.dart` 以真实中文字体渲染并输出四张图，存放于 `ui_audit/plain-sync-20260927/`：

| 图 | 内容 |
| --- | --- |
| `01-home-empty.png` | 文件同步空状态：「添加第一个同步位置」 |
| `02-home-two-locations.png` | 两个同步位置（双向「手机照片」、仅上传「工作文档备份」+ 待确认删除 + 冲突徽章） |
| `03-detail.png` | 详情页：本机/远端两半、方向三选一、冲突三选一 |
| `04-detail-held-deletions.png` | 仅上传位置的详情：待确认删除状态与主操作 |

另外在已启动的 iPhone 17 Pro Max 模拟器上安装 Debug 包，用 `--route=/files` 与 `--route=/plain-locations/new` 直接进入新页面截图核对（`sim_files_tab.png`、`sim_wizard.png`），确认真机字体、分组标题与按钮渲染正常——把测试渲染里的方块字形对比确认为测试字体缺字，而非产品问题。

同一次人工核对中发现并修掉的一处真实布局缺陷：卡片内两个并排按钮中只有第一个被 `Expanded` 包裹，`BackupActionButton` 的 `width: double.infinity` 导致「详情/暂停」按钮在 `Row` 里触发无限宽度断言（首页卡片、详情状态卡、向导底部按钮同一模式，已全部修正）。

## 7. 界面测试暴露并修掉的界面缺陷

界面测试（22 项）在写完后立刻暴露了四个真实问题，均已修复并更新断言：

1. **详情页“继续”按钮点了没反应**：详情页用受保护的 `update()` 改生命周期状态，而它拒绝非 active 的 profile，于是暂停后无法从详情页恢复（方向/冲突也一起被挡住）。现在暂停/继续走 `pause()`/`resume()`，`update()` 允许暂停中的位置继续改设置，仍拒绝陈旧页面/运行中/已删除。
2. **第 3 步名称输入框不显示默认名**：控制器在第 1 步构建时创建，而默认名（本机文件夹名）是选完文件夹才有的，进入第 3 步时补种默认值。
3. **英文/大字号下状态徽章行溢出**：两张卡片的徽章行改为 `Wrap`（可换行），不再用固定 `Row`。
4. **方向/冲突说明被截断成省略号**（用户现场反馈）：`AdaptiveListTile` 在 iOS 上把副标题压成一行，把“本机删除会同步删除远端文件”“本机独有的新文件不会被删除”这些关键语义截掉了。现在选项统一用新的 `PlainOptionRow`（单选图标 + 标题 + 完整换行说明），向导与详情页共用；回归 `test/features/plain_sync/plain_option_row_test.dart` 断言说明文字 `maxLines == null`、没有 ellipsis、行高大于单行。
5. **向导里的失败文案指错地方**：远端预检失败原本照抄服务的“请在详情页重新选择”，而用户还在 3/3 向导里；现在向导显示“请返回上一步，选择另一个真实存在、可写入的文件夹”。

另外，同一批测试确认了此前修掉的按钮无限宽度缺陷（`BackupActionButton` 的 `width: double.infinity` 放在 `Row` 里必须包 `Expanded`，首页卡片、详情状态卡、向导底部三处）。

## 8. 现场反馈后的第二轮修复（创建报错 / 退不出去）

用户现场：连点「创建同步位置」后看到「创建同步位置失败，请重试。」，而且退到第 1 步后无法再退出。核查模拟器容器里的 `state.db`：**三个 `kind=plain-folder` 的 profile 都已成功写入**，说明保存本身没失败，报错来自保存之后的 `context.pop(true)`——当时应用是被我用 `--route=/plain-locations/new` 直接打开的，向导就是根路由，没有可以 pop 的上一页，于是抛错并被通用 catch 显示成“创建失败”；同一个原因也让页头返回无处可去。

修复：
- 保存放在 try 内、导航放在 try 外；`leaveWizard()` 能 pop 就 pop，不能 pop 就 `go('/files')`——**已保存的配置绝不会再显示为创建失败**。
- 向导页头始终提供返回：第 >1 步退一步，第 1 步离开向导；切换步骤清掉上一次的错误文案。
- 通用失败文案之外，本机文件夹失效（`FolderRootUnavailableException`）单独给出“返回上一步重新选择本机文件夹”。
- 期间还在模拟器上核对：上述三个重复 profile 就是这三次“看似失败”的点击留下的；新包已重新安装，文件同步 tab 正常列出它们。
- 三项目标明确的回归（`add_plain_location_test.dart`）在临时副本里做过变异验证：把导航放回 try 内 → 测试 1 在第 0 帧就抓到「创建同步位置失败」；让 `goBack()` 不再离开向导 → 测试 2 失败；让 `goBack()` 不清错误 → 测试 3 失败。即这些测试确实锁住了本次 bug，而不是顺带通过。
- 顺带补上设计里一直没实现的一条约束：**同一个绑定不许重复创建**。`PlainFolderProvisioner` 现在比对（本机授权引用 + 连接 + 远端子路径段），命中即抛 `DuplicatePlainLocationException` 并在向导里说明已有哪个位置；同一本机配不同远端、同一远端配不同本机仍然允许（多设备/多备份是正常用法），暂停中的旧位置也不拦新位置。回归 `plain_folder_provisioner_test.dart`（5 项）。

## 9. 旧版加密同步彻底退出文件同步页（用户要求）

用户看图指出文件同步页底部那块「旧版加密文件夹同步」没用了。处理方式：**从文件同步 tab 整段移除**（标题、说明、旧任务卡片、管理入口），但**不静默遗留后台运行**——唯一入口移到「设置 → 旧版加密文件夹同步 → 管理旧版加密同步（N）」，只在确实存在非 isolated 的旧任务（含已暂停）时渲染，点进去仍是原来的页面可以查看/删除/加入。这样新用户永远看不到旧概念，老任务也不会变成“看不见但还在跑”的隐藏状态。截图：`ui_audit/plain-sync-20260927/sim_files_tab.png`（干净的文件同步页）与 `sim_settings_legacy.png`（设置里的唯一入口）。

## 10. 添加入口移到页头（用户要求）

用户觉得列表下方那整行「添加同步位置」太笨重，要求挪到右上角一个加号。现在页头右侧是「刷新 + 加号」（`plain-location-add`），列表下方那一行已删除；**列表为空时仍保留首屏说明卡和其中的大按钮**（新用户需要那句“本机文件夹 + 远端文件夹”的解释）。回归：`plain_sync_home_test.dart` 既有首屏用例 + 新增「列表非空时页头加号能打开向导、返回后位置仍在」用例。截图 `ui_audit/plain-sync-20260927/sim_files_tab.png`、`sim_files_add_tapped.png`。

## 11. 卡片宽度与正文对齐（用户现场指出）

用户指出位置卡片比上方正文窄。实测（截图像素 + widget 布局）确认：`BackupCard` 自身已经带 16pt 水平外边距（等于页面边距），`_LocationCard` 又在外面套了一层 `padding: horizontal 16`，于是卡片表面比正文多缩进 16pt。去掉多余那层后，卡片表面与段落文字左右完全对齐；回归断言 `card.left + AppSpacing.page == intro.left`、`card.right - AppSpacing.page == intro.right`（`plain_sync_home_test.dart` 的「the location card lines up with the page text」）。截图 `ui_audit/plain-sync-20260927/sim_files_tab.png`。

## 12. 格间首页去重（用户要求）

用户指出格间首页「上次传输已完成 + 立即备份」卡片与下面那行「备份详情与管理」重复累赘，要求融合。现在 `BackupStatusCard` 支持一个并排的次操作，格间首页卡片变成「立即备份 + 详情」，独立的详情行删除，页面只剩状态卡 + 「从云端恢复」。这与明文同步位置卡片同一形态（主操作 + 详情）。截图 `ui_audit/plain-sync-20260927/sim_velock_home_merged.png`。

## 13. 进度改到按钮上（用户要求）

用户看到「正在同步…」阻塞弹窗，要求删掉、把状态做到「立即备份」按钮上，并说明其他同类弹窗也照此处理。改动：`runSyncWithProgress` 与明文同步 runner 不再弹进度框；`BackupActionButton` 增加 `busy`（内联 spinner + 禁用重入），`BackupStatusCard` 在 `BackupStage.transferring` 时把主按钮置 busy（卡片标题同时是「正在传输，请稍候」），明文首页/详情按钮显示「正在同步…」；设置页/详情页/历史说明页里那几个会跑同步的按钮同样带上 busy；`showAdaptiveBlockingProgress` 这个已无调用方的阻塞弹窗组件删除。保留：失败弹窗（必须确认，AGENTS 既有要求）与明文「待确认删除」确认框。相关测试从「断言弹窗」改为「断言按钮 busy / 卡片正在传输」；顺带修掉一个由本次改动引入的真实回归——`BackupActionButton` 空闲时若也包 `Row`，会把列表挤动一点点，导致文件夹选择器里相邻行的点击落到被禁用的底部按钮上（已改为空闲时保持原来的单个 `Text` 布局）。截图 `ui_audit/plain-sync-20260927/sim_velock_home_merged.png`（无弹窗的首页）。

## 14. 用格间真实品牌图标（用户要求）

按用户要求从格间项目取图标：彩色源 `velock_codex/assets/images/app_logo.png`（绿盾 + 白 V）→ `assets/branding/velock_mark.png`，用在格间状态卡徽章（彩色）；**扁平版是同一源派生**（白底/白 V 抠透明后填单色 → `velock_mark_flat.png`），底部「格间」tab 用它并跟随选中态着色（格间项目里没有现成的线稿版，这一点如实说明）。同时在修一个由上一轮引入的行为问题：明文首页把页面级 `_busy` 传给每张卡，两个位置时会同时显示「正在同步…」；现在只有真正在跑的那张卡显示进度，其他卡仅禁用。截图 `ui_audit/plain-sync-20260927/sim_velock_home_merged.png`。

## 15. 文案动词按领域区分（用户现场指出）

用户指出格间详情页的「暂停传输」应为「暂停备份」。按同一原则统一：格间域用「备份」（暂停备份/继续备份、上次备份已完成、暂时无法继续备份、恢复引导“请先继续完成现有备份”），文件夹域用「同步」（暂停同步/继续同步、上次同步已完成）；真正描述传输过程的句子（“系统可能暂停传输”“传输记录”）保持「传输」。截图 `ui_audit/plain-sync-20260927/sim_velock_detail_wording.png`。

## 16. 明细弹层的列对齐（用户现场指出）

用户指出「已同步对象明细」里的文字没对齐：原因不是缩进，而是每一行把「大小 · 时间」拼成一个字符串，字节数字长度不同（296 B / 767 B / 1.4 KB）导致时间参差。现在 `AppDetailSheetRow` 支持 `trailing`（右侧固定列、tabular figures），该弹层变成【对象类型 · 方向｜时间｜大小】三列；`test/features/sync_profiles/synced_objects_sheet_test.dart` 断言三行金额右边缘一致、时间左边缘一致（±0.5px）。

## 17. 云端保存位置指向备份目录（用户现场指出）

用户点「云端保存位置」发现落到连接根目录（FN Connect 的 `USB_HDD_8T / Photos / …`），而不是格间备份真正所在的 `USB_HDD_8T/111`。根因：那一行只 push 了 `/connections/connection/<id>`，完全没用 profile 的 `dataset.remoteRootSegments`。现在副标题显示该相对路径，点击用 `?segments=` 传目录、由 `Connection` 解析为绝对路径后跳转；非法/越界 segments 被忽略并退回连接根。截图 `ui_audit/plain-sync-20260927/sim_velock_location_row.png`。

## 18. 旧版加密同步彻底下线（用户要求）

用户看到设置里仍有「旧版加密文件夹同步 / 管理旧版加密同步（1）」，明确表示淘汰的功能不要保留。改动：删除设置页那一整段与 `legacyEncryptedProfilesProvider`；`SyncProfileSummary.isBackgroundEligible` 排除 `selectedFolder`（没有任何入口能暂停/删除的任务不得继续后台运行）；全仓库不再有面向用户的「旧版/legacy」文案。**本机行与远端加密对象未删除**（无新增破坏性逻辑）。回归 `legacy_encrypted_entry_test.dart`（3 项，含“设置页不出现旧版字样”“有旧任务时也完全不展示”“旧任务不进后台调度而明文位置仍进”）与 `background_sync_test.dart`（13 项）。截图 `ui_audit/plain-sync-20260927/sim_settings_no_legacy.png`。

## 19. 连接列表补上「修改连接」（用户现场指出）

连接行的「更多操作」此前只有「删除连接」，用户问“没有修改？”。现在菜单里同时提供「修改连接」：WebDAV 打开预填的 WebDAV 表单（`replace=<id>`），OAuth 打开该 provider 的重新授权（provider + `replace=<id>`），与连接详情页铅笔入口完全一致，没有新增编辑页面。回归 `test/features/connection/connection_edit_entry_test.dart`。

## 20. 连接菜单补上「连接说明」（用户要求）

用户要求把连接页那个「连接说明」也放进列表的「更多操作」菜单。说明内容抽成共享的 `showConnectionInfoSheet(context, protocol)`（`connection_info_sheet.dart`），详情页信息按钮与列表菜单共用一份实现；内容仍是“适配器技术说明、不是本服务器检测结果”，不探测、不写远端。回归 `test/features/connection/connection_edit_entry_test.dart`（新增一项）与既有 `connection_oauth_info_test.dart` 全部通过。

## 21. 禁用态改成淡出而不是变灰（用户要求）

用户指出不可点击时图标“太灰”，要求保留原色、只加透明（系统风格）。根因是 `CupertinoButton(onPressed: null)` 用 `quaternaryLabel` 重绘 child。现在图标显式带自己的颜色（文件夹=主色蓝），禁用时只叠 `AppOpacity.disabled`；覆盖 `AdaptiveIconButton`、`AdaptiveActionMenu`（…菜单）与远端文件卡片。实现上卡片保持同一 widget 形状、只改 opacity 值，避免刷新时重建列表元素（`connection_loading_test.dart` 的 element 同一性断言通过）。回归 `test/widgets/disabled_artwork_test.dart`（4 项）。

## 22. 两半文件夹都能「打开」（用户要求）

详情页「本机文件夹 / 远端文件夹」加了「打开」：远端走 App 内已有浏览器（`segments` 机制，与格间「云端保存位置」一致）；本机交给系统文件管理器（Android tree URI / Apple bookmark→`shareddocuments://` / 桌面 `file://`），失败只提示路径。回归 7 项（5 项 hand-off 单测 + 详情页点击 2 项）。**边界：iOS 的 `shareddocuments://` 属未公开 scheme 的尽力而为，本轮只有代码路径与单测，没有真机/模拟器确认“文件 App 已定位到该目录”**；Android 侧同样未在真机验证具体文件管理器是否受理 tree URI。截图 `ui_audit/plain-sync-20260927/sim_plain_detail_open.png`。

## 23. 方向/冲突改为草稿 + 保存（用户要求）

详情页「同步方向 / 冲突处理」改成草稿式：改动只在页面上生效，页头出现「保存」按钮；未保存离开（页头返回或系统返回）弹「保存 / 不保存 / 取消」。保存结果回读 provider 确认，失败保留草稿；结构类操作（换文件夹、暂停、删除、立即同步）仍即时生效。回归 6 项（见 `plain_location_detail_test.dart`）。

## 24. 管理与概览的入口去重 + 真正能换目录（用户指出）

用户发现详情页和「管理」页都有「云端保存位置」，而且**没有任何地方能更换备份目录**。现在：概览页保留只读的「云端保存位置」（显示实际路径、点进去定位目录）；「管理」页改成「更换保存位置」并真正执行换目录。换目录流程与 `BackupHistoryHelp` 共用 `changeVelockBackupLocation`（只保存 profile 的 `remoteRootSegments`，不动共享连接、不启动同步、不迁移旧目录数据）；保存失败以 `saveFailed` 回传给调用方各自呈现（帮助页行内、管理页提示）。回归：管理页入口断言 + 帮助页 3 项（确认框改为 `backup-location-confirm`／「保存位置」）。

## 25. 明确未完成 / 不能宣称的部分

- 没有在真实 NAS 上执行过明文文件夹同步（没有创建/删除用户 NAS 上的任何文件）。已完成的真实服务端验证是本机 WsgiDAV（见 §5）；模拟器上只做了界面渲染与安装核对，没有在模拟器里跑通一次真实上传下载。
- 只支持 **WebDAV**：OAuth 云盘（Google Drive / OneDrive / 百度 / 阿里）在明文文件夹语义下需要新的文件级适配，界面明确拒绝（`plain_folder.remote_unsupported`）。
- 后台运行受 iOS/Android 系统调度限制，本轮只保证「同一条执行路径 + 前台可手动运行」，未验证长时间后台行为。
- Android SAF 不支持流式写，因此下载大文件在 Android 上会整文件读入内存（已在接口层如实标注，未假装支持）。
- 旧加密文件同步的远端数据无法迁移成明文镜像；用户需要删除旧配置后重新添加明文同步位置。
- 变更目录/更换本机文件夹都会重建基线（旧位置文件不删不迁移），这是有意的安全选择；「严格镜像（删除本机独有文件）」「忽略规则/选择性同步」留待后续。
