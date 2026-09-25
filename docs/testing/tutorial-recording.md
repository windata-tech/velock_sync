# 格间同步：中英文原片录制操作手册（会话间记忆）

> **2026-09-19 范围纠正（优先于下文历史基线）：** 用户明确文件、相册是重点，普通账号、信用卡、日记必须分别展示。旧 delivery-v2 只证明配置和一条账号，不是全内容同步验收。新版录制器固定 host 六类 `file,media,password,card,note,document`，UI 必须实际打开前五类；文档是额外 host 验证，不能冒称手机已展示文档。日记暂按备注/笔记，待用户确认。
>
> 默认必须先准备六类源数据，`prepared=true, keep_source=true`；`--check` 只读检查真实源库/加密文件。旧 zh/en 本机配置目前会报 **No file records**，这是正确拦截，禁止降回 password 绕过。录前准备必须完成，当前新增 UI 路径仍待实际设备验证，不是已录好的新版视频。

## 全内容固定样例与验收顺序

1. **文件优先**：`velock-sync-e2e-proof.txt`，实际打开预览并看到正文 `VELOCK SYNC REAL DATA E2E`；比较源/恢复密文大小、SHA-256、文件名/类型/父子关系。
2. **相册优先**：`velock-sync-e2e-proof.png`，采用 HostApp 新生成的 960×640 彩色演示图，不再用 1 像素图片糊弄。实际打开并等真实解码成功语义，再检查完整原图密文一致及媒体元数据；缩略图/空相册不算通过。
3. **普通账号**：`E2E Password`，解密详情显示 `e2e-user`，不能以“有一条凭证”概括卡和笔记。
4. **信用卡**：准备账号/卡的现有 seed 路径增加 `E2E_SEED_CREDIT_CARD=1`，单独创建 `E2E Credit Card`，使用合成 Visa 测试卡号 `4111111111111111`，打开卡详情确认内容。旧 `E2E Card` 银行卡样例不能冒称新信用卡用例已经验证。
5. **日记/备注**：`E2E note content`，打开详情确认第二行正文 `恢复校验正文`，只看到列表摘要不算。
6. **额外文档**：源/恢复均有非空加密文档和相同实体 revision/恢复元数据；独立于备注，手机未展示文档正文时必须明确这一界限。

生产选择器已补齐：文件 `file-item-<id>`、相册 `media-item-<id>`，按精确文件名匹配并要求唯一；从所选项取 id，等待 `media-preview-ready-<id>`。照片 ready 只在原图真实解码帧出现后存在，缩略图/失败占位图不算；关闭按钮 `media-preview-close`。这些选择器需要重新构建并安装 companion，旧安装包不可复用。

录制前通过正常创建/导入准备这些数据。历史 `testSeedVelockNoteOnly` / `testSeedVelockDocumentOnly` 使用 debug fixture 按钮，只能用于隔离回归准备，不可直接塞进公开原片；录制包必须无 fixture 按钮且验证所用数据真实加密落盘。现有 `testProbeVelockFileAndImageImport` 可以导入真实文件/照片，不能仅因 picker 成功就算持久化成功。相册从系统 Photos 导入时必须明确选择对应合成图片，不能误选恢复卡。

全内容录制顺序为：源设备依次打开上述五类 → 正常配置并上传；新设备恢复下载 → 先文件/相册，再普通账号/信用卡/备注。每段生成 `source-ui-coverage.json` / `replica-ui-coverage.json`，缺任一项拒绝通过。host 额外执行六类持久化与源副本比较；密文重写的凭证/文档不错误要求密文 hash 相同，解密可读性仍靠 UI，不将元数据比较冒充明文比较。

速度通过录前准备、单次定位、状态等待保证；**不得为了视频短而删去文件/相册或其他类型**。历史55/79秒不再是全内容教程时长标准。


## 新会话先读这里

目标：首次配置同步 + 另一台设备恢复，各中文/英文一份，真实 UI、真实加密传输，连续原片。不要从旧聊天重新探索。

- 录制入口：`tool/ios_ui_test/tutorial/record.py`；配置模板同目录 `config.example.json`。
- UI 步骤唯一实现：`ui_test_harness/CrossAppUITests/CrossAppUITests.swift` 中 `testTutorialSourceFlow` / `testTutorialReplicaFlow` 和 `tutorial*` helpers。不要另写坐标脚本复制整套流程。
- 基础运行器：`tool/ios_ui_test/run_cross_app_ui_test.sh`。教程适配器保留它的身份、远端与业务验证；替换点不匹配立即失败，需要审查运行器变化，不能删断言硬跑。
- 公共手册：`docs/格间同步使用手册.md`、`docs/Velock-Sync-User-Guide.en.md`。
- 历史证据：`docs/verification/2026-09-19-tutorial-retakes.md`，以其“最终交付”为准。
- 已接受版本：`ui_test_results/tutorial-20260919/delivery-v2/`。根目录旧版两段录像质量失败，禁止重新发布。

路径在本文中均相对仓库根目录；命令先切到仓库。真实产物保存在仓库外，`ui_test_results` 只是入口软链接。

## 1. 配置与录前准备（不进视频）

复制配置模板为 `tool/ios_ui_test/tutorial/zh.local.json`，英文另存 `en.local.json`。本机配置已忽略 Git；新机器必须核对并更新。当前已保存 zh/en 两份本机配置，指向本次成功源卡与远端，默认仅重录恢复段、保留源设备、擦除专用 replica；若要重录完整两段，明确设置 replica_only=false，并按实际源设备状态调整 prepared/keep_source。配置里的绝对路径仅属于本机配置，不写死到脚本。

必须提供：两个不同的**专用可丢弃模拟器**及明确的 `disposable_devices` 白名单、两个已构建的 simulator `.app`、companion 源码目录、外部产物目录、演示秘密文件和本地端口。秘密文件 chmod 600，JSON 必含 `VELOCK_RUNTIME_PASSWORD` 字符串，可选 `E2E_RECOVERY_PASSPHRASE`（基础运行器使用；已有恢复卡须匹配原流程凭据）；不要输出或提交内容。这里不读取用户 NAS 凭据。

**破坏性操作提醒：** 全内容模式强制 keep_source=true 保留已准备源设备；keep_replica=false 会擦除白名单内恢复模拟器，确认它可丢弃后才执行。`--check` 不启动、不擦除、不录制。脚本不会操作真实手机。

- 应用构建须禁用 E2E 专用按钮：Xcode 构建 extraArgs `DART_DEFINES=`；使用生产界面，关闭 Debug banner，不修改认证机制。
- 源设备准备真实演示账号和 `E2E Password`，保存完成后验证内容可读及加密文件存在，不能只看列表标题/DB行数。
- 准备阶段设置两 App 的真实语言，并预热照片选择器首用引导；英文还设置系统语言。不能用字幕伪造英文 UI。
- `prepared=true` 仅限源设备确实完成上述准备，必须同时 `keep_source=true`。
- `use_installed=true` 仅限已安装包与待用构建一致，且两个 keep 都为 true。修改/重建应用后不得继续复用旧安装。
- `replica_only=true` 必须 keep_source，并显式提供 `recovery_card` 和 `remote_root`，两者必须来自同一成功源设备；恢复卡必须是启用同步后的卡。不要猜“最近一个”文件。
- 恢复设备须无已有账号。保留 OS 的情况下，先在**指定可丢弃 replica**卸载两 App，再正常安装；不要保留旧账号绕过恢复。

```bash
python3 tool/ios_ui_test/tutorial/record.py --config tool/ios_ui_test/tutorial/zh.local.json --take zh-next-01 --check
# 审核配置、包的新鲜度、专用设备后，去掉 --check 执行：
python3 tool/ios_ui_test/tutorial/record.py --config tool/ios_ui_test/tutorial/zh.local.json --take zh-next-01
```

每次必须用全新 take 名；已有目录会拒绝，避免旧握手文件污染。UI 和模拟器启动/安装/重置**串行**；英文在中文完成后执行。只并行只读 QA、代码审查与纯逻辑测试。曾并行冷启动导致主机极高负载，反而更慢。

## 2. 录制机制与流程

脚本 APFS 克隆每次独立应用副本，避免签名污染公共构建；使用独立 harness DerivedData。本地演示 WebDAV 仅监听 127.0.0.1，不暴露到局域网。

XCTest 写 `start-段名` → 主机启动 `xcrun simctl io UDID recordVideo --codec=h264` → 确认日志 `Recording started` 才写 `recording-段名` → 测试完成写 `stop-段名` → 主机 SIGINT 自己的录制进程并等 MP4 完成 → 写 `stopped-段名` → XCTest 才允许 teardown。因此不应录入测试结束后的桌面。

本机 SimulatorKit/AXe recorder 不可用时已经验证原生 simctl 可用，不要再探索 QuickTime、镜像、摄像头。脚本超时会终止自己的 runner 进程组；录制完成不等于批准发布，仍须以下验收。脚本不承诺自动关闭所有模拟器，结束后只关闭本次专用设备，不碰其他测试设备。

### 首次配置

打开 Velock → 解锁 → 设置/实验性数据同步 → 开启配对 → 切 Sync 配对 → 返回 Velock 精确批准 → Sync 确认创建、配置 WebDAV → 实际上传 → 刷新配置摘要 → 以“刚刚/Just now · 已保护/Protected”结束。

### 新设备恢复

真实恢复卡照片 → 正确密码一次提交恢复原账户 → 启用同步、配对/批准新设备 → 连接同一演示远端 → 下载 → 返回 Velock 解锁导入 → 回凭证列表 → 打开 `E2E Password`，显示 `e2e-user`，密码保持掩码。

## 3. 已定位的坑：按原因处理，不整段盲重录

| 症状 | 已知原因 / 正确处理 |
|---|---|
| 密码为空、重复提交 | 不可用泛化的 Password 文本定位，可能命中标题。优先 secureTextFields / textFields；获取焦点后 Flutter 会切换字段类型，勿使用旧 AX 节点。清空残留，app.typeText，一次提交，等待解锁门消失；实体键盘无需等待软键盘。 |
| 开关点了没反应 | Flutter 合并了整段说明和 switch，节点中心不是按钮。已验证专用 iPhone 17 Pro Max 440×956 pt 使用归一化 (.855,.1935)，helper 有尺寸断言。换设备先探针，不可盲复用坐标。 |
| 等不到批准弹窗 | 背景也有 Velock Sync 文案。等待精确“批准这台 Velock Sync？”/“Approve this Velock Sync?”，批准后等弹窗消失，再切 App。 |
| 返回进入空间设置 | 可见 Setting 与 AX Back 不同；每次只点一次 Back/返回并等待凭证入口，再判断是否需要继续返回。不可双击左上角。 |
| 突然出现其他设备审批 | 失败 takes 留下旧 join-requests。只在隔离演示远端归档已确认失败设备的请求；保留原加密备份。必要时重装 replica 两 App 清缓存。不得删真实请求、自动批准未知设备。 |
| 有标题但详情空 | 旧数据准备超时中断，只有元数据没有加密文件。只重建可丢弃演示记录；等待实际保存完成。生产修复已增加事务保护，不靠伪造 DB 来演示。 |
| PathNotFoundException / 操作失败 | 曾是 descriptor.json.tmp 并发 rename 冲突；companion 已改每次独立暂存目录后原子替换。检查是否安装了修复后的包，不要归咎密码。 |
| 上传完成但显示尚未备份 | 刷新同步配置并等待旧摘要消失，不以旧状态结束。 |

诊断入口：`testTutorialUnlockFirstAttempt`、`testTutorialPairingSwitchProbe`、`testTutorialNavigationProbe`、`testTutorialPreparedSource`。需要显式 E2E_TUTORIAL_DIR；默认常规回归会跳过这些探针。先跑最小失败步骤，修正后再录整段；失败原片留作诊断，不剪掉错误冒充成功。

## 4. 发布验收（必做，不以 XCTest 通过代替）

```bash
bash tool/ios_ui_test/tutorial/run_qc.sh /absolute/take/01-first-setup.mp4 /absolute/new-qa-directory 0.2 6
# 可选：抽取六张关键帧，只读输入；图片包含演示恢复卡等，留在私有产物目录。
swift tool/ios_ui_test/tutorial/inspect_video.swift /absolute/take/01-first-setup.mp4 /absolute/private-frames
```

QC 使用 AVFoundation + Vision，无 ffmpeg 依赖。每 0.2 秒检查整段、前后 SHA-256 不变；只保存固定文案标签，避免原始 OCR 泄露。

- 返回 0：无自动告警，**仍需人眼检查**语言、头尾、画面与业务结果。
- 返回 3：命中错误提示，拒绝交付；返回 2：分析不完整，不得通过。
- 返回 4：长停留，查看对应时间窗口。标签相同不一定冻结，确认是否可见加载/正常处理，并记录决定；不可直接忽略。
- 源段须真实加密批次存在，结束“已保护”。恢复段须同 vault、不同 device、六类源 revision 与业务元数据一致，文件/相册实际密文字节大小与 hash 一致；UI 须分别打开 TXT 正文、原图、普通账号、信用卡、日记正文。仅 password=1 或 e2e-user 可读不再满足验收。
- 检查没有密码错误/空密码、操作失败、Debug/E2E 按钮、测试桌面、意外弹窗。长等待先优化真实步骤，禁止变速/拼接/剪辑掩盖。
- 发布目录只复制通过验收的 4 段 MP4 + 中英文手册 + README/校验和；复制前后 hash 一致。不得打包秘密、单独恢复卡、私有日志和失败 takes。
- 演示 localhost/HTTP 不可作为公网配置教程；公开手册注明真实环境 HTTPS 和实际服务器地址。

旧版仅账号演示基线（不满足新版完整覆盖）：中文约55/79秒，英文约55/78秒，1320×2868 H.264。它们是参考而非硬编码成功标准；中文恢复9.8–16秒停留已人工确认正常过渡/加载，不宣称零等待。

## 5. 快速维护验证

```bash
python3 -m unittest discover -s tool/ios_ui_test/tutorial -p 'test_*.py' -v
bash -n tool/ios_ui_test/tutorial/run_qc.sh
```

2026-09-19 持久化时：录制器从成功脚本提取并参数化，增加配置检查、全新 take 约束、替换锚点检查、退出清理与缺失录像拒绝；离线测试/QA 自测通过。**参数化后的入口未重新做完整 UI 录制**，不应将历史成功原片算作新入口端到端验证。下次先 --check，再跑真实录制与全部门禁。

### 全内容准备与故障隔离（2026-09-19 补充）

- `tool/ios_ui_test/tutorial/probe.py --config <private-config> --test <allowlisted-test> --take <fresh-name>` 只在源演示设备执行一个镜头外探针，默认不擦除；`--use-installed` 显式复用已安装生产构建。每次独立 harness 目录，避免陈旧 XCTest 二进制。
- TXT 准备用 `testTutorialImportText`：限定原生 `Browse View (Picker)` 容器 → CrossAppUITestHost → VelockSync-E2E-Source → 精确 txt cell → Open，最后必须出现生产 `file-item-*` 行。禁止从整个 AX 树按 proof 名称取首个匹配。
- 图片导入可能被 iOS Photos 重命名；私有配置 `photo_name` 记录实际导入名称。验证仍按目标 id 等待 `media-preview-ready-*`，不允许仅凭缩略图成功。
- 可单独执行 File/Photo/CredentialContentProbe，最后必须执行 NavigationProbe 全路径。QuickLook 首次“关于网络权限的说明”/“About network permission”点击“知道了”/“Got it”后，仍须等真实 TXT 正文。
- 准备专用 fixture app 与 production app 必须分开保存；正式配置只能指向无 fixture define 的生产副本，不要引用已被下一次构建覆盖的缓存 Runner.app。
- 首次配置重录前只清空专用源模拟器的 Sync app 私有配置，保留 Velock 内容。录制测试会在镜头外停用新的配对入口（产品 API 保留数据与密钥），镜头内重新启用并保存恢复卡。不得清空真实设备或真实 NAS。

### 硬性前置：准备源不能带着旧发布历史接空远端

2026-09-19 `zh-full-01` 源UI成功但远端覆盖失败：源已发布1–5、7，新远端仅收到6。Velock进度checkpoint不含业务数据，不能恢复这些缺失内容。录制器现在在设备操作之前拒绝该组合（`verify_recording_history`）。切勿通过删DB、降低remote gate或把进度checkpoint当快照绕过。需从真正未同步的完整演示源开始；复制生产app、卸载Sync私有配置都不会重置Velock发布历史。产品新远端完整重传问题须另行修复/验证，当前不得称已解决。

## 2026-09-20：全内容首配录像的补充规则

- 先用真正从未发布过批次的隔离源设备执行 `prepare_source.py` 的 `initialize/document/text/photo` 四个阶段（fixture build，仅画外准备）。随后覆盖安装 production build，运行 `testTutorialNavigationProbe`，必须五类内容全部打开；`prepare_source.py --phase verify` 与 `record.py --check` 必须通过六类持久化及历史门禁。
- 新模拟器的文件选择器默认在「最近项目」，脚本须点击系统「浏览」后进入本机 fixture host；不能依赖旧设备记忆的目录。文件添加按钮使用精确按钮匹配，不能用包含「添加」的任意节点（会误点空文件页说明）。
- Photos 会重命名导入图。只读查询源设备 `t_file` 中 `category_id=2` 的实际 `display_name`，写入私有配置的 `photo_name`，仍必须唯一命中并验证原图 decoded-ready。
- 中文系统偏好须在新模拟器首次启动前设置；英文样例可先用中文完成画外造数，再用真实语言设置切换 English。不要在已经准备好的设备上盲目执行 erase。
- 恢复下载后的 dashboard 会写入凭证。凭证事务临时文件必须使用独立 `credential_io_temp` 与每操作独占目录，不能复用会被预览清理/解锁扫描删除的 `decrypt_dir`。原生回读校验和失败回滚不可删；操作 finally 清理、启动时清理崩溃残留。
- 从 Sync 返回时可能仍处于叠加的数据同步设置路由；仅在该路由确实存在时逐层返回，限定导航栏返回按钮，不得误点其他设备的批准按钮。
- `record.py` 现在在源上传通过 host 校验后、第一次恢复前，自动保存私有 `pristine-remote` 和 `pristine-recovery-card.png`。恢复段重录要把完整 pristine remote 克隆到新的私有目录供本次运行使用，设置 `replica_only=true`、保留源设备及对应恢复卡，只重置明确 disposable 的恢复设备。不要直接服务 pristine 副本使其再被实验请求污染，也不要清除源历史。
- 旧失败恢复设备留下的加入申请会触发产品真实审批弹窗。应使用上述完整 pristine 备份进行隔离重录，而不是在视频里批准未知请求、拼接视频或降低内容门禁。
- accepted 必须同时具备五类 UI coverage、六类 host persistence/convergence、文件/图片字节校验，以及原片 QC/视觉复核；仅 MP4 文件存在不算成功。整段失败原片只作私有诊断，不交付。
- 英文系统 QuickLook 关闭按钮实际 label 为小写 `close`，优先用 `QLOverlayDoneButtonAccessibilityIdentifier`，不要只匹配 `Close`/`Done`。源设备仅改 App 语言的探针不等于英文系统新设备探针。
- 原生恢复表单已出现后，clean tutorial 对可选且不存在的生物识别开关只查当前存在性，不消耗3秒缺席超时。保留真正恢复提交、解锁和正文的等待断言。

### 最后验收基线（2026-09-20）

- 正式交付基线：源 `zh-recording-01` / `en-recording-01`；恢复 `zh-native-fixed-01` / `en-native-fixed-01`。恢复必须使用 `production-native-header-fix.app` 或含相同修复的新正式构建，不得退回只含credential IO隔离的旧库。
- 原生库修复/432次roundtrip/17边界与重建流程见 `/Users/parcool/CLionProjects/crypto_new/tests/README.md`；App中实际framework UUID须与构建产物对应。随机padding<12会触发旧版12字节header偏移损坏，不能把单次成功或多次重试当修好。
- 对外四文件映射和原始SHA256审计在私有产物 `delivery-original-byte-audit.json`。交付只含MP4、手册、说明和校验清单，不复制恢复卡图、配置JSON、日志或失败take。视频内演示口令/恢复卡仅允许完全隔离的虚构空间。

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
