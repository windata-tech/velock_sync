# AGENTS.md

本文件是本仓库的项目级记忆（Codex / 协作者共用）。

## WebDAV

### 1. 用户 NAS（远程，联调主用）

- 地址、账号、密码记录在 `tool/local_webdav/nas_webdav.local.env`（已 gitignore，**禁止提交、禁止复制到受版本控制的文件**）。
- 需要凭据时先读该文件，例如：`set -a; source tool/local_webdav/nas_webdav.local.env; set +a`，再用 `curl -u "$WEBDAV_USER:$WEBDAV_PASSWORD" ...`。
- NAS 文件系统路径（`WEBDAV_NAS_PATH`）与它在 WebDAV 上对应的真实目录（`WEBDAV_DISPLAY_PATH`）同样只记在该 env 文件里；共享名带空格和中文，URL 需编码。
- 本仓库公开：真实服务器域名/IP、NAS 路径、共享名不得写进受版本控制的代码、文档、测试或截图；截图含连接列表时先脱敏（用 `nas.example.com` 等占位）。
- 若认证返回 401 或路径 404，先核对本文件记录并向用户确认，不要猜测或改写凭据。

### 2. 本机测试服务（WsgiDAV）

- `tool/local_webdav/start_local_webdav.sh [start|stop|restart|status]`，默认端口 8888、账号 `velock` / `velock123`，数据根目录 `ui_test_results/persistent-webdav-root`。
- 这是模拟器/本机自测用的假服务，与上面的 NAS 无关，勿混用凭据。

## Sync 单模拟器 E2E（2026-09-30，跨会话入口）

- 先读 `docs/testing/sync-e2e.md`。脚本在 `tool/ios_ui_test/sim/`（`ui.sh` 精简树、`tap.sh` 按 identifier 点击、`run_test.sh` 单测、`backup_smoke.sh` 本机 WebDAV 冒烟）；私密值只放 gitignore 的 `local.env`。
- 界面自动化只按 widget key 发布的 accessibility identifier 定位，不再用中文标签；改界面时同一次改动里补 key / 更新 `testBackupSmoke`。
- 只改 Sync 时增量：重建安装 Sync、复用模拟器与格间状态，只跑受影响的测试。
- **用户说“测试”= 运行 `tool/ios_ui_test/sim/e2e.sh`**（构建→重装两 App→格间六类造数→数据库校验→Sync 配对备份→远端无明文→`app` 阶段 Sync 全功能巡检：文件同步双向/冲突/删除传播在第二台本机 WebDAV 18992 上、连接管理、设置各项，两边文件 `diff -r` 核对），约 12–15 分钟；要录像加 `--record`（从卸载前开始录）；失败按提示 `--from <阶段>` 续跑，不要重新探索界面。重装只允许 `local.env` 的 `E2E_RESET_ALLOWED_UDID`。
- 真实 NAS 联调（仅用户要求时）：`E2E_NAS=1 e2e.sh`，由 `tool/local_webdav/nas_relay_proxy.py` 在匿名 `127.0.0.1:18991` 转发到 NAS 每轮新建的 `e2e-<时间>/`（凭据/`WEBDAV_RELAY_URL` 只在 gitignore env）；验收后 `mirror` 留证、`remove` 删掉 NAS 文件夹。replica 恢复流程与 identifiers 见 `docs/testing/sync-e2e.md`；恢复配置停在「等待格间恢复」时必须在详情点 `backup-check-restore`，「刷新状态」不推进。中止 e2e 杀 `xcodebuild` 让 trap 收尾，直接 TaskStop 会遗留录屏进程（`Host recording is already in progress`→ `simctl shutdown`+`boot`）。

## 教程录制与验收（跨会话入口）

- 用户要求录制/重录“首次配置格间同步 + 新设备恢复”时，**先读 `docs/testing/tutorial-recording.md`**，不要重新探索旧失败流程。
- 可复用入口：`tool/ios_ui_test/tutorial/record.py`；先 `--check`。配置 `*.local.json` 忽略 Git，秘密仅来自私有 0600 文件；默认会擦除显式白名单中的专用模拟器，必须先核对。
- UI 路径固化在 `ui_test_harness/CrossAppUITests/CrossAppUITests.swift` 的 `testTutorialSourceFlow` / `testTutorialReplicaFlow`。录前准备与录制分离，模拟器操作串行，只读 QA/逻辑测试可并行。
- 密码按输入框角色定位、聚焦后不用旧节点、只提交一次；返回导航一次点击一次等待；批准弹窗匹配完整标题。详见上述手册，不再盲试坐标或整段重复重录。
- 录像用原生 simctl + start/recording/stop/stopped 握手；不剪辑、不变速。`run_qc.sh` 对每段以 0.2 秒扫描，错误拒绝、停留人工复核，再验恢复身份/真实业务内容。XCTest 通过不代表录像合格。
- 已接受历史交付：`ui_test_results/tutorial-20260919/delivery-v2/`；根目录旧片已撤回。详细证据 `docs/verification/2026-09-19-tutorial-retakes.md`，以“最终交付”为准。

### 同步覆盖范围：用户明确优先级（2026-09-19）

- **文件、相册是重点**；普通账号、信用卡、日记/备注必须分别准备和恢复验收，不得仅一条 password 就宣称同步通过。
- 教程固定 host 六类 file/media/password/card/note/document；UI 打开文件正文、照片原图、账号详情、信用卡详情、备注正文。document 额外 host 验证，不冒称手机已有文档展示。
- 新入口录前检查真实六类数据，旧仅密码的 zh/en 源设备应被拒绝。不能降低 REQUIRED_KINDS、把目录/缩略图/列表摘要当完整内容来绕过。
- `delivery-v2` 仍是历史基础配置演示，不是全内容验收；后续须准备完整样例、实跑新版路径，再重新录制和 QA。
- 2026-09-19 实测陷阱：准备源已有 published 批次时，新的空 WebDAV 不会自动得到全部旧数据；进度checkpoint没有业务快照。录制器已前置拒绝这种组合，禁止降低远端完整性门禁。`zh-full-01` 未通过、未交付；产品远端迁移/完整重传仍待修复。
- 2026-09-19 后续已修复 Apple Sync 的缺历史误报：runner 完成前校验本地验签进度对应的远端commit连续性，缺失记 `remote.velock_history_incomplete`；160项回归及实际模拟器拒绝测试通过。**仅误报/安全阻断修复，不是自动全量迁移完成**。历史原包已删时需完整旧备份或可信完整快照；详见 `docs/verification/2026-09-19-empty-remote-history-fix.md`。
- 2026-09-19 继续全量快照时发现并修复 companion 多文件导入binding：每条file只传自己的blob，批次文件缺附件先拒绝；DELETE历史blob refs不得要求新上传。隔离还原旧行可稳定重现，相关35项测试通过。快照依赖排序7项测试完成，但完整快照协议/传输/UI尚未接通，不能称自动补传完成；详见 `docs/verification/2026-09-19-current-snapshot-progress.md`。

- 当前快照新增组件：companion `sync_current_state_source.dart` 从真实业务表读取（含无change_log的导入记录）；`sync_current_snapshot.dart` 独立签名、加密分part与流式blob校验。174项合并回归通过，但Native回调/稳定heads/持久暂存/传输/恢复游标/UI尚未接通。禁止把VerifiedCurrentSnapshot当完成回执或重用旧checkpoint放行；同snapshotID必须复用原始暂存字节，不能重新prepare覆盖。详见上述设计与验证报告。
- 后续 Native读取binding + 原始密文暂存已实现：companion `sync_current_state_native_binding.dart` / `sync_current_snapshot_store.dart`。228项合并回归通过，六类真实SQLite→加密→磁盘→重新读取验收通过；Native通道为mock，未上设备。必须绑定解锁session、保留源hash/fence、缓存复用原字节并外部验签；每进程一个writer isolate。仍未接runtime/稳定heads/跨App及WebDAV/恢复完成状态机，不能宣称完整自动迁移。详见同一快照设计与验证报告。
- 快照已有 `SyncPasswordExchangeRuntime.stageCurrentSnapshot` 显式本地生成入口，frontier+producer连通，297项合并回归通过（实际runtime方法调用但Native为测试替身）。仍无UI/上传/恢复调用。必须由应用提供覆盖所有写入者的排他scope；只允许连续已发布本地链作为heads。后续V2已携带删除因果元数据，生成端不再一概拒绝墓碑；旧V1快照拒绝，恢复完成/历史完整性门禁保持。

- 最新进展：独立快照V2/domain2支持九类紧凑墓碑（无历史正文/blob）；真实source→加密→磁盘与runtime生成都包含删除状态。新空空间原子墓碑installer验证旧账号/文件upsert不复活、并发进入冲突；401条跨批失败全回滚。400项合并回归通过。旧增量V1不变；完整恢复状态机/游标安装、传输/UI/设备验收仍未完成，installer不写ACK或cursor，不能称完整同步已修好。

## 全内容教程录制（2026-09-20）

- 操作与脚本说明：`docs/testing/tutorial-recording.md`；真实回归证据：`docs/verification/2026-09-20-full-tutorial-recovery.md`。新鲜、从未发布的源使用 `tool/ios_ui_test/tutorial/prepare_source.py`，画外造数后覆盖安装 production，再五类 UI/六类 host 校验；禁止仅账号录制冒充全内容。
- 录制自动保存通过校验的 `pristine-remote` 和对应私有恢复卡。恢复段重录从完整 pristine 远端克隆新测试目录，保留源历史；失败替换设备的旧 join request 会触发真实审批弹窗，不能误批准或靠剪辑掩盖。
- 首次系统文件选择器从 Recents 进入 Browse；添加按钮不能模糊命中空状态文案；英文底部实际为 `File` / `Photo` 单数，必须匹配按钮而不是 Settings 的 `Photos Preference`。
- 录像不裁切/加速；失败 take 不交付。QC 的同标签停留告警需看实际帧，不能把自动无错误等同于无卡顿或完整业务验收。恢复卡仅可在完全隔离、永不存真实数据的演示空间中公开。

- 间歇性凭证回读失败已定位外部native库 `crypto_new` 的header hash偏移多12字节；iOS双slice修复已集成，432合成roundtrip及17padding边界通过。保留失败关闭与回读门禁；旧损坏密文不能自动修复，其他平台尚未重建。详见上述2026-09-20验证报告及companion AGENTS。

### 专用模拟器生命周期（2026-09-20 纠正）

- 教程/恢复测试开始前先盘点现有模拟器：优先复用上一轮有效的专用配对；失效或属于旧 take 的 `Velock ...` 模拟器先删除，禁止为每次 take 无限新建。
- 同一时间最多保留一对专用设备（source + replica），且只能擦除显式配置白名单中的设备。绝不删除真机或用户标准 `iPhone ...` 模拟器。
- 交付完成、失败终止或用户要求清理时，必须删除全部 `Velock ...` 专用模拟器；交付视频、日志和验证证据保存在项目外 artifacts，不依赖模拟器容器。
- 清理后以 `xcodebuildmcp simulator-management list` 复核，列表中不应再有 `Velock ...` 测试模拟器。

### 用户教程视频：构建模式与节奏门禁（2026-09-20）

- Flutter 官方不支持 iOS Simulator 的 Release/Profile 构建：`flutter build ios --simulator --release` 与 `--profile` 都会直接返回 “mode is not supported for simulators”。不得把 Debug 模拟器视频标注成 Release；2026-09-20 用户明确接受本轮 Debug 模拟器教程交付。
- 如果用户重新要求 Release 真机教程，必须在两台物理 iOS 设备上录制；当前物理设备不足时不能把 Debug 冒充 Release。模拟器 Debug 只适用于用户明确接受这一限制的版本。
- 用户可见节奏固定：关键内容页至少停留 2.3 秒；每次点击后 0.45 秒过渡；表单输入完成后 0.6 秒；同步结果至少 2.4 秒。等待必须由真实状态断言驱动，不能用长固定 sleep 掩盖。
- `E2E_TUTORIAL_PACE=1` 打开节奏控制，并写入 `tutorial-stage-timeline.tsv`。交付前必须按时间线检查过快/过长间隔；只通过覆盖门禁但没有节奏审查的原始片仍不算可交付。
- 2026-09-20 已接受 `delivery-pace-20260920`：中文首次配置138.98秒、中文恢复160.07秒、英文首次配置139.05秒、英文恢复157.46秒；内容页2.3秒、点击0.45秒、输入0.6秒、同步结果2.4秒。QC同标签区间均经人工抽帧确认不是冻结。

## 普通用户云备份 UI 第一轮重构（2026-09-25）

- 设计与验证记录：`docs/design/simple-cloud-backup.md`、`docs/verification/2026-09-25-simple-cloud-backup.md`。原 Sync `main` 备份为 `a1b7c6451afa40ce1f43de056c2288daa72ab413`；格间 `main` 备份为 `c5ba1ba2fa34c1f8e6935c9a1515acb2d42c2691`；两仓库服务器均有 annotated tag `backup/20260925-before-simple-sync`。重构曾在 `codex/simple-cloud-backup` 分支交付，2026-10-01 已全部并入 `main` 并删除该分支；**两个仓库此后直接在 `main` 开发，没有特别说明不新建分支**。不得把 UI 重构当成完整协议实现。
- **「云端保存位置」与「更换保存位置」不重复**（2026-09-27 用户：“这2个地方都有同样的入口，是否重复了？…现在好像没法更换哈”）：概览页的「云端保存位置」是**只读查看**（显示 `dataset.remoteRootSegments` 路径，点进去用 App 内浏览器定位到该目录）；「管理」页原来放的是同一个只读行，现改为**「更换保存位置」**（key `manage-change-location`），真正执行换目录。换目录流程抽成 `lib/features/cloud_backup/ui/velock_backup_location.dart` 的 `changeVelockBackupLocation`，与 `BackupHistoryHelp` 共用同一份（浏览→确认→`selectOriginalVelockFolder` 保存 `remoteRootSegments`），**不改共享连接、不启动同步、不迁移/删除两边数据**；返回 `(profile, saveFailed)` 记录，让帮助页继续用行内反馈、管理页用提示，避免把失败说成成功。回归：`sync_profile_removal_refresh_test.dart`（管理页有「更换保存位置」且不再有「云端保存位置」）+ `backup_history_help_test.dart`（共用流程后确认框改 key/文案为 `backup-location-confirm` /「保存位置」）。
- **方向/冲突是「草稿 + 保存」**（2026-09-27 用户：“修改了同步方向和冲突处理后，右上角需要多一个保存按钮，返回的时候如果用户没保存，就弹对话框提示是否保存”）：详情页的同步方向与冲突处理不再点一下立刻写库，而是先进草稿；有草稿时页头出现「保存」（key `plain-detail-save`，无草稿时不渲染）。离开用 `PopScope(canPop: !dirty)` 拦截（页头返回走 `maybePop`，系统返回手势同样被拦），弹 action sheet：保存 / 不保存 / 取消。**保存成功必须回读 provider 确认**（`_update` 失败是弹提示而不是抛异常，不能把“被拒绝的保存”当成功）；保存后由调用方统一 pop 一次，避免双重 pop。结构类操作（更换文件夹、暂停/继续、删除、立即同步）仍是即时生效，不走草稿。回归 `test/features/plain_sync/plain_location_detail_test.dart`（草稿不落库、保存落库并清按钮、取消保留、不保存直接离开、离开时保存、干净页面不弹）。
- **同步位置两半都能「打开」**（2026-09-27 用户：“在这前面添加一个按钮，打开…如果是打开本地的，就是本地的文件管理器（最好是要跳转到对应的目录位置）”）：详情页「本机文件夹 / 远端文件夹」两行现在是 `打开 | 更改`（keys `plain-local-open` / `plain-remote-open`）。**远端**用已有机制 `pushNamed(connection, segments:)` 在 App 内打开该目录（与格间「云端保存位置」同一路径，不重写浏览器）。**本机**交给系统文件管理器：Android 用 `content://` tree URI、Apple 用既有 native bookmark 通道解析出路径后开 `shareddocuments://<path>`、桌面用 `file://`；解析用的 security-scoped session 立刻释放（文件管理器有自己的权限），任何失败只给“这个设备上没有可以打开文件夹的应用。文件夹位置：…”而不是抛错。实现 `lib/features/plain_sync/local_folder_open.dart`（依赖注入，便于测试）。
  ⚠️ iOS 的 `shareddocuments://` 是**未公开 scheme 的尽力而为**。2026-10-01 `testSyncAppTour` 在 iOS 27 模拟器上截图确认它打开了系统「文件」App 并定位到所选目录（HostApp `PlainSync-E2E`）；**真机仍未验证**；若用户反馈无效，应改成 native `UIDocumentPickerViewController(directoryURL:)`（文档化，但打开的是选择器）再评估。回归 `test/features/plain_sync/local_folder_open_test.dart`（5 项，三种 grant + 无处理器 + 坏 bookmark）与 `plain_location_detail_test.dart` 的「both halves can be opened before being changed」。
- **禁用不等于变灰**（2026-09-27 用户：“这些图标，在任何不可以点的时候，我不要这么灰啊，在原本图标颜色上加点透明的白就行，跟系统的那种风格保持一致”）：`CupertinoButton(onPressed: null)` 会用 `CupertinoColors.quaternaryLabel` 重绘整个 child，把绿色盾牌、蓝色文件夹、页头图标统统刷成灰色。规则改为：**图标自己带显式颜色**（例如文件夹用 `appPrimary`），禁用时只叠 `AppOpacity.disabled`（0.45，与设计系统既有的禁用透明度一致），不换色。已覆盖 `AdaptiveIconButton`、`AdaptiveActionMenu`、远端文件卡片（`RemoteFileItem.inactive`）。**注意卡片只能用同一个 widget 形状改透明度值**：靠 `inactive ? Opacity(...) : content` 切换根 widget 类型会整棵子树重建，`connection_loading_test.dart` 的“加载时保留原列表元素”断言会红（必须保住 `identical(element)` 与位置）。回归 `test/widgets/disabled_artwork_test.dart`。
- **连接菜单要有「连接说明」**（2026-09-27 用户：“把菜单也加一个这个功能”）：连接列表「更多操作」里除修改/删除外，还要有只读的「连接说明」。说明内容抽成 `lib/features/connection/ui/connection_info_sheet.dart` 的 `showConnectionInfoSheet(context, protocol)`，连接详情页的信息按钮与列表菜单共用同一份实现（不许复制两份文案）；它只描述适配器能力，不探测服务器、不写远端、不改目录。回归 `test/features/connection/connection_edit_entry_test.dart`（含“不是当前服务器的检测结果”这条免责声明仍在）。
- **连接要有「修改」**（2026-09-27 用户：“这里只有删除，没有修改？”）：连接列表的「更多操作」菜单现在同时给「修改连接」和「删除连接」，修改复用详情页铅笔的同一套路由——WebDAV 走 `newWebDav?replace=<id>`，OAuth 走 `newOAuth`（provider + `replace=<id>`）重新授权；不要新造编辑页。回归 `test/features/connection/connection_edit_entry_test.dart`（两种协议各一项，断言打开的是预填表单而不是空白新建）。
- **「云端保存位置」要进到备份自己的文件夹**（2026-09-27 用户：“这个点过去了好像位置不对？它到了连接的根目录，而不是格间存放备份的目录”）：profile 的 `dataset.remoteRootSegments` 才是备份所在目录（现场是 `USB_HDD_8T/111`）。详情页那行现在副标题直接显示这个相对路径，点进去通过 `?segments=` 把目录交给 `Connection`，由它用 `RemoteObjectStoreFactory.scopeProtocol` 解析成绝对路径后一次性 `go()` 到该目录（连接根仍是浏览边界，可以往上走）；`segments` 来自路由参数，非法/越界值必须 try/catch 后忽略、退回连接根，不能把红色异常页丢给用户。回归：`test/features/cloud_backup/backup_navigation_test.dart`「cloud location opens the backup folder…」+ `test/features/connection/connection_initial_folder_test.dart`（含根目录、子目录跳转与越界拒绝三项）。
- **明细表要真的成列**（2026-09-27 用户：“这里文字没有对齐？”）：`AppDetailSheetRow` 新增可选 `trailing`（贴在 sheet 右侧、用 tabular figures 对齐数字），别再把「大小 · 时间」拼成一个字符串——各行的字节数长度不同，时间就会参差不齐。已同步对象明细现在是【对象类型 · 方向｜时间（固定列）｜大小（右对齐）】；回归 `test/features/sync_profiles/synced_objects_sheet_test.dart` 断言三行金额右边缘一致、时间左边缘一致。
- **动词跟着领域走**（2026-09-27 用户：“这个应该叫暂停备份而不是暂停传输吧？”）：格间域的动作/状态一律用「备份」（暂停备份/继续备份、上次备份已完成、暂时无法继续备份…），文件夹域用「同步」（暂停同步/继续同步、上次同步已完成…）。`BackupStage.lastTransferCompleted` 与详情页暂停行按 `isVelock` 分文案；真正指传输过程的句子（例如“系统可能暂停传输”“传输记录”）保留「传输」不改。
- **品牌图标用格间真实的**（2026-09-27 用户：“这里的图标应该用格间真实的，上面的用彩色的，下面的用扁平化的，你去格间的项目里找一下，复制过来用”，格间项目 `/Users/parcool/AndroidStudioProjects/velock_codex`）：彩色源文件是格间的 `assets/images/app_logo.png`（152×152，绿盾+白 V），已复制为 `assets/branding/velock_mark.png`；**扁平版是同源派生**（把白底与白 V 抠成透明后填单色 `velock_mark_flat.png`，格间项目里没有单独的线稿版），底部 tab 用 `VelockBrandMark(flat: true, color: …)` 按选中态着色，格间状态卡徽章用彩色版（`BackupStatusCard` 的 `_CloudMark(branded: isVelock)`）。素材目录已在 pubspec 注册；组件在 `lib/widgets/velock_brand_mark.dart`。
- **进度只长在正在跑的那张卡上**：明文首页用 `_runningProfileId` 区分“这张卡在同步”和“页面忙碌”，别的卡只禁用、不显示 spinner/「正在同步…」（否则两个位置会同时假装在同步）。
- **进度不弹窗，状态长在按钮上**（2026-09-27 用户：“这个对话框不要了，把状态做到立即备份的按钮上，如果有其他类似的这种，也按照这个方式来实现”）：`runSyncWithProgress` 与明文同步的 runner 都不再打开阻塞式进度弹窗，`showAdaptiveBlockingProgress` 已删除。`BackupActionButton` 新增 `busy`（内联 spinner + 禁用重入），`BackupStatusCard` 在 `BackupStage.transferring` 时把主按钮置为 busy（标题「正在传输，请稍候」），明文首页/详情按钮显示「正在同步…」。**失败仍然必须是需要确认的持久弹窗**，明文“待确认删除”确认框也保留；只有“进行中/已完成”不再打断用户。写 spinner 相关测试时不能用 `pumpAndSettle`（无限动画），要用固定 `pump()` 帧。
- **状态卡自带「详情」**（2026-09-27 用户：“把这个上次传输完成、立即备份这个卡片与备份详情与管理融合起来，反正你现在这个感觉有点重复累赘”）：格间首页不再有独立的「备份详情与管理」行，`BackupStatusCard` 新增 `secondaryLabel/onSecondary/secondaryKey`，与主操作并排（与明文同步位置卡片同一形态）；同一入口不要在两处重复。回归 `test/features/cloud_backup/backup_ui_test.dart` 断言该行不存在而卡片里有「详情」。
- 三个主入口为格间/文件同步/设置；技术计数放二级诊断，必要冲突/待授权不隐藏。格间负责加解密、原账号恢复和实际应用数据，Sync 只传输且不索取恢复卡密码/秘密；授权、建连接、预检、上传对象或下载完成不得表述为完整备份/恢复成功。
- 恢复必须先由格间找回原账号并签名授权；Sync 仅对原位置中签名授权内可信 producer 的候选历史做只读发现，随后仍走既有 runner 校验并由格间应用。候选发现不是完整验签/内容验证。返回新增云端页面必须保留 restore intent/已批准授权并自动继续；`returnTo` 仅允许已知内部流程。
- OAuth 普通用户默认不看 Client ID/Token/root ID；公开注册未配置时明确本版本暂不可用并提供其他位置。开发者配置默认折叠，输入仅在保存后生效。预检仅 `ifAbsent` 写随机无敏感 probe、读回校验、只删自己成功创建的 probe；恢复探测不写远端。
- 未完成项：current-state 完整快照传输/恢复状态机、可验证六类业务内容摘要、版本选择、自动完整云端迁移、单向仅上传文件夹模式。现有 runner 仍双向，本轮不是 upload-only 改造或完整架构重写；原签名/历史连续性/blob/完成回执门禁不放宽。
- 最终 Sync 425 项、格间 29 项相关回归全部通过，两仓库改动范围 analyze 均为 No issues found；Sync 含 14 项真实路由、11 项预检及 13 项界面测试，后者另用真实字体渲染四张图验收（不重复累计）。日志在项目外 work/simple-cloud-backup-20260925，以 `sync-regression-final-accepted.txt`、`companion-regression-final-accepted.txt` 和 `visual-qa-final-accepted.txt` 为准。截图是真实 widget + 内存 fixture，不是模拟器/真机截图；本轮没有真机、模拟器、新 NAS 写入、真实 OAuth 授权或跨 App 恢复 E2E。

## 云备份后续：NAS 入口与 FN Connect

- 真实 FN Connect 根入口可 PROPFIND207 列共享目录，但 MKCOL405；必须选择实际可写文件夹。MKCOL405/409 现在分类 `provider.webdav.collection_not_writable`，不再误报原子防覆盖不支持，也不得取得/删除非自有探针目录。
- 同服务 MOVE 的 Destination 使用 RFC4918 允许的编码绝对路径，避免 FN Connect 转发下外部 absolute-URI 返回502；保留 Unicode/空格/转义/base 子路径/query。Overwrite:F、碰撞412与字节校验、发布201/源消失不放宽，禁止普通PUT回退。
- Sync432、格间32项相关回归通过，改动范围分析无问题。但真实FN Connect生产适配器仅1MiB不可变创建/内容校验通过，四并发阶段401，整组live test未通过；401后停止重试，已请用户解锁Mac并确认账号，不能宣称NAS或完整跨App同步已验收。详细证据 `docs/verification/cloud-backup-follow-up.md`。
- **2026-09-30 已查明并解决**：FN Connect 转发层对约 50 ms 内近同时到达、前一个尚未应答的请求返回伪 `401 Basic`（转发前拒绝，无副作用）；局域网直连无此问题。`WebDavAuthRaceGuard`（`lib/providers/webdav/webdav_auth_race_guard.dart`，按 origin+sha256(账号) 进程内共享）：前一请求未应答时起始间隔 200 ms；仅可重放请求有界重试 401（账号本进程未成功过时 1 次、成功过后 3 次，带抖动），上传流不重放，403 不重试，`Overwrite: F`/412/回读门禁不变。live test FN Connect 3/3 通过、401=0；去掉守卫的对照稳定复现 401×3。真实 NAS 备份→replica 恢复端到端已通过（经本机转发代理、Debug 模拟器）。详见 `docs/verification/2026-09-30-fnconnect-concurrent-401.md`。

## 临时授权恢复（2026-09-26）

- “格间已允许连接”不能仅判断 approval 非空：配对临时响应有 5 分钟有效期。向导用最早 request/response 截止时间、Timer 和继续/前台检查保持状态一致；过期必须给“重新授权”入口并保留云端位置/恢复 intent，不延长期限或跳过验签。
- finalizer 保存持久 profile 前重验到期；授权有效时发起的持久保存完成后，ACK 可晚于临时期限。同一 flow 的晚到结果不得覆盖新 session/reset；ACK 未完成不能被 clearCompletedFlow 清除或被已有 profile 卡片遮盖。
- 回归：`test/features/cloud_backup/velock_pairing_recovery_test.dart`、`backup_navigation_test.dart` 和 pairing/finalizer 单测。widget 持有应用级 Timer，必须在测试体 finally 中 reset/dispose，不能只在 addTearDown 清理。
- 现场根因与验证边界：`docs/verification/2026-09-26-pairing-recovery.md`。NAS 并发 401 与本轮临时授权过期是不同问题，禁止混称为 NAS 已全流程通过。


## WebDAV 格间备份目录选择（2026-09-26）

- 已有云连接不等于实际备份文件夹。格间向导选择 WebDAV 连接后必须提供目录浏览（读取只用 PROPFIND；备份模式可由用户明确确认新建空文件夹），再由用户确认完整目录；不能只提示用户进入共享文件夹却不给入口。
- `VelockSyncProfile.remoteRootSegments` 是相对于原连接的 decoded 路径段；旧配置默认空列表。不得全局改写原连接，否则普通同步与其他备份会被重定向。预检、恢复扫描、runner、inventory、join profile 重建必须保持同一 scope。
- 浏览仅 Depth:1 PROPFIND，拒绝外源/越界 href，不自动重试403（401 仅按 2026-09-30 `WebDavAuthRaceGuard` 有界重试，未证实账号只 1 次），不把读取失败当空目录；除备份模式用户明确点击“创建并进入”后仅新建一个空文件夹外，尚未明确选择及最终确认时不得写入或创建配置；恢复模式保持只读。授权过期仍需重授权，不因选文件夹放宽签名/期限门禁。
- 331 项回归通过，改动范围 analyze 无问题；已安装新版 Sync Debug 模拟器。安装后模拟器界面停在连接格间，等待用户自行批准才能继续真实 NAS 列表/预检。本轮没有真实 NAS 备份恢复成功结论，先前并发401边界保留。详见 `docs/verification/2026-09-26-backup-folder-selection.md`。

## 备份目录内新建文件夹（2026-09-26）

- 备份选择器提供“新建文件夹”→显示创建位置、输入名称→“创建并进入”；仅创建一个空目录，进入后仍需明确“使用这个文件夹”，不自动开始备份。恢复模式隐藏创建入口且不调用创建服务。
- WebDAV 仅发一次无正文 MKCOL，不跟随重定向、不递归创建、不自动重试；仅201成功，405不视为已有目录成功。网络超时/5xx/异常2xx属于结果不确定，保留父目录并要求刷新，禁止盲目重建或把父目录误选为新目录。
- 名称与父路径先校验再读取凭据，拒绝路径穿越、分隔符、控制字符与超长名称。创建期间禁用重复提交/导航/选择；取消不发请求。
- 350项回归通过，五个改动Dart文件静态分析无问题；完整Debug模拟器包构建、安装及启动成功。本轮没有在用户NAS上新建/删除目录，也不代表新空目录的全量备份/恢复已经完成。详见 `docs/verification/2026-09-26-create-backup-folder.md`。

## 统一返回与目录导航（2026-09-26）

- 页头返回统一使用 `AppBackButton`（公共 `WDAppBar` 和 `AdaptiveSliverScaffold` 默认提供），单chevron、同一颜色和尺寸、至少44px触控区、中英文辅助标签。不要再手写不同箭头或启用框架默认带上页标题的返回。关闭/取消不是返回；iOS状态栏跨App“格间”入口不能由应用替换。
- 连接远端文件浏览和备份目录选择器：子目录返回父目录，配置根目录才退出路由；系统返回保持同样语义，目录创建进行中禁止离开。明确“使用这个文件夹”仍返回选择结果，不应拦成上一级。
- RemoteFileBrowser同步维护currentPath，刷新/重试不得重置根目录；失败/加载时仍可回父目录，generation拒绝晚到响应覆盖新状态，不能浏览超出配置根目录。不要只修按钮却遗留canGoBack一直为false。
- 417项相关回归通过，改动范围静态分析无问题；详情与现场验证边界见 `docs/verification/2026-09-26-unified-back-navigation.md`。导航修复不代表NAS完整备份/恢复验收。

## 目录加载不闪屏（2026-09-26）

- Connection浏览页不能用loading替换整块正文（路径/文件列表）；保持CustomScrollView与固定区挂载，加载仅显示路径旁轻量进度，等待时保留旧列表但禁用旧项点击，完成后再切换。
- RemoteFileBrowser.visibleState提供加载期间最后可见目录，错误后不能继续把旧列表当新目录；保留当前请求路径和generation用于返回/晚到保护。不要调用Riverpod标记internal的copyWithPrevious绕过公开API。
- 回归必须用Completer在请求完成前断言Element与位置稳定，不可只pumpAndSettle看最终截图宣称无闪烁。首次loading不显示空目录；失败仍能返回重试。技术能力卡后续已移入“连接说明”，不再常驻目录页。详见 `docs/verification/2026-09-26-folder-loading-stability.md`。

## 连接说明按需查看（2026-09-26）

- 目录页不再常驻“支持能力/使用限制”两张只读技术卡，不把静态适配器说明伪装成NAS检测成功。WebDAV与OAuth详情统一提供页头信息按钮“连接说明”（key: connection-info）。
- 点击打开可滚动只读说明，完整展示功能/限制、不省略截断，明确“不是当前服务器的检测结果”。打开/关闭不探测、不写远端、不改当前目录；日常浏览不需操作这些技术项。
- 慢请求测试继续断言路径/列表Element与位置稳定，不得因移除能力卡而删除加载禁用、失败返回等回归覆盖。

### 跨 App 管理入口与返回（2026-09-26）

- Sync「恢复卡与已授权设备」必须使用 `openVelockBackupSettings` / `velock://sync-settings`；禁止复用只唤醒旧页面的 `velock://open`，也不要为管理操作创建 pairing request。
- 格间配套修复：单次消费最新原生导航 inbox，锁定时保留最新意图；外部路由 go + 新 page key 清除旧批准页和附着的手动详情；直接进入页返回设置。保持全部授权/过期/验签门禁。
- 证据与回归：`docs/verification/2026-09-26-management-link-navigation.md`（Sync 434、格间94项；现有模拟器两 App Debug 构建及跨 App UI）。不等于完整同步/恢复验收。

## 历史缺失说明与详情返回兜底（2026-09-26）

- `remote.velock_history_incomplete` 的消费者主操作为 `BackupAction.reviewHistory`，进入 `BackupHistoryHelp`，不能再丢进普通「管理」。首页/详情同义，运行/权限/冲突安全优先级不变。
- 说明显示实际选定目录（含profile子目录），只读查看不运行同步、不清错误、不改授权/目录。当前不能自动重建完整新备份的限制必须明说，不能用重试/重新连接或新建空目录冒充修复。
- 配置完成回有底部导航的首页；`SyncProfileDetail` 所有状态始终提供统一返回。有历史pop，无历史回对应产品首页，系统返回一致。禁止在wizard结束时只go到无底栏又无返回兜底的独立详情。
- 本轮452项相关回归通过；iOS/Android真实路由测试覆盖无历史返回，现有模拟器GUI覆盖详情/说明/首页三入口。见 `docs/verification/2026-09-26-history-help-and-detail-navigation.md`。仅入口/导航修复，历史缺失的完整重传能力仍未接通。

## 找回原备份目录操作闭环（2026-09-26）

- 后续修正：BackupHistoryHelp不再只有只读文件浏览；首屏精简，WebDAV主按钮打开只读BackupFolderPicker，使用目录后再确认完整路径，明确“确认并继续备份”才修改本profile的remoteRootSegments并调用既有runner。不更改共享连接，不清历史错误/cursor/可信producer，选目录不等于备份成功。OAuth暂仍只读查看。
- 全局返回图标32、触控区至少44。详细限制按需查看；不能重新堆成长说明页。
- 目录修改与VelockSyncService整个预检/运行共享独立location lease，且保存前拒绝陈旧profile、运行中、已删除/非active状态。不要只检查已创建的run row，adapter预检期间也必须互斥。
- 357项相关回归通过、九文件analyze无问题；现有iPhone 17 Pro Max Debug模拟器已构建安装启动，widget真实字体首屏已看图。未执行用户NAS目录选择/写入或真实恢复。见 `docs/verification/2026-09-26-original-backup-folder-action.md`。

## 返回按钮视觉对齐（2026-09-26）

- 页头返回箭头的**实际可见左侧笔画**应与白色内容卡片外侧16px页面边缘对齐，不是仅校验44触控框或Icon box。Cupertino的默认16px导航leading padding不能与按钮内部字形留白叠加；Material的默认56 leading槽也不能让44px按钮再次右移。
- WDAppBar及AdaptiveSliverScaffold普通/大标题/紧凑页头统一此规则，非返回的自定义leading不改。像素扫描回归使用真实MaterialIcons，断言蓝色箭头与卡片边界差<=1.5px；次操作按钮同一页面边距。见 `docs/verification/2026-09-26-back-button-alignment.md`。

## 确认旧目录不自动同步（2026-09-26，覆盖前述“确认并继续备份”行为）

- 用户明确区分“确认旧目录”与“同步数据”。BackupHistoryHelp确认按钮只保存profile位置，禁止自动调用runner、传输结果提示或把保存说成备份成功。
- 保存后切换“备份位置已更新 / 本次只保存目录，尚未开始备份”；主操作“完成”只返回。可选“开始备份”必须是用户另一独立点击，才能执行既有runner。不能保留旧错误标题误导用户反复换目录。
- 253项回归、两文件analyze通过，现有Debug模拟器安装启动。见 `docs/verification/2026-09-26-folder-confirmation-only.md`。保存目录本身不是旧备份内容的完整性验证。

## 自动/手动同步去重与运行状态（2026-09-26）

- 前台自动同步和手动同步会创建不同 dispatcher，须按数据库文件身份 + profile 共享进行中 Future，不能只做实例内去重；跨 isolate 锁忙是“已在进行中”，不可写失败记录或报同步失败。
- 首页/详情已有任务 running 时持续刷新本地状态，终态停轮询，dispose 取消 Timer；刷新保留正文。失败结果及抛异常用明确确认的持久弹窗，不能只用短 Toast。
- 437 项相关回归通过，现场数据库任务已 completed 但页面残留 running；闪过的具体错误原文未捕获。详见 `docs/verification/2026-09-26-sync-running-state.md`。不代表新增业务数据完整备份/恢复验收。

## 格间 / 文件同步状态口径（2026-09-26）

- 两类 profile 独立记录状态，连接相同也不代表保存作用域相同；不得用格间成功覆盖文件夹失败，或自动把文件夹重定向到格间目录。
- 已配置文件夹首页与格间首页/详情共用 BackupStatusCard + BackupPresentation，错误全文展示；失败时间明确为“上次失败”，旧安全写入失败不描述成当前整个云端均不可用。
- 现场文件夹显示09:15旧失败且自动同步关闭，格间17:40已完成且使用111子目录；未实跑文件夹NAS重试，不能宣称其错误已经修复。验证记录：`docs/verification/2026-09-26-backup-file-status-consistency.md`。

## 安全写入错误主操作（2026-09-26）

- atomic_create_unsupported / collection_not_writable 使用 checkStorage，首页与详情直接进入 BackupStorageHelp，不得再绕概览/普通管理。
- 打开只读；用户明确检查才创建非业务探针；检查通过不清失败、不自动同步，另点开始同步才调用runner。普通文件任务不得借此重定向到格间子目录。
- 现有文件任务直接迁移目录仍未实现，失败页必须明说限制，不让用户改恢复包/后台开关或共享连接。详见 `docs/verification/2026-09-26-storage-error-action.md`。

## 文件同步任务更换可写目录（2026-09-26，覆盖上一节的“尚不支持迁移目录”）

- 现场：文件同步位置（连接根/NAS 入口）安全检查失败后页面只给“重新检查”，用户无法继续。
- 现在 `BackupStorageHelp` 为文件同步任务提供“选择可写入文件夹/更改可写入文件夹”：只读浏览（可新建空目录）→“使用这个文件夹”→确认弹窗（只改这个任务的位置，不改连接、不删旧数据、不自动同步）→“保存位置”。保存后位置文本立即显示新路径，仍需用户另行“检查此位置/开始同步”。
- `SelectedFolderSyncProfile` 新增 `remoteRootSegments`（默认空=连接根，旧 profile 行为不变）；`SelectedFolderSyncService.inspectInitialSync/run` 经 `RemoteObjectStoreFactory.scopeProtocol` 使用该 scope，并整体包在 `withVelockLocationGuard` 内，防止同步中改目录。保存走 `SelectedFolderSyncProfileRepository.selectSyncFolder`：拒绝陈旧页面、running、非 active；不修改共享连接。
- 路径校验统一在 `sync_profiles/model/remote_root_segments.dart`；OAuth 连接仍不支持子目录 scope，UI 不提供该入口。
- 页面文字按时机出现（2026-09-26 用户要求）：首屏只留“保存位置/连接/路径/检查按钮/两行入口/一句可展开说明”；失败后才出现原因与可执行提示；长说明收进“关于这次检查”，点开才展开。文案不删，只改出现时机。
- 提示必须**供应商中立**（2026-09-26 用户要求）：App 面向各种 WebDAV 服务，不得写死“NAS 入口/共享文件夹”。`collection_not_writable` 统一走 `uncreatableFolderMessage(context)`，措辞为“请进入服务里一个真实存在、且这个账号有权限写入的文件夹；只读入口、共享入口或聚合视图都不行”；`backup_failure_message_test` 断言中英文界面不再出现 NAS 字样。NAS 只可在 WebDAV 表单/连接说明等技术语境中作为例子出现。
- 旧目录数据不会自动迁移；换到新空目录等于从该位置重新开始，历史完整性门禁不放宽。详见 `docs/verification/2026-09-26-file-sync-folder-relocate.md`。尚未在真实 NAS 上完成“换目录后同步成功”的内容级验收。

## 文件同步改为普通明文镜像（2026-09-27，用户明确要求）

- 用户原话：**「这里根本不需要加密，就单纯的同步软件」**。文件同步（底部「文件同步」tab）不再是加密对象同步，改为普通同步盘：
  每个**同步位置** = 本机一个文件夹 ⟷ 远端一个文件夹（可在不同连接），可添加多个；远端就是用户真实文件/目录名，NAS 或任何程序都能直接读写。
- 设计依据：`docs/design/plain-folder-sync.md`（概念、方向、冲突、算法、表结构、界面、分期）。实现：
  - 模型/存储：`lib/dataset_adapters/plain_folder/`（`plain_folder_sync_profile.dart`、`mirror_models.dart`（planner）、`plain_folder_sync_service.dart`、`plain_folder_provisioner.dart`、executor）；`SyncDatasetKind.plainFolder`（持久化 `plain-folder`），`vaultId` 为空是该 kind 的正确表示（envelope 按 kind 校验）。
  - 数据库 schema v12 新增 `mirror_entries`（基线）/`mirror_conflicts`/`mirror_run_stats`，见 `lib/infrastructure/database/sync_state_mirror.dart`；运行记录复用 `sync_runs`。
  - 界面：`lib/features/plain_sync/`（列表 `plain_sync_home.dart`：**添加位置在页头右上角「+」** key `plain-location-add`，不用列表下方整行；**卡片不要重复套水平 padding**——`BackupCard` 自带 16pt，再包一层会让卡片比正文窄（回归 `plain_sync_home_test.dart` 的「the location card lines up with the page text」）；空列表仍有说明卡 + key `plain-location-create`；向导 `add_plain_location.dart`、详情 `plain_location_detail.dart`、运行 `plain_location_run.dart`）。路由：`/files`、`/plain-locations/new`、`/plain-locations/:profileId`。
  - 复用（不要重写）：`RemoteObjectStore`（新增 `isDirectory` 与可选 `RemoteCollectionCreator.createCollection` = 单次 MKCOL）、`SelectedFolderStorage`（新增可选 `StreamingSelectedFolderStorage.writeFileFromStream`）、`BackupFolderPicker`（远端目录浏览/新建）、`withVelockLocationGuard`、`SyncProfileDispatcher`/后台调度（executor 已注册）。明文同步**只支持 WebDAV**；OAuth 云盘明确拒绝。
- 方向语义：双向（默认）/仅上传（本机是唯一真值）/仅下载（远端是唯一真值，本机对已同步文件的修改被覆盖，本机独有文件不删）。冲突默认**保留两份**（本机版本另存 `名称 (本机冲突 日期 时间).扩展名`），可改以本机/以远端为准。首次同步只合并、**绝不删除**没有基线的路径。
- 删除保护：超过 1000 项或基线 20%（基线少于 5 条时只看 1000）时扣下删除，**保留基线行**（否则下次会把文件当新文件重新下载，等于静默撤销删除）；界面确认后用 `allowDeletions: true` 再跑一次才真正删除。
- 旧加密 `selected-folder` 是**已淘汰的协议，界面上彻底不存在**（2026-09-27 用户：“旧版就是淘汰的版本功能，不需要保留”）：文件同步 tab 不显示、设置里整段删除、`legacyEncryptedProfilesProvider` 已移除，全仓库不得再有面向用户的「旧版 / legacy」文案（回归 `legacy_encrypted_entry_test.dart` 断言设置页连“旧版”两个字都不出现）。
  同时 `SyncProfileSummary.isBackgroundEligible` **排除 `SyncDatasetKind.selectedFolder`**：既然没有任何入口能查看/暂停/删除它，就不能再让它悄悄在后台跑（回归同上 + `test/background/background_sync_test.dart` 改用 `velockManaged` 做引擎 fixture、用 `plainFolder` 做“无 executor 的 kind”）。
  **本机 profile 行与远端加密对象都不动**：没有新增删除逻辑，旧任务只是不再被调度、不再被展示。要彻底清掉本机遗留记录或远端加密目录需要另行确认（远端是加密对象，不能转成明文镜像）。
- 远端写入后必须 `stat` 回读远端时间/etag 再写基线（否则服务器自己的 mtime 会让下一次同步把刚上传的文件当成远端改动下载回来）。本机下载后重新扫描本机元数据再写基线。
- 文案边界：必须写明「远端是明文，能访问该账号的人都能看到和修改」；同步结果只说上传/下载/删除/冲突数量与时间，不说“已备份”。
- 端到端验证入口：`tool/local_webdav/start_local_webdav.sh start` 后用 `flutter test test/dataset_adapters/plain_folder/plain_folder_webdav_integration_test.dart`（真实 WsgiDAV：建目录/上传/下载/覆盖/删除/保留两份冲突；服务未启动时自动 skip，不碰用户 NAS）。
- `WebDavObjectStore.list(prefix: '')` 的 `allowEmpty` 只放行**连接根**这一种空 key，其余空 key/越界 key 仍 fail closed（否则「列同步位置根」根本不可能成功）；回归 `webdav_object_store_test.dart`。
- 远端写失败（409/401/403…）翻译为 `plain_folder.remote_folder_unwritable`；向导在创建 profile 前先 `checkRemoteWritableFor` 预检（`plainRemoteWritableCheckProvider` 可注入），失败不写 profile，文案说“返回上一步换文件夹”而不是详情页服务话术。
- 方向/冲突这类“必须读明白才敢选”的说明文字**禁止被单行截断**（用户 2026-09-27 反馈 3/3 页说明被省略号截掉）：选项统一用 `lib/features/plain_sync/ui/plain_option_row.dart` 的 `PlainOptionRow`（单选图标 + 标题 + 完整换行说明），不要再用 `AdaptiveListTile(isThreeLine: true)` 塞长说明；回归在 `test/features/plain_sync/plain_option_row_test.dart`（断言 `maxLines == null`、非 ellipsis、行高大于单行）。
- **保存成功后绝不能再报“创建失败”**（2026-09-27 现场：连点创建看到「创建同步位置失败，请重试。」，实际 3 个 profile 都已写入）：`AddPlainLocation.create()` 的保存放在 try 内、导航放在 try 外；`leaveWizard()` 能 pop 就 pop，不能 pop（向导本身是首个路由，例如用 `--route=/plain-locations/new` 直接打开）就 `go('/files')`。向导页头必须始终有返回：`goBack()` 先退一步，第 1 步则离开向导；切换步骤要清掉上一次的错误文案。
- **一个本机文件夹只能属于一个同步位置**（2026-10-01 用户：“选择了一个本机的位置后，再次新建，还可以选同一个位置，这样不会导致数据错乱吗？”，确认按此规则改；覆盖 2026-09-27「同一本机文件夹可配不同远端、暂停的不拦」）：同一本机文件夹配多个远端时，各位置基线独立、运行锁按位置，会把一个远端的删除连锁传到另一个远端、转发冲突副本、并发运行互相看到半写文件。现在 `assertPlainLocalFolderUnused`（`lib/dataset_adapters/plain_folder/plain_local_folder_guard.dart`）拒绝**相同 / 包含 / 被包含**，**已暂停的位置同样占用**，`selfProfileId` 排除自身；`DuplicatePlainLocationException` 已删除（被它覆盖）。**不能比 `localRootReference` 字符串**：iOS 每次选同一文件夹得到的 bookmark 都不同（旧重复检查在 iOS 上实际无效）——iOS 经一次短暂 acquire/release 取路径（折叠 `/private/var`→`/var`、去尾斜杠）；Android 比 SAF tree 文档 ID（`com.android.externalstorage.documents` 的 `卷:路径` 可判包含，其他 provider 只判相等）；桌面用规范化真实路径（`resolveSymbolicLinksSync`，同步调用以便 widget 测试）。已有位置的 bookmark 解析失败时退回原始引用相等。向导第 1 步选完立即检查（`PlainFolderProvisioner.assertLocalFolderUnused`），`create` 再查一次；详情页「更换本机文件夹」同样检查。提示文案 `plainLocalFolderInUseMessage`（点名占用的位置和文件夹、建议去该位置改远端）。已存在的违规位置不会被自动修改。回归 `plain_local_folder_guard_test.dart`（假 bookmark 映射同一路径/嵌套/前缀孪生/失效 bookmark/Android）、`plain_folder_provisioner_test.dart`、`add_plain_location_test.dart`「a local folder another location owns is refused at step 1」。
- 暂停只停传输，**不冻结设置**：`PlainFolderSyncProfileRepository.update` 允许非 active（暂停）profile 改方向/冲突/名称，仍拒绝陈旧页面、运行中与已删除；暂停/继续本身走 `pause()`/`resume()`，详情页与卡片一致（详情页早期版本用 `update` 改状态，导致“继续”按钮点了没反应）。

## 上线标准复查：明文同步的安全与错误路径（2026-09-27 夜）

用户要求「以格间项目的上线标准」再自查一遍：流程是否最小但完整、有没有大 bug。四路只读审计（引擎正确性 / 失败路径 / 上线就绪 / 跨 App 安全）后逐条修复，规则如下（回归见 `docs/verification/2026-09-27-launch-hardening.md`）：

- **远端列不出来 ≠ 远端是空的**。`WebDavObjectStore.list` 以前把 PROPFIND 404 当空目录返回，引擎随后把「远端什么都没有」当成「用户删了所有远端文件」，于是**静默删本机文件**。现在 404 抛 `RemoteObjectNotFoundException`（引擎映射 `plain_folder.remote_folder_missing`），另外三重保护：远端空 + 本机非空 + 有基线 ⇒ 运行失败且不删；**只有本次真正列过的目录**（`MirrorListingScope`）下面的路径才允许删除；深度截断（`remote_too_deep`）同上。回归 `plain_folder_sync_service_test.dart`（404→code、空listing不删本机）、`mirror_planner_test.dart`（未列过的父目录不可删）。
- **确认删除只批准用户看过的那批路径**。`run(allowDeletions: true)` 不再等于“批准一切”：删除必须走 `runConfirmedDeletions(profileId, confirmedPaths)`，计划在确认之后变大就重新扣下（`MirrorHeldDeletions.paths`）。界面流程：`runPlainLocation` 自己「跑 → 列出**具体路径**的确认表 → 只批准这些路径再跑」，全部在同一个 busy 窗口内（以前在 `_busy` 为真时递归调用 `_run`，导致「确认删除并继续」**什么都不做**，而再点一次会**未经复核**直接删）。回归 `plain_sync_home_test.dart`（确认表列出路径、只批准这些路径、取消则一次都不删）、`mirror_planner_test.dart`。
- **上传必须回读校验**：PUT 之后 `stat` 比对远端大小与本机长度，不一致就 best-effort 删掉残件、报 `plain_folder.upload_incomplete`、**不写基线**（否则被截断的远端文件会变成“真相”，下一轮把好的本机文件覆盖或改名成本机冲突）。下载字节只在写成功后计数；运行失败时不再把 `heldDeletionCount` 清零（「有删除等待确认」要留住）。回归见上。
- **被系统杀掉不能永远卡住**：`sync_runs` 里 state='running' 的孤儿行以前会让位置永久显示「正在同步」，并让改设置/删除永久失败。现在 `main.dart` 与后台 isolate 启动时都调用 `SyncStateDatabase.failInterruptedSyncRuns()`（写 `sync.interrupted`，并清掉死进程的 `profile_locks`），回归 `test/infrastructure/database/sync_state_interrupted_runs_test.dart`。
- **WebDAV key 是解码后的相对路径**：`Uri.resolve('a#b.png')` 会把 `#` 当 fragment，于是带 `#`/`?` 的文件名被写到**别的路径**（两个这样的名字还会互相覆盖）。现在逐段编码（`_objectUriFor`），MOVE 的 Destination 始终是编码后的 path（不再有 query 分支）。回归 `test/providers/webdav/webdav_object_store_keys_test.dart`，`webdav_destination_path_test.dart` 的 fixture 改为解码 key。
- **换文件夹要原子**：以前先存 profile、再清基线，两步之间失败就会「提示没保存成功但其实已保存」＋用旧基线删远端文件。现在 `PlainFolderSyncProfileRepository.relocate(...)` 在同一个事务里保存并清 `mirror_entries`/`mirror_conflicts`/`mirror_run_stats`，写之前先做远端可写预检。
- **目录重叠守卫**：明文位置不得等于/包含/被包含于格间备份目录（`assertPlainScopeAvoidsBackups`），也不得与另一个明文位置的远端互相包含（`assertPlainScopeAvoidsOtherLocations`，抛 `PlainLocationOverlapException`，已不再接收本机引用）；**同一个远端文件夹 + 不同本机文件夹仍允许**（多设备是文档化用法），本机文件夹由上面的本机守卫保证不同。`PlainFolderProvisioner` 的 `backups` 参数是 required，守卫在写远端探针**之前**跑。
- **失败文案只有一份**：`plainFailureMessage(context, code, {connectionName})`（`plain_location_presentation.dart`）是明文域唯一映射（离线/超时/证书/401/403/404/409/412/429/507/存储不足/远端文件夹消失/上传不完整/运行中/被系统中断…），**正文永不出现错误码**；`AppFormat.errorSummary` 补 507 与离线，Velock 域共用。原始异常交给 `SyncFailureClassifier.classify` 再翻译（丢包不再报“原因不明”）。
- **每个同步客户端都有超时**（连接 30s、收发 5min，共享工厂 + 明文/格间服务）：黑洞式断网不会再让运行无限挂起并把人困在页面上。
- **本机替换不先删目标**：`rename` 本身就是覆盖（Dart/桌面），Android SAF 因为 `renameDocument` 允许 provider 改名成 `name (1).ext`（会变成静默副本），改为**原地写回已有文档**（`replaceDocumentContent`），失败返回 `provider.saf.replace_failed` 且绝不再删除暂存件。SAF 现在也实现 `StreamingSelectedFolderStorage`（大文件不再整份进内存）。
- **页面标题与返回槽**：导航栏标题允许两行、用 `minHeight` 而不是固定 44pt；返回键后面不再加 8pt（会把 leading 槽撑到 52pt 溢出）；**向导的「第 N 步，共 3 步」固定在正文里**——放在导航栏 trailing 槽会在路由转场逐帧收窄时溢出（debug 条纹）。
- **英文界面不许出现中文**（`test/l10n/sync_english_pages_test.dart`、`sync_settings_english_test.dart`、`plain_sync_english_test.dart` 会逐屏扫描 Text 与 Semantics）：设置页、连接说明、活动记录、连接详情、百度 token 页、文件同步页全部补齐；唯一允许的是语言选择器里的 `简体中文` 本身。`syncText` 之外的裸中文不再新增。
- **上架材料**：`ios/Runner/PrivacyInfo.xcprivacy`（DiskSpace/FileTimestamp/UserDefaults required-reason）、`docs/release/app-review-notes.md`（ATS/后台模式/无账号无分析/评审如何看到文件同步）、Android `@string/app_name`＝「Velock Sync」、`sqlite3_flutter_libs`（自 0.6.0 起是空包）已删除。`_provisionNasConnection` 只在 debug 生效；`sync_profile_runner` 的 `VELOCK_SYNC_EVENT` 只在 debug 打印。
- **已知未做**：`shareddocuments://`（未公开 scheme，建议换 `UIDocumentPickerViewController.directoryURL`）、运行中取消（`RemoteOperationCancellation` 仍未接到界面）、>64MiB 的“同尺寸不同时间”文件仍按延迟校验处理（不会误删，但不会自动收敛）、明文位置不支持云盘（仅 WebDAV）。
- **已脱离 `flutter_platform_widgets` 并迁到独立设计库（2026-09-27 全部完成；细节见 `docs/design/adaptive-widgets-migration.md`）**：Flutter 把 Material/Cupertino 拆成 `package:material_ui` / `package:cupertino_ui`（3.47 起可用，SDK 内 `flutter/material.dart`、`flutter/cupertino.dart` 后续弃用）。现状与硬规则：
  - **0 个文件** import SDK 的 `flutter/material.dart` / `flutter/cupertino.dart`；业务页面只 import 我们自己的 `adaptive_widgets.dart` / `common_widgets.dart`（将来设计库再变只改这两三个文件）。
  - `pubspec.yaml` 里 `flutter_platform_widgets` **已删除且不许加回**；`flutter_localizations` 也已移除（用 `GlobalMaterialLocalizations.delegates`）。
  - 自己的脚手架：`main.dart` 单个 `MaterialApp.router`（外层 `CupertinoTheme`）、`WDAppBar`（自实现 `ObstructingPreferredSizeWidget`）、`AdaptivePageScaffold` / `AdaptiveTabScaffold`（Apple 用 `CupertinoTabBar`，Material **保持 Material 3 `NavigationBar`**，不要退回 `BottomNavigationBar`）。
  - `adaptive_widgets.dart` 提供 `AdaptiveTextButton`/`AdaptiveElevatedButton`/`AdaptiveSwitch`/`AdaptiveSpinner`/`AdaptiveTextFormField`/`AdaptiveFieldPrefix`（最小宽度，英文标签不溢出）。
  - 验证基线：analyze 无问题、1111 项测试全绿、iOS 模拟器构建+安装、Android `app-debug.apk` 构建成功。

## 同步记录状态口径：0 对象不叫「已完成」（2026-09-27）

- 用户现场指出：运行记录弹层写着 `同步记录 · 已完成`，下面却是 `上传对象 0 个 · 0 B` / `传输明细：本次没有传输任何对象`。**完成的是这次运行，不是传输**，两者不能混为一谈。
- 规则：`sync_runs.state` 不变（仍是 running/completed/failed，所有调度与门禁照旧）；只改用户读到的那句话。`lib/features/sync_profiles/model/sync_run_outcome.dart` 的 `runWindowTransfers` 用运行自己的时间窗取对象，`syncRunConclusionLabel` 给出结论：运行中 / 失败 / **无需传输**（completed 且本次 0 个对象）/ 已完成（本次有对象）/ 未知状态原样显示。
- **状态必须和它下面的计数同源**：弹层的上传/恢复计数、传输明细、列表行、概览副标题都用同一份 `runWindowTransfers` 结果；不允许再出现“已完成 + 0 个对象”。旧的 `runStateLabel` 已删除（它只看 state，必然重犯）。
- 文案边界：`无需传输` 只说这次运行没有可传的对象，**不等于**“云端已是最新/已完整备份”（格间尚未发布新批次时也是这个结果）。文件同步域的位置状态另有 `已是最新`，两个词不要互相套用。
- 未改：活动页「最近同步」（用词是同步完成/同步失败、且不显示对象计数，要同规则需另加跨配置传输历史查询）；首页状态卡「上次备份已完成」（它是“上一次运行结束了”的时间陈述）。
- 回归：`test/features/sync_profiles/run_conclusion_test.dart`（9 项：时间窗边界、四种结论、未知状态、空运行弹层全屏无“已完成”、有对象仍是已完成、英文不回落中文、真实页面三处口径一致）；渲染证据 `ui_test_results/run-conclusion-20260927/`（`run_conclusion_visual_qa_test.dart`，真实 CJK 字体，未设环境变量时只断言不写文件）。详见 `docs/verification/2026-09-27-run-conclusion-status.md`。

## 连接说明的内容口径（2026-09-27）

- 用户现场（WebDAV 连接说明）：「我感觉这个说明有点不对呢」。核对后确认三类问题：①「条件创建/范围下载/安全存储密码」是适配器内部黑话，用户看不出「不会覆盖我的文件」；②「范围下载」「回收站」是 App **从未调用**的服务端特性（同步引擎不做范围读；Drive 的 delete 是永久删除，不走回收站）；③「断点续传取决于服务器能力」是**错的**——WebDAV `supportsResumableUpload: false`，引擎也不持久化上传会话（`providerCheckpoint` 无人写入），中断必然整份重传。另外该文件当时是纯中文常量，英文界面会显示中文（`sync_english_pages_test.dart` 里有显式技术债记录）。
- 规则：`lib/providers/provider_capability_summary.dart` 只描述 App 对这种连接**实际实现**的行为，且**不得超出适配器的 `RemoteCapabilities`**（文案与旗标不一致就是 bug）。每个字符串必须本地化，`context` 用 required-but-nullable，调用方不能忘传 locale。
- 文案结构：功能说明（能做/不覆盖）+ 注意事项（限制）+ **「登录信息」独立一行**（密码/令牌存在系统安全存储，属于 App 的存储方式，不再混进“功能”里当卖点）。
- WebDAV 现在明说「不支持断点续传：大文件中断后要从头重新上传」；云盘说「大文件按分片上传」但**不说**可恢复上传，并补一句「上传中断后下一次会重新开始」。将来真做了会话续传，文案与测试必须一起改。
- 回归：`test/providers/provider_capability_summary_test.dart`（7 项，含黑话/未使用特性黑名单、实例化 `WebDavObjectStore` 对齐 `supportsResumableUpload`、英文 locale 全行无中文）；`test/l10n/sync_english_pages_test.dart` 的例外已删除，改为「the connection info sheet paints no Chinese」；`connection_edit_entry_test.dart` 更新断言。渲染证据 `ui_test_results/connection-info-20260927/`。详见 `docs/verification/2026-09-27-connection-info-copy.md`。

## 行图标：卡片里不许只有一行没图标（2026-09-27）

- 用户现场（管理 tab 截图，箭头指着「重新连接格间」）：「这里差一个图标」。该行直接位于有云图标的「更换保存位置」下面，自己却没有 leading。同类缺陷还有概览卡里条件渲染的「查看等待传输的内容」（同卡另外三行都有图标）。
- 规则：**同一张卡片（AdaptiveListSection）里的可点行，要么都有 leading，要么都没有**；不能因为某行是后加的条件行就漏掉。无关的整卡（例如只有一行的「暂停备份」「详细记录与诊断」）不强制加图标。
- 图标选择沿用已确立的词汇：连接相关用 `CupertinoIcons.link`（新增连接行、连接详情页头同款），等待传输用 `CupertinoIcons.tray_arrow_down`（与 `_PendingTab` 空状态同款），保存位置用 `cloud`，管理用 `slider_horizontal_3`。别为一次性观感引入新图标词汇。
- 回归：`test/features/sync_profiles/sync_profile_row_icons_test.dart` 用真实内存数据库渲染概览卡与「管理」tab，逐个断言上述行的 `AdaptiveListTile.leading` 非空（条件行通过预置一个未完成传输让它出现）；渲染证据 `ui_test_results/profile-row-icons-20260927/`。详见 `docs/verification/2026-09-27-row-icons.md`。

## 格间本地改动「立即打包」（2026-09-27）

- 现场：用户在格间「文件」页加入一个文件后，Sync 连点 4 次「立即备份」全是「无需传输」。查设备数据确认：那 4 次运行时 `SyncExchange/Outbox/Ready` 确实为空（`无需传输` 没说谎），但根因在格间——**文件域没有打包出口**：相册导入、凭证/卡/备注、文档、设置页、以及应用启动基线都会调 `exportPendingExchangeChanges`，文件（导入/改名/移动/删除/新建目录）不会，只能等下一次启动基线（现场：09:18:05 加文件 → 09:21:16 重开格间才打包 seq3）。
- 修复在格间仓库：新增 `SyncPendingChangePackager`（debounce 400ms + 单飞 + 尾随补跑 + 退后台 `flush`），由 `SyncStateRepository.recordNextLocalChangeInTransaction` 单点通知（覆盖 file/file-tag/document/password/card/note），Dashboard 启动时用完整 runtime 安装；启动那次导出改走 `exportNow()`，避免与通知并发的第二次导出争抢同一批 pending。
- 设备验证：不重启格间，新建文件夹 / 删除文件夹都在 **0.96 s** 内出现 `Outbox/Ready` 批次；随后 Sync「立即备份」把 seq4/seq5 的 operations/envelope/commit 全部上传并写回执。
- 规则：以后遇到「改了东西但同步说无需传输」，先查该域有没有通知打包器，不要把「无需传输」当成「没有改动」——它只说明这次运行没有可传对象。格间侧新增本地写入者不得绕过 `recordNextLocalChange`。
- 证据 `ui_test_results/companion-packaging-20260927/`，详见 `docs/verification/2026-09-27-companion-prompt-packaging.md`。

## 删除保护链与暂存空间卡片（2026-09-27）

- 用户现场（设置页截图）：「这个删除保护和暂存空间现在还真的生效吗？业务逻辑是什么」。查设备数据：`garbage_collection_runs` 97 行**全部 skipped**（`completed` 0 行），9-26 是 60 次 `no-candidates`（当时 checkpoint 能恢复、活跃设备 1 台），9-27 00:54 起连续 23 次 `checkpoint-missing`；`<support>/staging/` 只有一个空的旧 profile 目录。
- 根因（同一个 commit `6f871317` 把 WebDAV `list()` 的 404 从「当空目录」改成抛 `RemoteObjectNotFoundException` 之后暴露）：①格间 checkpoint **没有 parts**（适配器恒 `parts: const []`，发布器从不建该目录），恢复端却无条件列 `checkpoints/<id>/parts/` → 404 → 该候选被当「不可用」跳过 → 每个候选都跳 → 每次 GC 记 `checkpoint-missing`，候选清单根本不会被读；②单设备 vault 从没发布过 ACK，`RemoteAcknowledgementReader` 无条件列 `acknowledgements/` → 404 → 即使修好①也会 `gc-error`。
- 规则：**「集合从未创建」不等于「读不到」**——但只对 fail-closed 的发现路径成立（读不到 checkpoint/ACK 只会继续跳过清理、不会授权删除）。业务目录列举（明文镜像）**保持 404 抛错**，不能拿这条去放宽。
  - 新能力 `CheckpointWithoutPartsDatasetAdapter`：声明无 parts 的数据集，恢复时不再探测 `parts/`；带 parts 的数据集保持严格（parts 目录消失仍跳过该候选）。格间适配器实现它。
  - `SyncCheckpointRecovery._committedCandidates` 与 `RemoteAcknowledgementReader.read`：该集合 404 = 「还没发布过」，返回空而不是让运行失败/记 `gc-error`。
- 界面口径：`已开启` 不再写死（无可信检查点 → **尚未生效**）；`最近清理` 只在 `completed` **且 `deletedObjectCount > 0`** 时显示时间（跳过/失败也写 `completed_at`，而 `completed` 也可能一个都没删——保留期没到；旧逻辑因此会说「刚刚」）；`等待确认`/`活跃设备` 在没跑到那一步时显示 **尚未统计**，不拿 DB 初始值 0 冒充事实；脚注写「上次检查：<相对时间>。…已跳过。」。
- **删除「暂存空间」卡片**：唯一写入方（旧版加密 selected-folder）已淘汰，格间只用该目录做剩余空间预检，明文同步不经过它，卡片永远 0 B、按钮是空操作。`StagingSpaceManager` / `cleanupStaging` / 脱敏诊断里的暂存用量保留（诊断仍报告；旧版页面代码路径未动）。
- 回归：`sync_checkpoint_recovery_test.dart`（6）、`sync_profile_runner_test.dart` 的端到端「无 parts + 单设备 + 无 ACK + 404 集合 → GC 真的 completed 并删 1 个对象」、`remote_acknowledgement_reader_test.dart`、`sync_settings_deletion_protection_test.dart`（三种状态 + 暂存卡不存在）、`sync_settings_english_test.dart`（英文页无中文、无 `Staging space`）、`deletion_protection_visual_qa_test.dart`（真实字体三态渲染，`ui_test_results/deletion-protection-20260927/`）。全量 **1120 项**通过。
- **设备实测**（同一台 iPhone 17 Pro Max 模拟器 + 用户真实 NAS）：装好修复后的 Debug 包启动，第一条 GC 记录（10:37）即为 `completed`，`checkpoint_id=v1-54c5db05…`（真从远端恢复）、`活跃设备=1`（首次是测量值）、`候选=1`、`可清理=0`、`已删除=0`；说明更早构建一直在正常**发布** checkpoint，断的只是恢复读取。
- 边界：保留期决定了现在**还不会真的删**——唯一候选（seq 5、`retentionHoldUntil=2026-10-27`）要到约 **2026-12-03** 才可能满足 cutoff（30 天保留 + 7 天缓冲 + hold）；在那之前 `可清理=0` 是设计如此，不是故障。详见 `docs/verification/2026-09-27-deletion-protection-chain.md`。

## 简化纸卡的加密恢复文件（2026-09-27）

- Apple Velock 备份开始前通过 `VelockRecoveryTransport` 上传并回读验证 companion 的 `Recovery/Outgoing/<vaultId>.json`。缺文件写失败记录 `local.velock_recovery_required`，提示打开并解锁格间；不得假报完成。
- 恢复引导支持未配对时选择原云端连接/目录，只下载有上限的密文文件至 App Group `Recovery/Incoming/selection.json`，不索取账号密钥/密码，不在 Sync 解密。原生授权边界和普通配对流程保持。
- 云端对象 `velock-recovery-<lookup>-<contentHash>.json` 不可变，密码版本并存，不纳入业务数据清理。WebDAV 列举根目录后过滤文件名，不能把字符串前缀当目录。取回结果原子提交，过期/已离开页面的异步结果不覆盖新选择。
- 旧备份缺文件时需要旧完整二维码/VSR1，或原设备升级解锁后再备份。Android 不在本次 App Group 扩展范围。
- 详见 sibling Velock 的 `docs/verification/2026-09-27-compact-cloud-recovery.md`；真实本地 WebDAV 密文往返已验，但不冒称重新完成全部业务恢复 E2E。


## 更换保存位置保留新建文件夹（2026-09-27）

- 用户要求只移动「新建文件夹」按钮，不能减少功能。管理 → 更换保存位置必须显示「选择备份文件夹」，左侧上一级、右侧新建文件夹，复用已有 creator。`changeVelockBackupLocation` 的 picker 模式应随 `requireExistingBackup`，不能固定 restoring=true；只有寻找原历史/恢复入口保持只读。创建后进入空目录，仍需明确使用/保存，不自动备份或迁移。回归与设备验收见 `docs/verification/2026-09-27-manage-new-folder.md`。

## 「打开格间」直达云备份（2026-09-27）

- 首页/详情/向导 `openVelockForBackup` 的 launcher 必须复用 `velockBackupSettingsLauncherProvider`，发送 `velock://sync-settings`；不得退回仅唤醒旧页的 `velock://open`。此入口不创建配对请求、不携带requestId、不等于授权完成。
- Sync49项、格间23项相关回归通过；新版Sync Debug已安装现有iPhone 17 Pro Max，GUI确认点击「打开格间」→锁屏→解锁后自动进入云备份，未改连接开关。详见 `docs/verification/2026-09-27-open-velock-cloud-backup.md`。

- 2026-09-27 用户补充：真实 NAS 只有 `USB_HDD_8T` 下已知有新建文件权限，其他目录权限不确定。联调写入应选择该目录下用户指定的实际位置；不得假定共享根或其他目录可写。本次快照测试使用 localhost 隔离 WebDAV，未写用户 NAS。

## 原备份丢失后建立新备份（2026-09-27）

- 已接通 Apple「原来的备份找不到了？」→选择新空目录→格间明确生成当前完整内容→Sync 不可变上传/完整回读→CAS 切换本 profile；不改账号身份、不清 cursor、不伪造旧历史完整。只能重建当前本机仍完整可读的内容，不找回已丢失历史。
- 新设备先取回密文恢复文件并在格间使用纸卡恢复原账号，再配对下载快照，由格间真实落库/全内容读回和签名完成回执后推进。首页启动/回前台仅在待恢复配置出现本地完成回执时续接；回执存在不等于验证通过。
- 新目录仅快照、还无增量集合时：只有本次完整验证的 snapshot baseline 绑定同 remote/vault/producer，且覆盖位置等于 appliedSequence，才允许首次 commits 列举404为空；普通集合、超过基线、后续分页404不放宽。
- 真实专用 iOS26.5 Debug + localhost WebDAV 分阶段验收：6类内容重建/切目录、空白账号恢复、Native快照恢复、5类UI正文/原图 + 文档Native读回、源端新增seq7→恢复端实际打开正文与7条revision一致。测试失败后修复重试已记录，不能冒称最终包从零单次全流程或真实NAS验收。详见 `docs/verification/2026-09-27-rebuild-missing-backup.md`。
- Native生成原先卡在新装库缺`t_sync_conflict_resolution_intent`（补onCreate及同版本onOpen幂等修复），另修未用File/Media目录不存在时的journal检查。不得通过删除用户数据或跳过密文读取绕过。


## 建立新备份完成页返回（2026-09-27）

- 「返回备份」不能仅 `context.go('/')`：帮助/重建页通过 `Navigator.push` 叠在 StatefulShellBranch 首页上，地址已经是 `/` 时同地址跳转不会移除它们。先取得 router、当前 Navigator `popUntil(route.isFirst)` 关闭流程，再 `router.go('/')`。
- 回归必须覆盖真实 GoRouter + StatefulShellRoute 下首页/详情两种入口和 iOS/Android；直接把完成页作为 MaterialApp.home 无法复现。相关 48 项通过，见 `docs/verification/2026-09-27-rebuild-return-navigation.md`。


## 新位置完整备份必须记成功记录（2026-09-27）

- 快照重建绕过普通 runner，不能只记录随后空增量的「无需传输」。schema 13 的 sync_runs.rebuild_json 保存独立完成摘要，必须与 profile CAS 同一事务提交；上传/回读/授权未通过不记成功。
- 记录标题「新备份已建立」，详情是「已校验的备份内容」（快照加密对象数/字节），不能把重试验证字节冒充本次上传流量，也不当业务文件数。普通 0 对象 run 保持「无需传输」。
- 旧版遗漏只在持久 job、成功切换后的完整 profile、签名回执和签名清单一致时补回，保留原时间并说明来源；准备完成本身不能证明上传完成。见 `docs/verification/2026-09-27-rebuild-history.md`。


## 新位置备份性能优化（2026-09-27）

- WebDAV 父目录缓存仅在上传/原子发布成功后填充，限定单client/scope；失败清空，显式删除失效子树。不把MKCOL405/409当存在证明，不用缓存放宽防覆盖或自动重放流。11个同目录对象的父目录MKCOL由44降到4。
- 新快照保留upload逐对象完整读回hash校验，之后不再重复全量baseline验证，完成页不再追加普通runner；本次成功与目录CAS仍原子记录。准备快照后的新修改下一轮处理，文案必须明确。
- 独立下一轮同步仍重新完整验远端快照；不得把本次优化扩展成永久可信缓存或关闭历史完整性门禁。165项相关回归通过。见 `docs/verification/2026-09-27-snapshot-transfer-optimization.md`；通俗说明 `docs/guides/velock-sync-explained.md`。

## 2026-09-29 QA 修复（双模拟器 19 条）

- 401 的格间备份主操作是「修改连接」（`BackupAction.fixConnection`→`backup_connection_fix.dart`），保存后必须再确认才重试，保存本身不启动备份；不要再把 401 送进无法改密码的管理页。
- 连接被拒绝/重置 ≠ 离线：分类为 `network.unreachable`，文案提示检查地址端口与服务器；`network.offline` 仅为旧记录保留。
- 等待格间应用快照的恢复 profile 提供「检查恢复进度」，回前台自动检查；前台自动同步结束要刷新首页卡片。
- 文件同步选择远端目录时，按内容拒绝含 `velock-sync` 的格间备份目录（不只查本机 profile）。
- 格间侧：恢复密钥输入规范化（U+2011 等短横线）、等待恢复横幅由 `waitEnded` 信号刷新、恢复场景批准文案。详见 `docs/verification/2026-09-29-qa-fixes.md`（Sync 1303、格间 1399 项通过；未模拟器复测）。

## 百度网盘 / 阿里云盘连接（2026-09-30）

- 新建连接直达协议列表（中间页 `new_connection.dart` 已删）。百度 `BaiduNetdiskObjectStore`（xpan，token 走 query、错误是 HTTP200+errno、4MiB 分块 MD5、`rtype=0` 防覆盖、返回路径不同即拒绝、spool 必删）与阿里云 `AliyunDriveObjectStore`（openapi.alipan.com，`check_name_mode=refuse`、预签名 URL 过期仅刷新一次、存储域名不带 Bearer、同名改名即拒绝）均已接入 OAuth、目录选择、连接说明与矩阵。
- 内置密钥只在构建时注入（`BAIDU_NETDISK_APP_KEY`/`BAIDU_NETDISK_SECRET_KEY`/可选 `BAIDU_NETDISK_APP_FOLDER`、`ALIYUN_DRIVE_CLIENT_ID`/可选 `ALIYUN_DRIVE_CLIENT_SECRET`、`GOOGLE_OAUTH_CLIENT_ID`、`ONEDRIVE_OAUTH_CLIENT_ID`），用 `cp oauth_keys.example.json oauth_keys.json` + `--dart-define-from-file`，见 `docs/OAUTH_SETUP.md`。

### 网盘应用密钥：仓库不带、用户可自带（2026-09-30）

- 用户原话：「我这是开源项目啊，我注册好了，开源后，别人都能用我的key了？」。**仓库里不得出现任何网盘 AppKey/Client ID/Secret**；`oauth_keys.json` / `*.oauth_keys.json` 已 gitignore，示例 `oauth_keys.example.json` 全部留空（空 define 视为“没有内置密钥”，`BAIDU_NETDISK_APP_FOLDER` 空值回落 `Velock Sync`）。
- 没有内置密钥不再是死路「此版本暂未开通」：连接页给「使用自己的应用密钥」表单（`oauth-own-*` keys，Google/OneDrive 只要 Client ID；百度要 AppKey+SecretKey+应用名称；阿里云 App ID、Secret 可选），存在系统安全存储 `velock-sync/oauth-client/<type>`，优先于内置密钥，release 构建也可用。**用户自带密钥是开源版的正常路径**（2026-09-30 用户：“作为一个开源第三方应用，本来就是应该让用户自己去填”；开发者注册内置密钥那条路暂停）：协议列表直接列出四家网盘，没有内置密钥的副标题写明在哪个平台注册（Google Cloud / Microsoft Entra / 各开放平台），不再折叠「更多云盘」。
- 用户自带的 secret 随该次登录的 token 一起保存（刷新需要它）；**内置 secret 永不持久化、也不混进用户自己的应用**（`isBuiltInClientId` 判定）。已有连接保留它登录时用的密钥，改/删自带密钥只影响下一次登录。
- 面向用户的界面与帮助不得出现 dart-define/环境变量等构建术语（开发者表单与 `AppKeys` 中的 OAuth Client ID 已删除）。
- **Google 自带密钥 = iOS 类型客户端**（2026-09-30）：Google 的 iOS/Android 客户端不能登记自定义回调，所以 `velocksync://oauth/callback` 对 Google 永远不可用。Client ID 必须形如 `<前缀>.apps.googleusercontent.com`（否则 `oauth.registration.google_client_id_invalid`），回调由 `OAuthPublicClientConfiguration.redirectUriFor` 推导为 `com.googleusercontent.apps.<前缀>:/oauth2redirect`，内置 Google 密钥同样适用；表单展示并可复制软件包 ID `tech.windata.velock.sync`（key `oauth-bundle-id`）。这个 scheme 不在 Info.plist 里声明，而是经 iOS `ASWebAuthenticationSession`（`AppDelegate` 的 `WebAuthenticationController`，通道 `tech.windata.velock.sync/web_auth`，`oauth_web_authentication_session.dart`）直接拿回调；state 仍由 session 校验。**非 iOS 平台没有 capturer**：遇到非 velocksync 回调在打开浏览器之前抛 `OAuthRedirectUnsupportedException`，界面说明「目前只支持 iPhone 和 iPad」；Android 若要支持需另做（loopback 等），不要回退成打开浏览器后收不到回调。
- Google 范围是 `drive.file` + `drive.appdata`（默认根 `appDataFolder` 必须有 appdata 范围；两者都非敏感，发布为正式版无需 Google 审核）。同意屏幕停在「测试」时 refresh token 约 7 天过期、只有测试用户能登录，自有项目仍可能显示“未经验证”，帮助页与 `docs/OAUTH_SETUP.md` 已写明。
- 现场验证（2026-09-30，Debug 模拟器）：用户自己的 iOS 类型 Client ID 填入后，系统弹出“想要使用 accounts.google.com 登录”，继续后进入 Google 登录页（显示用户同意屏幕的应用名），**没有 redirect_uri 错误**。完整登录/选目录/上传需用户自己输入账号，截至记录时未完成。用户提供的 Client ID 与 plist（含 API_KEY）**不得写进仓库**，测试用 `123-abc.apps.googleusercontent.com` 之类占位。
- 回归：`test/providers/oauth/oauth_client_registration_test.dart`（12 项，含变异检查）、`remote_provider_availability_test.dart`、`backup_navigation_test.dart`（四家各：折叠入口、自带密钥表单、显式保存）。未验证：真实账号端到端；Google iOS 客户端是否接受自定义 scheme `velocksync://oauth/callback`。
- 验证边界：两家各 16 项 V1 契约 + 专项用例在**有状态假服务器**上通过并做过变异检查；接口细节未能对照官方文档在线核实，**没有真实账号端到端**。`velocksync://oauth/callback` 是否被两家后台接受、百度 `/apps` 目录限制、阿里云默认盘/资源盘选择都待真实账号确认。百度 secret 打进客户端二进制可被提取。

### 代理网络与 Google Drive 实测（2026-09-30）

- 用户电脑经系统代理（被墙）访问 Google。Dart `HttpClient` 不读系统代理，原先登录页（系统浏览器，走代理）成功后 token 交换无限挂在「正在连接」。现在所有远端 HTTP 一律用 `newSyncDio()`（`lib/infrastructure/network/sync_http.dart`）：有限超时 + iOS 读取系统手动代理（原生通道 `tech.windata.velock.sync/system_proxy`，启动与回前台刷新）；回环/链路本地/简单主机名/系统例外列表直连，PAC 不评估、畸形设置直连。**禁止再新建裸 `Dio()` 做远端请求。**
- Google Drive 实测（iOS 模拟器 Debug、iOS 类型客户端、`appDataFolder`、经代理）：登录、选目录、上传/回读字节一致/防覆盖/列目录/删除全部通过。首轮实测发现 `_lookup` 漏 `spaces=appDataFolder`，导致 Sync 专用文件夹里**读不回、删不掉（静默跳过）**；已合并成单次查询并加有状态回归（去掉 spaces 必红）。旧假服务器不看查询参数，所以没抓到——Drive 测试的 fake 要按真实 space 语义回应。
- 复测入口 `tool/live/oauth_drive_probe_main.dart`（复用模拟器上已登录的连接，只碰 `velock-probe-*`），用法见 `docs/OAUTH_SETUP.md`「Live check on a simulator」。用完重装正常包。OneDrive/百度/阿里云尚无真实账号实测。
- Google 细粒度授权页默认不勾选权限，用户需勾选（全选）；App 目前不校验 token 返回的 scope，缺权限时会在后续请求才报 403（待改进）。

### 文件同步支持云盘（2026-10-01）

- 明文文件同步现支持 WebDAV、百度网盘、OneDrive、阿里云盘与 Google Drive（`RemoteObjectStoreFactory.plainMirror`，各家 `asMirror(scope:)` 真实路径镜像）。选远端目录走 `pickPlainRemoteFolder`，读不到时有「修改连接」。
- **Google Drive 必须是“完整访问”连接**（用户 2026-10-01 选择）：从文件同步添加时路由带 `access=full`，只申请 `https://www.googleapis.com/auth/drive`，登录后用 `grantsGoogleFullDriveAccess` 校验 Google 真的给了（同意页可取消勾选），连接记录 `fullDriveAccess: true`；重新登录保持该参数。格间备份用的 `drive.file`+`drive.appdata` 连接（含 `appDataFolder`）不能用于文件同步，界面会说明并引导新建。`drive` 是受限范围：测试状态约 7 天要重新登录、提示未验证应用，正式发布需 Google 审核。
- Google 同一文件夹允许同名项目：镜像按层用 ID 查名字，同名（含与 Google 文档同名）一律停止并报 `provider.google.duplicate_name`，绝不随便挑一个读写/删除；Google 文档/表格/快捷方式跳过；删除进回收站；替换内容用 PATCH 续传上传保留同一 item。
- 验证边界：五家均只在有状态假服务器上通过（含变异检查），**没有任何真实账号的文件同步实测**。
- **重叠提示要说清是哪两个目录**（2026-10-01 用户：“怎么报这个提示？”，选的是格间备份目录的父目录）：`BackupFolderOverlapException` 带 `chosenSegments`/`backupSegments`，向导与详情页共用 `backupOverlapMessage`，区分“里面含有备份目录 / 在备份目录里面 / 就是备份目录 / 内容里检测到 velock-sync”，并给出路径与做法（选不含该子目录的文件夹或新建专用文件夹）。守卫本身不放宽。
- **WebDAV 连接可自定义名称**（2026-10-01 用户：“新建连接不能自己输一个名字吗？”）：表单选填区首行「名称」（key `webdav_name`），编辑时预填当前名称；留空 = 服务器地址（`defaultConnectionName`）。`setProtocolAndFinalize(name:)` 与 `replaceWebDavConnection(name:)` 传入；`reconfiguredWebDavConnection` 的 `name: null` 保留原名（其他调用方不受影响）。OAuth 的名称仍是「更多设置」里的账号备注。
- **目录图标/列表两种显示，全局一个开关**（2026-10-01 用户：“格间这边是 GridView，同步目录那边又是 ListView？能不能同时支持 2 个，让用户可以切换”）：`FolderViewMode`（`lib/features/connection/state/folder_view_mode.dart`，`AppKeys.folderViewMode` 持久化，启动时由 `main.dart` 覆盖 bootstrap，写入失败只影响下次启动）。连接浏览页与 `BackupFolderPicker` 共用 `FolderViewToggle`（key `folder-view-toggle`）、`RemoteEntryTile` / `RemoteEntryRow` / `remoteEntryGridDelegate`（`remote_folder_views.dart`）；列表行显示文件大小与修改时间。两种模式下条目 key 不变（选择器 `backup-folder-<名>`，浏览页 `remote-entry-<名>`），UI 自动化不受影响。`BackupFolderPicker` 现在是 ConsumerStatefulWidget，单测要包 `ProviderScope`。
- **连接浏览页可新建文件夹**（同日用户：“GridView 的这种方式里没有创建新文件夹的入口？”）：路径行右侧 `remote-browser-new-folder`，与选择器共用 `showNewRemoteFolderDialog` 与 `remoteFolderCreationError`（同一份校验/文案）；经 `backupFolderCreatorProvider`（单次 MKCOL）在当前目录创建，相对段由当前路径相对连接根计算；成功后留在原目录刷新列表，失败弹提示且不重试。同名文件或文件夹都拦截。回归 `test/features/connection/folder_view_and_create_test.dart`。
- **两个目录页的工具条一致**（2026-10-01 用户：“新建文件夹一个是纯图标，一个带文字”）：新建文件夹统一用 `NewRemoteFolderButton`（纯图标 + tooltip/语义标签，位于切换按钮左侧）；选择器的 key 仍是 `new-backup-folder`，浏览页是 `remote-browser-new-folder`。
- **「修改连接」不用笔**（同日用户：“编辑按钮不要用那支笔…实在不行就自己 svg 画一个”）：`lib/widgets/connection_settings_glyph.dart` 自绘「服务器 + 齿轮」（24 格、1.6 描边，跟随 IconTheme 颜色），连接浏览页页头（key `connection-edit`，23pt）与选择器「修改连接」使用；连接列表菜单项仍是系统 IconData。回归 `test/widgets/connection_settings_glyph_test.dart`（`GLYPH_PREVIEW=<png>` 可输出对照图）。
- **刷新按钮只留真的会访问服务器的**（同日用户：“到处都有那个刷新按钮，好像点了也没什么用”）：格间首页、文件同步首页、两个详情页、活动页的页头刷新只是重读本机数据库（页面在操作后、运行中本来就会自动刷新），已删除；首页与活动页保留下拉刷新。保留的三处：连接列表「检查连接状态」、连接浏览页「重新读取文件夹」（不再弹“已更新连接状态”）、OAuth 连接详情「检查连接」。iOS 图标统一用 `CupertinoIcons.arrow_clockwise`（旧 `CupertinoIcons.refresh` 像“回退”，不要再用）。
- **对话框用自己的卡片，不用老式 CupertinoAlertDialog**（2026-10-01 用户：“这个app的对话框太素了吧，看着像Android的，但是我也不是说要搞为iOS老版本的那种风格”）：Apple 平台的 `showAdaptiveAlert` / `showAdaptiveConfirmation` / `showAdaptiveNotice` / `showAdaptiveForm` / `showAdaptiveTextInputs` 统一走 `lib/widgets/app_dialog.dart` 的 `AppDialog`（`showAppDialog` 淡入+轻微缩放呈现）：大圆角磨砂卡片、左对齐标题、可选着色图标徽章（有破坏性操作时自动变红）、胶囊按钮（两个且放得下时并排，否则竖排且主操作在上）；主操作品牌色填充、破坏性主操作红色填充、其余灰底；禁用只降到 `AppOpacity.disabled`，不换色。弹窗里的输入框用 `AppDialogTextField`（填充无边框，聚焦品牌色描边，`invalid` 时红色描边）。底部选项菜单（`showAdaptiveActionSheet`，含所有 `AdaptiveActionMenu` 的「更多操作」）同日改为同风格的 `AppActionSheet`（2026-10-01 用户：“底部的更多操作菜单也改成同样风格”）：底部浮起的磨砂圆角卡片、左对齐标题、选项为圆角行（可带图标，破坏性项红色图标与文字）、取消是底部单独的灰色胶囊；`AdaptiveAction.icon` / `AdaptiveActionItem.appleIcon`（缺省回落 `icon`）提供 Apple 图标，连接菜单「修改连接」用 `ConnectionSettingsGlyph`。Android 保持 Material `AlertDialog` / `SimpleDialog`。按钮 key 照旧并经 `withAutomationId` 暴露；测试里找 iOS 弹窗用 `find.byType(AppDialog)`、菜单用 `find.byType(AppActionSheet)`。回归 `test/widgets/app_dialog_test.dart`。
- **「云端保存位置」页只做一件事：把问题解决掉**（2026-10-01 用户：“这个页面有点啰嗦，而且出了问题，也没有给去解决问题的入口”）：`BackupStorageHelp`（标题「云端保存位置」）首屏只有一张卡：连接名+路径、带图标的一句结论、主按钮、次按钮「检查此位置/重新检查」、一行脚注。进入时从本机最近一次失败运行读出原因（`latestSyncRun`，**不访问服务器**；探针仍只在用户点检查时写）。不能写入（`atomic_create_unsupported`/`collection_not_writable`）→ 主按钮「更换保存位置」（key `storage-change-folder`），格间备份复用 `changeVelockBackupLocation`（含新建文件夹，确认后只保存位置，不自动备份），保存后就地生效，需重新检查；登录被拒（401/unauthor，与首页同一规则）→ 主按钮「修改连接」（`storage-fix-connection`，复用 `editBackupConnection`）；检查通过 → 「开始备份」（`storage-sync`）。已删除只读「浏览此连接的文件夹」、「关于这次检查」展开卡和底部重复说明，不要再加回来。回归 `backup_storage_help_test.dart`（含格间换目录、401 入口）与 `backup_storage_help_folder_test.dart`。

## 18 种语言与商店截图（2026-10-02）

- 用户要求 Sync 与格间一样支持 18 种语言（简繁中、英、ar de es fr hi id it ja ko nl pl pt ru tr vi），**商店页 + App 界面都要**；中文名「格间同步」（繁体「格間同步」），其他语言显示名 Velock Sync。
- 界面仍只写 `syncText(context, 中文, English)`；其他语言按**英文原文**查 `lib/l10n/translations/sync_translations.dart`（生成文件）。流程见 `tool/l10n/README.md`：`dart run tool/l10n/extract_sync_text.dart` → `gen_translations.py --split` → 翻译新增 key 到 `tool/l10n/translations/<code>/partN.json`（可新开 part）→ `gen_translations.py` 校验并生成。缺翻译时运行时回落英文。
- **英文句子不能拆成片段拼接**：`'... on $en.'` 这种把英文短语塞进占位符的写法，其他语言会露出英文（2026-10-02 日语截图里出现 “the Baidu Netdisk developer platform”）。要么整句分别写，要么占位符的值本身也用 `syncText` 翻译（如 `why`、`or`）。
- 默认语言为「跟随系统」；`sync-language-<storageValue>` 是语言选项的 identifier。
- **改商店截图或文案前先读 `docs/release/store-screenshots.md`**（2026-10-03 起的跨会话入口）：三条路按代价排好了——只改画框/样式跑 `tool/store/recompose.sh`（约 2 分钟，不用模拟器，从 `ui_test_results/store/raw/` 已有原始截屏重套框）；只改标题改 `shot_strings.json` 后同样 recompose；只有 App 界面本身变了才需要 `all_shots.sh` + 模拟器。看线上实际在用什么跑 `tool/store/export_from_asc.py`（只读 ASC）。**Sync 自 1.0.1 起是 iPhone-only（`TARGETED_DEVICE_FAMILY = 1`），不要再生成 iPad 截图。** 画框样式在 `compose.py` 的 `STYLES`（现用 `deep`）、设备比例在 `GEOMETRY`（iPhone 16 Pro Max 真机比例：圆角 62pt、灵动岛 126×37pt、钛金属边框与侧键）。
- ⚠️ **截图是 Waiting for Review 期间唯一锁定的元数据**：版本在审核队列里时换不了截图，必须先撤出审核重新排队；版本上线后也只能随新版本换。所以截图改好先存在仓库里，随下一个版本一起上，不要为了换图把在审的版本撤下来（除非用户明确要求）。
- 商店截图：`tool/store/all_shots.sh iphone <udid> [lang…]`（需先跑完 e2e，有格间备份）。`testStoreShots` 不再匹配中英文文字：底部 tab 按位置点（阿拉伯语镜像）、返回用 `app-back`、新建连接用 `connection-new`，等待的状态文字由 `shot_env.py` 按翻译表查好传入。文件夹名/截图标题在 `tool/store/shot_strings.json`，字体按语言选（阿拉伯语用 Arial，SF Arabic 没有拉丁字母）。演示 WebDAV 端口 5005/8080 若被旧进程占用会直接报错（旧进程会用别的目录应答，导致“历史不完整”）。
- 商店文案在 `tool/store/metadata/<ASC 地区>/`（24 个地区），名称/副标题 ≤30、关键词 ≤100、推广文本 ≤170。
- **并行出截图**：`all_shots.sh iphone <udid1>,<udid2>,…` 按语言轮流分给多台模拟器（每台独立端口 8080+i、DerivedData、日志）。截图慢是因为 UI 自动化在等动画/同步，CPU 很闲，单台每种语言约 4 分 20 秒；4 台并行 12 种语言约 14 分钟。⚠️ `simctl clone` 出来的模拟器**仍指向原模拟器的 App 数据目录**（`get_app_container` 返回原机路径），多台会互相覆盖；克隆后必须在克隆机上 `uninstall` 再 `install` Sync 与 `CrossAppUITestHost.app`（`ui_test_results/sim/DerivedData/Build/Products/Debug-iphonesimulator/`）。用完删除克隆（名字 `Velock Shots iPad N`）。
- 上传截图：`~/.velock-release/sync-shots/fastlane/Deliverfile`（只传截图，`skip_metadata`，不提审）；文案用 `~/.velock-release/sync_push_meta.py`（ASC API 直推 tool/store/metadata 下 24 个地区）。

