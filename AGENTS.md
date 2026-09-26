# AGENTS.md

本文件是本仓库的项目级记忆（Codex / 协作者共用）。

## WebDAV

### 1. 用户 NAS（远程，联调主用）

- 地址、账号、密码记录在 `tool/local_webdav/nas_webdav.local.env`（已 gitignore，**禁止提交、禁止复制到受版本控制的文件**）。
- 需要凭据时先读该文件，例如：`set -a; source tool/local_webdav/nas_webdav.local.env; set +a`，再用 `curl -u "$WEBDAV_USER:$WEBDAV_PASSWORD" ...`。
- NAS 文件系统路径 `/vol4/1000/USB_HDD_8T/velock-sync` 在 WebDAV 上对应的真实目录是 `parcool 共享给我/velock-sync`（共享名带空格和中文，URL 需编码）。
- 若认证返回 401 或路径 404，先核对本文件记录并向用户确认，不要猜测或改写凭据。

### 2. 本机测试服务（WsgiDAV）

- `tool/local_webdav/start_local_webdav.sh [start|stop|restart|status]`，默认端口 8888、账号 `velock` / `velock123`，数据根目录 `ui_test_results/persistent-webdav-root`。
- 这是模拟器/本机自测用的假服务，与上面的 NAS 无关，勿混用凭据。

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

- 设计与验证记录：`docs/design/simple-cloud-backup.md`、`docs/verification/2026-09-25-simple-cloud-backup.md`。原 Sync `main` 备份为 `a1b7c6451afa40ce1f43de056c2288daa72ab413`；格间 `main` 备份为 `c5ba1ba2fa34c1f8e6935c9a1515acb2d42c2691`；两仓库服务器均有 annotated tag `backup/20260925-before-simple-sync`。重构交付分支为 `codex/simple-cloud-backup`，不得把 UI 重构当成完整协议实现。
- 三个主入口为格间/文件同步/设置；技术计数放二级诊断，必要冲突/待授权不隐藏。格间负责加解密、原账号恢复和实际应用数据，Sync 只传输且不索取恢复卡密码/秘密；授权、建连接、预检、上传对象或下载完成不得表述为完整备份/恢复成功。
- 恢复必须先由格间找回原账号并签名授权；Sync 仅对原位置中签名授权内可信 producer 的候选历史做只读发现，随后仍走既有 runner 校验并由格间应用。候选发现不是完整验签/内容验证。返回新增云端页面必须保留 restore intent/已批准授权并自动继续；`returnTo` 仅允许已知内部流程。
- OAuth 普通用户默认不看 Client ID/Token/root ID；公开注册未配置时明确本版本暂不可用并提供其他位置。开发者配置默认折叠，输入仅在保存后生效。预检仅 `ifAbsent` 写随机无敏感 probe、读回校验、只删自己成功创建的 probe；恢复探测不写远端。
- 未完成项：current-state 完整快照传输/恢复状态机、可验证六类业务内容摘要、版本选择、自动完整云端迁移、单向仅上传文件夹模式。现有 runner 仍双向，本轮不是 upload-only 改造或完整架构重写；原签名/历史连续性/blob/完成回执门禁不放宽。
- 最终 Sync 425 项、格间 29 项相关回归全部通过，两仓库改动范围 analyze 均为 No issues found；Sync 含 14 项真实路由、11 项预检及 13 项界面测试，后者另用真实字体渲染四张图验收（不重复累计）。日志在项目外 work/simple-cloud-backup-20260925，以 `sync-regression-final-accepted.txt`、`companion-regression-final-accepted.txt` 和 `visual-qa-final-accepted.txt` 为准。截图是真实 widget + 内存 fixture，不是模拟器/真机截图；本轮没有真机、模拟器、新 NAS 写入、真实 OAuth 授权或跨 App 恢复 E2E。

## 云备份后续：NAS 入口与 FN Connect

- 真实 FN Connect 根入口可 PROPFIND207 列共享目录，但 MKCOL405；必须选择实际可写文件夹。MKCOL405/409 现在分类 `provider.webdav.collection_not_writable`，不再误报原子防覆盖不支持，也不得取得/删除非自有探针目录。
- 同服务 MOVE 的 Destination 使用 RFC4918 允许的编码绝对路径，避免 FN Connect 转发下外部 absolute-URI 返回502；保留 Unicode/空格/转义/base 子路径/query。Overwrite:F、碰撞412与字节校验、发布201/源消失不放宽，禁止普通PUT回退。
- Sync432、格间32项相关回归通过，改动范围分析无问题。但真实FN Connect生产适配器仅1MiB不可变创建/内容校验通过，四并发阶段401，整组live test未通过；401后停止重试，已请用户解锁Mac并确认账号，不能宣称NAS或完整跨App同步已验收。详细证据 `docs/verification/cloud-backup-follow-up.md`。

## 临时授权恢复（2026-09-26）

- “格间已允许连接”不能仅判断 approval 非空：配对临时响应有 5 分钟有效期。向导用最早 request/response 截止时间、Timer 和继续/前台检查保持状态一致；过期必须给“重新授权”入口并保留云端位置/恢复 intent，不延长期限或跳过验签。
- finalizer 保存持久 profile 前重验到期；授权有效时发起的持久保存完成后，ACK 可晚于临时期限。同一 flow 的晚到结果不得覆盖新 session/reset；ACK 未完成不能被 clearCompletedFlow 清除或被已有 profile 卡片遮盖。
- 回归：`test/features/cloud_backup/velock_pairing_recovery_test.dart`、`backup_navigation_test.dart` 和 pairing/finalizer 单测。widget 持有应用级 Timer，必须在测试体 finally 中 reset/dispose，不能只在 addTearDown 清理。
- 现场根因与验证边界：`docs/verification/2026-09-26-pairing-recovery.md`。NAS 并发 401 与本轮临时授权过期是不同问题，禁止混称为 NAS 已全流程通过。


## WebDAV 格间备份目录选择（2026-09-26）

- 已有云连接不等于实际备份文件夹。格间向导选择 WebDAV 连接后必须提供目录浏览（读取只用 PROPFIND；备份模式可由用户明确确认新建空文件夹），再由用户确认完整目录；不能只提示用户进入共享文件夹却不给入口。
- `VelockSyncProfile.remoteRootSegments` 是相对于原连接的 decoded 路径段；旧配置默认空列表。不得全局改写原连接，否则普通同步与其他备份会被重定向。预检、恢复扫描、runner、inventory、join profile 重建必须保持同一 scope。
- 浏览仅 Depth:1 PROPFIND，拒绝外源/越界 href，不自动重试401/403，不把读取失败当空目录；除备份模式用户明确点击“创建并进入”后仅新建一个空文件夹外，尚未明确选择及最终确认时不得写入或创建配置；恢复模式保持只读。授权过期仍需重授权，不因选文件夹放宽签名/期限门禁。
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
