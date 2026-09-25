# 当前内容快照与多文件导入：本轮执行结果

## 真正修复的既有产品问题

`velock_codex/lib/sync/bridge/sync_password_exchange_import_binding.dart` 原先把整个批次blob集合传给每一条文件。真实 `SyncFileUpsertApplier` 严格要求只包含该条记录引用的blob，所以两文件/文件与相册混合批次会抛 `File operation blob references are invalid`。单密码教程无法暴露它。

修复后：

- 文件upsert/resolve-conflict在批次开始前检查缺失/重复附件引用，缺少第二个文件附件时也不留下第一个文件的业务写入。
- 每个文件只获得自己的blob映射，不复制大型二进制数据；共享blob仍可分别供多条记录使用。
- 删除记录中的blob refs表示历史保留对象，不强制重新携带待删除文件；保留墓碑回归测试。
- 签名、hash、payload内blobId一致性、文件journal与版本向量检查没有放宽。

## 验证证据

- 通过真实SQLite FFI、真实文件applier、临时落盘文件验证：不同文件/照片内容分别正确、共享blob、额外无关blob隔离、第二附件缺失零写入、payload引用不匹配拒绝、删除历史引用兼容。
- 为避免触碰工作树，用项目外隔离副本只还原旧的 `blobs: batch.blobs` 行，运行新增“file and photo receive only their own distinct blob”用例，稳定得到原始FormatException。正式代码同用例通过。证据 `ui_test_results/current-snapshot-20260919/red-proof.log`。
- 合并回归35项通过（binding、file upsert、启动文件journal恢复、importer、V1协议、快照排序）。证据 `ui_test_results/current-snapshot-20260919/regression.log`。
- 数据样例为合成字节和凭证保护payload；这是导入业务与落盘回归，不冒称已在另一台模拟器展示真实图片解码。

## 快照恢复顺序基础

新增 `velock_codex/lib/sync/bridge/sync_snapshot_order.dart` 与7项测试：目录父节点先于子节点、标签successor先于旧标签、实体与标签先于关联。缺引用、循环依赖、重复实体和资源超限全部拒绝，不能通过剥离关系“恢复”。

2万层目录链采用非递归拓扑排序，本机观测48ms；这只是元数据排序耗时，不是端到端同步性能。模块尚未接入正式快照恢复入口，不影响原有增量操作顺序。

## 尚未完成

签名全量快照和业务当前状态读取组件已实现并做组合测试（见下节）；实际Native内容回调、流式blob传输、完整恢复后的游标安装、UI入口和双设备验收尚未接通。旧进度checkpoint仍不能充当快照。误报阻断和六类验收门禁保持开启。未安装本轮新的companion构建、未录制新教程视频；不声称自动补传已完成。

设计约束已固化到 `docs/design/velock-current-state-snapshot.md`。下一步必须沿可信Velock生产与验收路径实现，不可直接重置producer/sequence绕过历史缺口。


## 后续执行：真实当前内容源 + 加密快照组件

新增 companion 四个文件：
- `lib/sync/bridge/sync_current_state_source.dart`
- `lib/sync/protocol/sync_current_snapshot.dart`
- 对应 `test/sync/sync_current_state_source_test.dart` 和 `sync_current_snapshot_test.dart`

内容源从真实SQLite业务表与实体映射生成完整当前状态，支持九种协议实体（文件/媒体/目录共用file）、标签和关联；保留UUID/revision/vector，不依赖日志、不更新数据库。凭证正文/文档Delta、加密文件流由可信只读回调提供。未映射、缺内容、跨空间依赖、待处理journal/冲突、采集期间修改均拒绝，文件系统metadata intent要求显式检查回调。

加密协议复用VLP1/AES-GCM，加独立Ed25519 manifest签名及commit hash。元数据分part，文件/照片按blob流式校验，不把大型二进制展开到JSON。所有输入集合在await前固定，字节数组只读；验证后再次消费blob仍检查hash/长度。同ID重试必须复用暂存原始字节（暂存层还未实现）。

### 这轮实际验收

- **174项合并测试全部通过**：新内容源/快照协议、既有多文件binding、file applier、启动journal恢复、importer、V1协议与依赖排序。日志：`ui_test_results/current-snapshot-20260919/combined-components.log`。
- 其中包含真实SQLite内容源 → prepare → open → 六类完整正文/文件字节核对，且样例中有从远端导入、没有本地change_log的实体。账号密码、信用卡字段、日记正文、文档Delta和两份不同file/media字节均断言。
- 协议测试103项，涵盖篡改、错身份/错密钥、漏part/blob、重复实体/操作、资源上限、共享blob去重、来源变更及可变输入竞争。初次一项测试fixture的无padding base64解码错误已修正，最终重跑通过。
- 6个新增/排序生产与测试文件静态分析无问题：`components-analyze.log`。
- 合并测试runner显示约2秒（不等同于含工具启动的墙钟，也不代表WebDAV同步性能）；2万节点排序本次53ms。无大型文件或网络吞吐验收，不能由此宣称满足端到端速度指标。

### 明确边界

这些是生产代码组件和真实SQLite组合测试，文件使用合成加密字节/可信回调；不是实际Native读取、图片解码或双设备UI恢复验收。没有改远端历史门禁，没有安装新模拟器构建，没有重录视频，也没有声称自动全量迁移完成。下一阶段仍须接入稳定heads、持久暂存/传输、恢复完成状态机与UI；现有安全阻断继续保留。

## 再继续：真实读取接口与原始密文持久暂存

本轮新增 companion：
- `lib/sync/bridge/sync_current_state_native_binding.dart` 及对应测试。
- `lib/sync/bridge/sync_current_snapshot_store.dart` 及对应测试。
- 扩展原 `sync_current_state_source_test.dart` 的六类组合用例：真实SQLite → codec.prepare → 磁盘stage → 新store实例load → codec.open → 正文/文件字节断言。

Native binding使用生产AuthService/RootDirs/VenyorePlugin接口，凭证和文档解密到独立临时目录后读取，正常及异常退出均清理。文件/相册按真实category和目录祖先查找原始加密文件；锁定、空间切换、越界路径、软链、待恢复metadata journal、同长度且恢复mtime的文件修改均拒绝。方法通道在测试中被mock，**未做实际设备Native解密验证**。

为减少大型文件额外I/O，去掉了每次文件流前后重复的整文件hash扫描：流中直接对实际输出字节计算hash，外部源内容fence仍保留全量hash，不能退化为stat-only。未测真实网络/大文件吞吐，不声称已经满足端到端速度目标。

持久暂存按单快照字节预算写入part和blob，逐文件flush，最终fence成功才发布commit和目录。重启重新核对清单、长度/hash；同ID只复用原始密文，重新随机加密的不同内容拒绝覆盖。写入失败/源变更/缺附件不会产生可用的完成目录；已有其他快照不删除。文件流重读仍有hash防篡改。缓存加载不是验签授权，codec.open不可省略。

### 验证

- **228项合并回归通过**，日志 `ui_test_results/current-snapshot-20260919/combined-native-store.log`。
- 新增暂存测试37项、Native binding测试17项；连同既有174项。包含失败清理、原字节重试、ID冲突、资源预算、软链/路径逃逸、磁盘内容损坏、并发同ID写入、锁定/切换及临时明文清理。
- 本轮5个目标文件静态分析通过：`native-store-analyze.log`。
- 未接产品runtime/跨App与WebDAV传输/稳定heads/恢复完成状态机/UI；未安装构建，未录视频。原历史缺口门禁保持原样。
- 存储层目前要求每进程一个writer isolate，根路径由应用控制；单快照预算不等于磁盘剩余空间检查/缓存总额GC；没有目录fsync和真实断电验收。不能把缓存存在当作远端备份或恢复已完成。

## 再继续：runtime显式生成入口与可信本地序列位置

新增 companion `sync_current_snapshot_frontier.dart`、`sync_current_snapshot_producer.dart` 及各自测试。现有 `SyncPasswordExchangeRuntime` 新增显式 `stageCurrentSnapshot` 方法，把身份/密钥、Native binding、业务source、同步序列位置、codec和持久store连成调用链，缓存放在Exchange的 `Snapshots/Local`。未自动加入旧V1 Outbox，未由UI触发，也未上传远端。

- 覆盖位置必须来自本地连续、已发布且业务变更状态一致的batch链；ready/reserved、缺前序、重复/fork、跨空间变更和未完成的入站导入拒绝。远端producer使用已完成导入cursor，不篡改它。
- 从采集到暂存必须由调用方提供真实的空间级写排他，覆盖业务/Native文件变动、导入和导出回执；不提供仅锁快照自己的假安全默认值。过程中同时复核身份/session、完整内容和序列位置。
- 相同ID重试先加载并用当前可信本地密钥完整验签，复用原始字节，不重新计算今天的heads。不同vault/producer/key或自洽hash但坏签名均拒绝。
- 新发现的上线约束：只保存活跃内容而跳过已删除实体的因果版本，会使后续离线增量可能错误复活旧内容。因此生成frontier暂时拒绝目标空间墓碑；必须先扩展紧凑删除因果元数据，不能删墓碑或通过降低检查绕过。该风险属于新快照接续设计，尚未上线，不冒称既有用户已发生丢失/复活。

### 实际测试结果

**297项合并回归通过**：之前228项 + frontier45项 + producer20项 + 既有runtime兼容4项。证据 `ui_test_results/current-snapshot-20260919/combined-producer-runtime.log`。

Producer测试确实调用了 `SyncPasswordExchangeRuntime.stageCurrentSnapshot`，使用真实SQLite、真实codec/store并检查重开原密文、没有业务库/序列写入；Native binding为测试替身。还验证源/序列/身份/session在最后fence失败时不留下完成缓存，以及异步期间写排他scope持续持有。它不是双设备或实际Native解密验收。

新增和相关目标文件分析结果见 `producer-analyze.log`。原runtime另有12条已有的初始化参数风格info，没有本轮新编译错误；为避免改变其公开构造参数，未顺手重构。

仍未完成：实际应用全部写入者参与排他、删除因果元数据、跨App及WebDAV快照传输、空空间恢复状态机与完成后安装游标、UI、设备验收与性能实测。未安装新构建/录视频，历史缺口安全门禁保持不变。

## 再继续：V2删除因果信息与防旧内容复活回归

独立快照草案升级为 **V2/domain2**，旧增量V1协议不变。旧current-only V1快照即使签名正确也拒绝，不能复用为带删除因果信息的恢复基线；不覆盖旧ID产物。

- codec支持紧凑delete操作：保留UUID/revision/vector，受保护正文严格为schemaVersion/kind/deleted/deletedAt，不携带历史文件、凭证正文、trash或blob，也无关系依赖。活跃关系不能指向墓碑，upsert不能混入删除标志。
- source现在枚举全部活跃映射和九类墓碑，包括没有change_log的导入删除状态。删除记录不触发任何Native正文/原文件读取；缺失版本、错误字段、还残留活跃业务行、超预算均拒绝。
- sender frontier不再一概拒绝墓碑，前提是新producer走完整V2 source/codec；连续已发布batch链、未完成导入等原有检查不变。实际runtime生成测试已包含已删除文件的版本信息，并验证原字节重试。
- 新 `lib/sync/repository/sync_snapshot_tombstone_installer.dart` 在新空空间原子安装规范t_sync_entity删除状态，不伪造batch/sequence、不写applied marker/cursor/ACK。事务前校验全部payload，拒绝错误vault/非空空间/跨空间UUID碰撞/不一致重放。400条分块查询与写入，避免每实体单独通道调用。

### 实际验收

**400项合并回归全部通过**，日志 `ui_test_results/current-snapshot-20260919/combined-causal-v2.log`。本轮10个目标文件静态分析结果见 `causal-analyze.log`。

关键证据：
1. 六类活跃内容＋九类删除状态，从真实SQLite生成，经签名加密、磁盘暂存、重开验签保留全部语义。
2. 真正调用已有Password/File upsert applier：安装删除版本后，较旧vector不会产生业务行/文件写入；并发vector记录冲突，不直接复活内容。
3. 401条安装在第二批触发SQLite失败，前400条也回滚；随后重试成功且精确重复不写新数据。
4. V1旧缓存、坏签名、漏附件、关系指向墓碑、墓碑携带旧正文等负例拒绝。

### 仍然不是完整恢复完成

Installer只是恢复的一个子步骤，尚未接通全部活跃内容物化/文件journal收敛/最终安装heads/ACK。只允许目标仍为空或同一批墓碑时重放；目标DB已有任何applied-operation历史也保守拒绝，暂不适用于同一DB其他空间已有同步历史的通用恢复。必须由后续恢复状态机处理阶段进度，不能在活跃恢复后盲目重装墓碑。

本轮没有设备Native解密、WebDAV快照传输、UI/双设备验收或大文件端到端测速，未安装新构建/录制视频。仅解除生成端“有墓碑就拒绝”的临时限制，正式远端历史缺口/恢复完成门禁始终保持。
