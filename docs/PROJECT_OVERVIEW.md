# Velock Sync 项目详细描述（含问题与改进方向）

- 编写日期：2026-09-19
- 代码基线：`1935715`（工作区有未提交改动，见第 7 节）
- 文档版本：1.0
- 关联文档：[PRD.md](./PRD.md) · [TECHNICAL_SPEC.md](./TECHNICAL_SPEC.md) · [SYNC_PROTOCOL_V1.md](./SYNC_PROTOCOL_V1.md) · [V1_COMPLETION_SPEC.md](./V1_COMPLETION_SPEC.md) · [IMPLEMENTATION_STATUS.md](./IMPLEMENTATION_STATUS.md) · [PROVIDER_ADMISSION.md](./PROVIDER_ADMISSION.md) · [OAUTH_SETUP.md](./OAUTH_SETUP.md) · [ANDROID_VELOCK_EXCHANGE.md](./ANDROID_VELOCK_EXCHANGE.md)

---

## 1. 项目概览

**Velock Sync**（`tech.windata.velock`）是一个开源、跨平台的**增量同步引擎与客户端**，由重庆 Windata 科技公司维护，Apache-2.0 许可。它承担两类职责，产品首页因此分为两个区域「格间备份 / 文件夹同步」：

1. **格间数据零知识远程备份（`velock-managed`）**：Sync 只搬运 Velock（格间，姊妹仓库 `velock_codex`）已经加密、签名的不透明 Exchange artifacts。它不读取格间数据库、不持有主密钥/同步密钥、不解释业务 payload；内容恢复、删除恢复、业务冲突全部由格间本体负责。产品定位是「持续备份 + 灾难恢复」，换机/重装只是恢复场景之一，不是产品主叙事。
2. **通用双向文件夹同步（`selected-folder`）**：用户选择本地文件夹 + 一个远端 Provider，形成独立的 **Generic Vault** 加密同步空间（独立 root key、设备签名身份、PBKDF2 口令保护的恢复材料），按主流同步盘的心智提供增量双向同步、断点恢复、tombstone、删除保护与三种冲突策略（keepLocal / keepRemote / keepBoth）。

关键产品约束（PRD 核心原则）：

- 格间数据**始终零知识**，远端对象一律 fail closed；
- **备份优先于换机**：文案、状态、空状态都从持续备份角度表达；
- **远端不是临时中转站**：对象不可变、commit 前不可见、GC 必须满足保留期（业务 30 天 + 远端安全缓冲 7 天）+ Retention Manifest + checkpoint + 活跃设备 ACK + 引用检查；
- **通用同步默认非破坏性**：首次同步不静默覆盖、大规模删除需确认、冲突不静默丢失、重试幂等；
- **一个同步引擎、多类数据集**：前台/后台/手动/预约任务全部走同一个 `SyncProfileDispatcher`，新增数据集不复制主流程。

### 代码规模（2026-09-19 统计）

| 维度 | 数值 |
| --- | --- |
| `lib/` Dart 源文件 | 171 个，约 38,040 行（不含 generated） |
| 测试文件 | 102 个，约 16,977 行 |
| Git 追踪文件总数 | 938 |
| 最大源文件 | `sync_profile_workspace.dart` 3,973 行、`sync_state_database.dart` 2,431 行 |
| 文档 | `docs/` 9 份规格 + 3 份验证记录；根目录 18 语言 README |
| 测试向量 | `test_vectors/protocol_v1`（valid/replay/corrupted/invalid-auth/path-traversal/unsupported-version）、`test_vectors/velock_exchange_v1` 接口契约 JSON |

## 2. 平台与发布形态

- **iOS/iPadOS**：主平台。App Group `group.tech.windata.velock.sync.exchange` 与格间交换 artifacts；document picker + security-scoped bookmark 支撑文件夹同步；BGTaskScheduler 后台调度；App Store Connect 发布（`tool/release/verify_app_store_release.sh` 同时归档 Sync 与 Codex 两个 App 并做 codesign 校验）。
- **Android**：次平台。SAF（document tree URI）目录授权；与格间通过 **ContentProvider 信任边界**交换——要求 signature 级权限 `tech.windata.velock.permission.SYNC_EXCHANGE`，且 Release 构建必须注入 `VELOCK_EXCHANGE_AUTHORITY` / `VELOCK_COMPANION_PACKAGE` / `VELOCK_COMPANION_CERT_SHA256` 三个非秘密标识，IPC 前校验包名与签名证书；WorkManager 后台调度。
- **桌面（macOS/Windows/Linux）与 Web**：仅保留脚手架用于开发/测试（文档明确「桌面：planned」），不是发布目标。
- **依赖版本**：Dart SDK `^3.8.1`，app 版本 `1.0.0+1`（未随 2.x 产品目标更新）。
- **多语言**：README 18 个语言版本互相链接；App 内 i18n 依赖 `flutter_localizations`。

## 3. 总体架构

```text
Flutter UI（features：dashboard / connection / activity / selected_folder / sync_profiles）
  -> Application / Profile lifecycle（providers，Riverpod 3 + hooks）
    -> SyncProfileDispatcher（唯一入口，注册 SelectedFolderExecutor + VelockSyncProfileExecutor）
      -> VelockSyncService -> Velock Exchange Adapter（App Group / ContentProvider）
      -> SelectedFolderSyncService -> SelectedFolder Dataset Adapter
    -> Shared Sync Core（sync_core：engine / crypto / conflicts / model / contracts）
      -> RemoteObjectStore（契约）
        -> WebDAV / Google Drive / OneDrive（infrastructure + providers）
    -> SyncStateDatabase（SQLite，lib/infrastructure/database）
    -> 平台安全存储（rootKeyRef / signingKeyRef / credentialRef，flutter_secure_storage）
    -> Background（workmanager / BGTask -> 同一 Dispatcher）
```

### 3.1 模块地图（`lib/`）

| 目录 | 职责 |
| --- | --- |
| `sync_core/engine` | 传输核心：`sync_upload_engine`、`sync_download_engine`、`sync_profile_runner`、checkpoint 发布/恢复、`sync_garbage_collector`、`remote_retention_manifest_service`、设备成员/移除/加入审批（membership、join approval、removal）、`generic_vault_batch_compiler` |
| `sync_core/crypto` | Generic Vault：root key 派生、operations/blob 加解密与 codec、acknowledgement、**vault_recovery_package**（PBKDF2 包裹的恢复材料） |
| `sync_core/conflicts` | 冲突解决服务与三策略（耐久 intent 先行，可审计） |
| `sync_core/contracts` | 两个核心抽象：`RemoteObjectStore`（Provider 契约）、`SyncDatasetAdapter`（数据集契约） |
| `sync_core/model` | 协议模型：envelope、ack、failure、retention manifest、GC candidate manifest |
| `dataset_adapters/velock_exchange` | 格间对接：交换存储与队列探测、配对控制面（pairing control plane）、冲突网关、发现/探针、iOS App Group 根与 Android 通道 |
| `dataset_adapters/selected_folder` | 文件夹同步 14 个模块：授权（SAF / security-scoped bookmark）、存储适配、扫描器、变化计划、批次准备、入站应用、冲突解决、profile 供给器、同步服务与执行器 |
| `providers/` | WebDAV（`webdav_client_plus`）、Google Drive（PKCE 公共客户端 + `drive.file`）、OneDrive（PKCE + `Files.ReadWrite`）、**百度网盘/阿里云盘（暂缓，仅凭据预配置页）**、OAuth 公共层（系统浏览器 + PKCE，重授权原子替换 credentialRef） |
| `sync_profiles/` | Profile 仓储/模型/设置/向导（格间配对向导）/执行契约/诊断 |
| `infrastructure/` | SQLite 状态库、secure storage 各 key store、staging、storage |
| `background/` | 前台协调器 + 后台调度（统一进 Dispatcher） |
| `features/` | 五大功能区的 UI 与各自 model/repository/state |
| `appearance/`、`widgets/` | 设计 token、主题、自适应组件库 |
| `core/` | 路由（go_router）、仓库门面、日志、JSON 解析、本地数据管理 |

### 3.2 同步协议要点（Protocol V1）

- 不可变对象：envelope、`operations.enc`、opaque blob、commit marker、receipt/ack、checkpoint；以 `vaultId + sourceDeviceId + sequence + batchId` 标识；**相同逻辑键只能重放完全相同内容，内容冲突必须拒绝**。
- Sync 只验证外层完整性（长度、SHA-256、envelope schema/版本、生产者身份、sequence 与前序引用、格间签名与可信 receipt）；`operations.enc` 与 blob 内部格式归 `velock_codex`。
- 入站：下载并校验后原样发布到 Exchange inbox，**只有格间返回可信 receipt 才推进 applied cursor**。
- 安全失败（fail closed）：未知生产者、签名/hash 错误、序列分叉、路径穿越、超限 artifact、错误版本、伪造 receipt。
- 多设备协同：版本向量 + tombstone，并发修改不静默丢失；冲突保留双方版本由用户三选一。

### 3.3 安全模型

- 零知识边界：格间数据在 Sync 内全程是「不可信字节」；通用数据在远端只有 Generic Vault 加密对象。
- 密钥只存在于平台安全存储，Envelope 只保存不透明 `*Ref`；有 secret 字段名校验防止明文入库；日志/诊断禁止出现凭据、密钥、恢复口令、原始路径、业务明文（CI 有 `verify_no_secrets.dart` 与 `check_dependency_licenses.dart` 两道检查）。
- OAuth 全走系统浏览器 + PKCE 公共客户端，客户端不内置任何 secret；redirect URI 固定 `velocksync://oauth/callback`；删除 OAuth 连接先请求远端吊销，失败则本地恢复连接。
- 国产网盘（百度/阿里）因官方 code/refresh 都要求 `client_secret`，**明确暂缓**，必须先有独立、最小权限、可审计的 Token Broker（`PROVIDER_ADMISSION.md` 给出准入三前提），当前入口只是凭据预配置页，不创建连接。
- Android 跨 App 交换是签名级信任边界：包名 + 证书 SHA-256 双重校验，未配置即禁用集成。

## 4. 测试与工程体系

### 4.1 分层测试

- **单元/组件测试**：102 个 `*_test.dart`（~17k 行），覆盖 sync_core 全引擎（上传/下载/checkpoint 恢复/GC/retention/成员/加入审批/版本向量/失败归一化）、协议 crypto（测试向量往返）、两类数据集适配器、三个 Provider 的公共契约测试（`test/providers/contracts`）、Profile 仓储/Dispatcher 路由、UI 定位与分组。
- **跨仓库契约**：`test/dataset_adapters/contracts/velock_exchange_cross_repo_contract_test.dart` + `tool/verify_cross_repo_exchange_contract.dart` 对照 `velock_codex` 校验 Exchange 接口契约；Android 侧有 `ProtocolV1VectorsTest.kt` 消费同一 `test_vectors`。
- **模拟器 XCUITest（跨 App 双机）**：`ui_test_harness/`（HostApp + CrossAppUITests）+ `tool/ios_ui_test/run_cross_app_ui_test.sh`：两台 iOS 模拟器 + 常驻 WsgiDAV（`tool/local_webdav/`，端口 8888，凭据 `velock/velock123`，数据根在 `ui_test_results/persistent-webdav-root` 软链目录外），跑「格间笔记保存→备份→第二设备恢复→业务持久化校验」以及「selected-folder 双模拟器：授权→首传加密→恢复包导出→二机导入→下载内容哈希校验」全流程。
- **验证证据**：`docs/verification/` 三份日期化验证记录；`ui_audit/` 35+ 张 UI 走查截图（current/redesign/repositioning/recheck 四轮）。
- **CI（GitHub Actions `quality.yml`）**：安全（license + secrets 扫描）→ Flutter（`dart format` 检查、`flutter analyze`、`custom_lint`、`flutter test`、`git diff --check`）→ Android `assembleDebug`。**注意：无 iOS job、无 XCUITest job、无覆盖率度量**。

### 4.2 工程约定（AGENTS.md 沉淀的经验）

- 大型可再生产物（`ui_test_results`、DerivedData）放项目外，项目内保留同名软链接以兼容脚本路径；避免 Flutter 3.47 iOS Debug 构建的 `xattr -r -d com.apple.provenance` 递归进大目录导致启动慢。
- iOS 真机验证走 XcodeBuildMCP（设备「谭毅的iPhone」，`tech.windata.velock`），手动点桌面图标验证必须 Release；UI 测试按「widget test < XCUITest < Computer Use」成本决策树选择，动画/异步界面必须谓词等待、禁止裸 sleep。
- NAS WebDAV 联调凭据只存在于 `tool/local_webdav/nas_webdav.local.env`（gitignore），禁止进入受控文件。

## 5. 文档体系

| 文档 | 内容 | 状态 |
| --- | --- | --- |
| `PRD.md`（v2.0） | 产品边界、两类数据集、场景 A–E、功能范围、信息架构、状态与文案规则 | 已确认，进入实施 |
| `TECHNICAL_SPEC.md`（v2.0） | 架构、Dispatcher 契约、格间/文件夹两大数据集规格、安全要求、错误分类、测试规格、P0–P4 实施阶段与回滚策略 | 已确认，进入实施 |
| `SYNC_PROTOCOL_V1.md` | 不可变对象、完整性、入站提交、fail closed 条件 | 协议基线 |
| `V1_COMPLETION_SPEC.md` | V1 完成定义（公共/格间/文件夹三组硬性要求 + 发布检查清单） | 验收基线 |
| `PROVIDER_ADMISSION.md` | 各 Provider 准入状态与 Token Broker 前提 | 现行 |
| `OAUTH_SETUP.md` | PKCE 公共客户端配置、redirect URI、scope、重授权/吊销 | 现行 |
| `ANDROID_VELOCK_EXCHANGE.md` | Android 跨 App 信任边界与 provider 操作契约 | 现行 |
| `UI_REDESIGN_SPEC.md` | 证据驱动的 UI 问题审计（P0/P1 清单）与统一设计原则 | **待实施基线**（工作区有未提交修改） |
| `IMPLEMENTATION_STATUS.md` | 2026-09-12 实现状态与剩余工作 | 需滚动更新 |
| `README*`（18 语言） | 对外描述、开源声明、商业说明、App Store 入口 | 已随 `66b184b/45bc77d` 重写 |

文档质量总体较高：规格用 MUST/SHOULD/MAY 分级、发布检查清单化、回滚路径明确、Provider 准入有外部文档依据。主要短板见 7.3。

## 6. 当前实现状态（截至 2026-09-12 状态文档 + 工作区）

**已完成**：两类数据集与共享传输核心全部就位；selected-folder 全链路（授权/扫描/批次/加密/冲突/执行器）已恢复并接入 Dispatcher 前台+后台；Generic Vault crypto 与恢复包、三 Provider、删除保护与 GC、checkpoint 恢复、双模拟器 XCUITest、跨仓库契约测试；UI 已完成「备份与同步」双区域重构与一轮设计审计。

**剩余工作（IMPLEMENTATION_STATUS.md）**：iOS 真机 App Group entitlement + 签名构建 + 格间互操作验证；selected-folder 真机 Document Picker/SAF、后台限制与真实 Provider 长流程；Provider 账号端到端恢复演练 + 故障注入 + 发布证据；发布前 UI 截图回归、动态字体、深色模式验收。

## 7. 问题清单

### 7.1 代码与架构

1. **巨型文件与职责过载**：`sync_profile_workspace.dart` 3,973 行（一个 UI 文件承载多类 Profile 详情的全部逻辑）、`sync_state_database.dart` 2,431 行（所有表/查询/迁移集中）、`adaptive_widgets.dart`/`adaptive_dialogs.dart` 合计 2,000+ 行。缺乏按页面/组件的拆分，改动半径大、review 困难。
2. **数据库层是单文件上帝对象**：2,431 行单文件管理十余张表，没有 repository/DAO 分层；`SyncProfileRepository` 之上还有 `core/app_repository.dart` 门面，职责边界需要梳理。
3. **遗留死代码**：`lib/sync/http.dart` 是早期遗留（早期 commit「create a download manager but not used」的痕迹），`core/local_data_manager.dart` 等门面与 features 内 repository 存在职能重叠；`lib/generated` 依赖 build_runner，但无生成物过期检查。
4. **未统一的小模块**：`sync_profiles/diagnostics/` 在工作区尚未提交；`features/dashboard/model` 是空目录；`features/sync_profiles/ui` 只有目录（实际实现在 `sync_profile_workspace.dart`）——目录结构与真实代码分布不一致，新人定位成本高。
5. **协议演进风险**：envelope schema 只有「版本拒绝」能力，没有前向兼容策略说明（未知版本 fail closed 是对的，但未来加字段/加 Provider 时的协商机制缺文档）。

### 7.2 平台与发布

6. **Android 格间集成交付不完整**：Companion（velock_codex）侧签名 provider 尚未发布，`VELOCK_EXCHANGE_AUTHORITY` 等三个标识未定，Android 真机互操作从未完成（状态文档列为剩余工作）。
7. **桌面/Web 是纯脚手架**：目录存在但无适配承诺，容易误导贡献者投入；建议明确标记或移出默认构建。
8. **版本号与产品目标脱节**：pubspec 仍 `1.0.0+1`，PRD 目标 2.x，App Store 版本管理没有自动化。
9. **CI 不对称**：只有 Android 构建 job；iOS 构建（entitlement、签名、后台任务配置）完全依赖本机脚本，`verify_app_store_release.sh` 还**硬编码了绝对路径（`/Users/parcool/...`）和 Team ID**，换机器即失效，且 Team ID 进版本控制不妥。
10. **本地 WebDAV 凭据默认值**：`start_local_webdav.sh` 默认 `velock/velock123`，虽然只是假服务，但默认弱口令写进脚本，容易被误用于真实联调环境。
11. **仓库卫生**：`.DS_Store` 被 Git 追踪（虽有 gitignore 规则但文件已入库）；`build/`、`custom_lint.log`（8.8MB）等产物在本地目录中未被 gitignore 规则完全覆盖（`*.log` 已覆盖 custom_lint.log 但 `build/` 目录存在且未被追踪——确认无碍，但 `ui_test_results` 软链指向项目外，CI 全新 checkout 时本地工具需自行重建 WsgiDAV 环境）。

### 7.3 工程与流程

12. **`pubspec.lock` 被 `*.lock` 规则忽略而未入库**：Flutter **应用**应提交 lock 文件保证依赖可复现，当前 CI 每次 `pub get` 都可能漂移（lock 被忽略 + 依赖多为 `^` 宽区间）。
13. **工作区长期脏**：`git status` 显示 13 个已修改 + 5 个未跟踪文件（含新增 `diagnostics/`、`queue_probe`），说明「功能完成—提交」节奏松散；未提交内容包含行为变更（启动扫描削减、队列探测），存在回滚困难。
14. **测试短板**：无覆盖率门槛/报告；`flutter test` 只跑 Dart 层；XCUITest 依赖本地 XcodeBuildMCP + 固定模拟器 UDID（`26CC5821...`/`22842F80...`），无法在 CI 无人值守运行；Provider 只有契约测试，**真实账号端到端与故障注入**（限速、断网、401、路径冲突、超大文件）只停留在人工验证与验证记录。
15. **UI 重构未落地**：`UI_REDESIGN_SPEC.md` 记录了 P0 级问题（页面无标题、状态栏重叠、语义色冲突、UUID/异常类名泄露到文案、重复操作、死胡同空状态、maxLines 硬截断），但状态仍是「待实施」；这些直接伤害产品可信度（一个安全类 App 把 `OAuthClientRegistrationMissingException` 展示给用户）。
16. **可观测性弱**：`sync_profiles/diagnostics` 刚起步；没有崩溃上报/指标管道，「最近失败原因」依赖本地 SQLite 记录，跨设备排障困难。
17. **多仓库协同成本**：协议与契约横跨 `velock_sync`/`velock_codex` 两仓，目前靠契约 JSON + 跨仓验证脚本 + 文档约定维持，没有 lockstep 发布或 CHANGELOG 同步机制。

### 7.4 产品与范围

18. **能力缺口**：照片库同步、多文件夹归一 vault、Provider 内密文空间浏览、历史版本、完整桌面端都在「后续范围」，V1 价值集中在备份正确性而非可用性体验。
19. **Provider 覆盖面受限**：国产网盘（百度/阿里）被 Token Broker 前置条件卡住，而这是中文用户的重要场景；WebDAV 面向个人 NAS 用户，受众窄。
20. **恢复材料单点**：Generic Vault 恢复材料（口令包裹）一旦丢失即失去整个同步空间，产品侧尚无「多副本/云端托管/社交恢复」等缓解路径的说明。
21. **后台同步的电池/流量策略**：有 WorkManager/BGTask 与网络恢复触发，但蜂窝策略、电池优化豁免、iOS 后台配额耗尽后的用户可见降级，状态文档未给出验证结论。

## 7.5 改进进度（2026-09-19 本轮）

按第 8 节优先级执行后的状态（对应提交见 `git log`）：

**已完成**

- 仓库卫生（#2）：`.DS_Store`/`.idea/`/`*.iml` 移出追踪；`pubspec.lock` 入库（`*.lock` 增加例外）；积压的 18 个文件按「诊断 / UI / XCUITest」逻辑分组提交；`tool/release/verify_app_store_release.sh` 去硬编码（仓库根从脚本位置推导 + `VELOCK_TEAM_ID` 环境变量 + companion 缺失时跳过）。
- UI 泄漏修复（#1 残留项）：selected-folder 管理页行副标题不再渲染原始 `errorCode`/`state`（改用 `AppFormat.errorSummary` + 固定状态标签）；百度网盘/授权流程 toast 与 OAuth 文件夹选择器错误态移除异常类名（细节进日志）；新增 `test/widgets/app_format_test.dart` 固化「错误码 → 用户文案」映射。原审计 P0 #1–#7 此前已在前三轮 UI 审计落地（见 `UI_REDESIGN_SPEC.md` 实施状态）。
- CI（#5 一半）：`flutter test --coverage` 发布 `coverage/lcov.info` 工件（先测基线、暂不设门槛）；新增 macOS runner 的 iOS 模拟器编译 job；`verify_no_secrets.dart` 加固（二进制内容宽容跳过 + 跳过可再生产物目录——此前在本机 DerivedData 上会直接崩溃）。
- 巨型文件拆分（#4 一半）：`sync_state_database.dart` 2,431 行 → 门面 735 行 + 13 个按表域划分的模块（connections/profiles/runs/activity/transfers/locks/batches/folder_scan/conflicts/devices + records/migrations/sql），公共 API 零变化（records 由门面 re-export），`flutter analyze` / `custom_lint` / 435 项测试全绿。

**仍待办**

- UI 复检三项（规格「仍待完成」）：连接详情文件网格正常态（需可用远端）、深色模式/动态字体逐页巡检剩余页面、iPad 与 Material 分支逐页截图。
- 真机/Provider 端到端验证矩阵（#3）：iOS App Group + 格间互操作、Android 签名 provider、selected-folder 真机 SAF/Document Picker、真实 Provider 账号与故障注入——需要设备与账号，无法在仓库内完成。
- `sync_profile_workspace.dart`（3,973 行）拆分：属 UI 层，需配合视觉回归再动。
- 多仓 lockstep（契约 JSON 共享位置、版本协商策略文档化）、可观测性管道、恢复材料冗余方案、版本号治理（pubspec 仍 1.0.0+1）。

## 8. 改进方向

### 8.1 短期（1–2 周，风险/信任类优先）

1. **落地 UI_REDESIGN_SPEC 的 P0 项**：补页面标题、状态栏安全区、语义色修正、UUID/异常类名从主文案清除、重复操作收敛、死胡同加动作。安全产品的「可信感」就是竞争力，且规格已就绪、成本最低。
2. **仓库卫生一次性清理**：`git rm --cached .DS_Store`；把 `pubspec.lock` 从 `*.lock` 排除并入库；提交当前工作区积压的 18 个文件（拆成「UI 定位修复」「队列探测」「诊断」等逻辑 commit）；`custom_lint.log`、`build/` 确认忽略。
3. **发布脚本去硬编码**：`verify_app_store_release.sh` 改为 `xcodebuildmcp`/环境变量驱动（对齐 AGENTS.md 的真机流程），Team ID 从 Xcode 签名或 CI secret 读取；为 iOS 增加一条最小 CI（`xcodebuild build` 编译检查即可，先不解决签名）。
4. **版本号治理**：pubspec 对齐 2.x 目标，建立「PRD 版本 ↔ pubspec ↔ App Store build number」的单一事实来源。

### 8.2 中期（1–2 月，工程与质量）

5. **拆分巨型文件**：`sync_profile_workspace.dart` 按 kind（velock/selected-folder）与区块（overview/history/settings/conflicts）拆为多个 widget + 独立 state；`sync_state_database.dart` 拆为按表域的 DAO（profiles/scans/objects/transfers/conflicts）+ 统一迁移器。拆的时候补 golden/组件测试兜底。
6. **测试补齐**：引入覆盖率（`flutter test --coverage` + lcov 门槛，先设基线再抬升）；Provider 故障注入矩阵（401/429/超时/半写/断网/限速）参数化进契约测试；把双模拟器 XCUITest 脚本改造成可在 CI runner（macOS）无人值守运行的版本（模拟器 UDID 可配置 + 自动 boot）。
7. **可观测性**：完成 `diagnostics` 模块——本地诊断包（脱敏校验 + 一键导出）、关键失败的结构化事件（runId/profileId/errorCode/retryable 已有模型，缺上报与聚合），先做「用户可自助导出」再做任何远端上报（与零知识定位一致）。
8. **协议前向兼容策略文档化**：envelope 版本协商、新增字段默认忽略规则、Provider capability 扩展点（`provider_capability_summary.dart` 已有雏形），写入 `SYNC_PROTOCOL_V1` 附录。
9. **多仓 lockstep**：`test_vectors` + 契约 JSON 抽到共享位置（或发为内部包），两仓 CI 互验；给 Exchange 契约加版本号与弃用流程。

### 8.3 长期（季度级，产品能力）

10. **补齐真机验证矩阵**：iOS App Group + 格间互操作、Android 签名 provider 发布与真机冒烟、selected-folder 真机 SAF/Document Picker 长流程；把结果固化进 `docs/verification/` 并在 README 标注验证状态。
11. **Token Broker 决策**：评估自建 vs 第三方，若决定做百度/阿里云盘，按 `PROVIDER_ADMISSION.md` 三前提立项（最小 scope、审计、吊销、轮换）；否则在 UI 上明确「暂不支持」而非预配置页。
12. **恢复材料冗余方案**：多接收人导出、离线打印卡片、（可选）受控云端托管——这是通用同步产品的核心信任点。
13. **体验补全**：照片库/多文件夹 vault、密文空间内浏览（Provider 侧只读目录树）、历史版本查看、桌面端正式化（或明确不做）。
14. **后台体验**：蜂窝/电池策略可配置、iOS 后台配额耗尽的降级提示、同步流量统计展示。

### 8.4 优先级建议（Top 5）

1. UI P0 修复（用户可见的信任问题，规格现成）；
2. 仓库卫生 + `pubspec.lock` 入库 + 发布脚本去硬编码（低成本高确定性）；
3. 真机/Provider 端到端验证矩阵（当前「已实现」与「已验证」之间的最大缺口）;
4. 巨型文件拆分（可维护性拐点，拖得越久成本越高）；
5. 测试覆盖率基线 + CI 增加 iOS 编译 job（质量地板）。

---

## 附录 A：关键路径速查

- 同步主流程：`lib/sync_profiles/execution/` → `lib/sync_core/engine/sync_profile_runner.dart`
- 上传/下载：`lib/sync_core/engine/sync_upload_engine.dart` / `sync_download_engine.dart`
- GC 与保留：`sync_garbage_collector.dart`、`remote_retention_manifest_service.dart`、`garbage_collection_evidence_builder.dart`
- 格间对接：`lib/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter.dart`（544 行，核心）
- 文件夹同步：`lib/dataset_adapters/selected_folder/selected_folder_dataset_adapter.dart`
- Provider 契约：`lib/sync_core/contracts/remote_object_store.dart`
- 恢复材料：`lib/sync_core/crypto/vault_recovery_package.dart`
- 后台：`lib/background/background_sync.dart` → Dispatcher
- 状态库：`lib/infrastructure/database/sync_state_database.dart`

## 附录 B：目录结构（顶层）

```text
velock_sync/
├── lib/                  # 应用源码（171 个 dart 文件）
├── test/                 # 102 个测试文件
├── test_vectors/         # 协议/交换契约测试向量（跨仓共享）
├── docs/                 # PRD / 技术规格 / 协议 / 验证记录 / UI 审计
├── tool/                 # release、ios_ui_test、local_webdav、CI 辅助脚本
├── ui_test_harness/      # 双模拟器 XCUITest 宿主工程（HostApp + CrossAppUITests）
├── ui_audit/             # UI 走查截图（4 轮）
├── ios/ android/ macos/ windows/ linux/ web/   # 平台工程（iOS/Android 为主）
├── ui_test_results -> ../velock_sync_test_results   # 产物软链（项目外）
└── .github/workflows/quality.yml   # CI：secrets/license → analyze/lint/test → android build
```
