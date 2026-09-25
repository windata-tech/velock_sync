# 格间当前内容全量快照：空远端补传设计与实施边界

暂定方向：用户要求“继续”，未单独选择历史保留策略；先沿推荐方向开发当前完整内容快照，不自动执行迁移或丢弃全部历史版本。不得删除旧备份、重置原生产者身份、改写旧不可变批次或降低历史门禁。

## 为什么不能把旧增量重新编译

历史发送包在回执后删除，重新加密会改变nonce、hash和签名；同ID覆盖远端违反不可变协议。现有checkpoint仅记录发布进度，不能代表文件、原图或凭证内容。

## 当前内容必须来自可信Velock

- 不能仅扫描pending变化，也不能只读取历史本地change_log。远端恢复的实体可以有当前revision和本地业务文件，但没有当前protected_payload日志。
- 必须从同一稳定版本的实际业务状态读取文件/相册、普通账号、信用卡、日记、文档、目录、标签和关联；缺内容、未完成文件落盘journal、未处理冲突均不能悄悄跳过。
- 私钥、解密正文始终留在Velock。Sync仅传输加密快照part和流式blob，不直接读取业务数据库或拿到根密钥。

## 独立快照协议，不能冒充历史批次

1. 独立快照ID和域分离的manifest，签名绑定vault、授权生产者、当前entity/revision集合、part顺序/长度/hash、全部blob长度/hash和每个生产者的覆盖游标（sequence与batch ID）。
2. 大型文件/原图流式处理并按blob去重；不把相册整体base64放进manifest，不引入无限本地归档。使用独立暂存、空间预算和版本复核，生成中发生变化应安全重试。
3. 所有数据落盘、校验完成后最后发布快照commit；中断续传沿用同一快照和原始字节，不重新签出同ID的另一内容。
4. 接收端必须使用本地已信任生产者验签并校验全部part/blob；普通progress checkpoint不能走这条分支。
5. 第一版只恢复到新的空空间：逐条操作可幂等重放，文件journal须完成，所有内容验收后才能安装覆盖游标和ACK。中途失败保留“未完成”，不能因为部分applied marker存在就跳过文件落盘。
6. 恢复排序：目录先于子项、标签successor先于旧标签、文件/文档与标签先于关联。拒绝缺失引用和环，不通过剥离关系临时恢复。
7. 完整快照成功后再从认证游标继续增量；旧客户端不支持时明确拒绝，而不是猜测跳过缺失历史。

## 本轮代码进展（未上线全量快照入口）

- `velock_codex/lib/sync/bridge/sync_snapshot_order.dart`：确定性、非递归拓扑排序，先验证完整依赖图再返回应用计划；缺引用、环、重复实体、资源超限拒绝。7项测试包括2万层目录链，无递归栈风险；本机测试约48ms，不代表网络恢复耗时。
- 并行修复实际增量/快照共用导入binding：多文件同批次必须逐操作分配blob，不把整批blob误传给每条文件；删除操作的历史blob引用不要求重新携带已删除内容。具体测试结果另记验证报告。

可信业务枚举与签名快照组件已在后续实现（见下节），Native读取binding与本地暂存后续已实现（见文末），但尚未接入实际runtime、传输、恢复完成证明和游标安装、UI授权与进度、双设备全类型验收。组件测试本身不是快照恢复完成证明。

## 当前内容组件与协议草案（后续实现，仍未接入产品入口）

### 可信内容源

`SyncCurrentStateSource.collect` 从指定sandbox的实际业务表、实体映射及vault信息中读取当前状态，不依赖change_log。短只读事务捕获元数据；凭证完整正文与文件流通过可信本地回调取得，回调不在SQLite事务内运行。恢复导入而没有本地change_log的记录也必须包含。

产物为依赖记录、加密operation及流式blob。身份、revision、vector保持不变；operation/blob ID由snapshot/vault/entity确定性派生。未知活跃类型、未映射行、缺正文/文件、缺关系或环均拒绝，不跳过。生成前后用数据库指纹/连接变更计数和内容回调复核；文件回调必须提供不可变版本及内容变更检查，不能只信mtime。未完成SQLite文件journal、冲突解决intent或未解决冲突拒绝；磁盘文件/相册metadata intent由必填只读回调检查。最终发布仍需调用者的写排他/原子代次校验；只读fence不是跨进程锁，也不生成可靠的覆盖游标。

### 独立加密协议

`SyncCurrentSnapshotCodec.prepare/open` 使用现有VLP1保护业务payload及part。manifest为规范JSON，Ed25519签名使用独立域 `VelockCurrentStateSnapshot/2\\n`（实际域尾部为换行）。kind为 `velock-current-state-snapshot`、version为2（独立快照草案升级，旧增量V1不变）；生产者/key/vault/snapshot身份由调用者本地信任约束，不接受远端自报公钥。

manifest包含part序号、密文长度/hash、条数，blob ID/长度/hash/保护类型，以及各生产者的sequence+batchID。commit绑定manifest SHA-256，必须最后发布。每part最多500条，默认8MiB，元数据总限128MiB；所有限额可收紧。文件、原图始终是单独流，按blob ID只哈希一次准备；验证后重新读流仍校验长度和hash以拒绝源被替换。消费者必须先完整暂存，不能在流尚未结束校验时发布业务文件。

解包先验签/身份，验证所有part、内层payload认证、依赖图与全部blob后返回只读plan。该plan**不是应用完成回执**，不写业务库、不更新游标、不发ACK，也不表示正文已经由业务applier解码或图片已可展示。普通进度checkpoint不能替代manifest。

同一snapshot ID的中断恢复必须复用已暂存的原始产物；重新运行prepare会产生新nonce，不能覆盖同ID已发布对象。后续已提供本地持久暂存层（见文末），远端断点续传尚未接通；调用者不得直接用此组件替换正式历史门禁。

### 下阶段必需条件

1. 将Native读取binding接入实际runtime，捕获稳定heads并提供发布排他条件。
2. 将本地暂存接入跨App交换与WebDAV commit-last传输，补实际可用磁盘空间与总缓存生命周期预算。
3. 新空空间恢复状态机：全部物化、journal收敛、幂等续传，然后原子安装heads及完成回执。
4. 现有历史门禁只接受验证且已恢复完成的快照覆盖证明，不能仅凭manifest名字放行。
5. 双设备六类正文/原图验收、断网/重启/损坏注入及性能计时后，再制作中英文原始录像。


## 后续：Native读取binding与持久暂存

- `SyncCurrentStateNativeBinding` 构造时绑定已解锁的sandbox、AuthService、RootDirs、数据库和现有VenyorePlugin；任何锁定/解锁或空间切换使旧source失效。凭证/日记/文档调用现有Native decrypt，独立临时目录读取完整正文，finally清理明文；文件和媒体按真实category及目录祖先解析加密文件，不读缩略图。实体/路径、符号链接、文件hash和metadata intent均检查。文件流本身计算hash，不能只依赖mtime。该binding尚未被产品runtime调用。
- `SyncCurrentSnapshotStore.stage` 流式写入加密part/blob，限定单快照磁盘字节预算，每文件flush；源fence复核通过才写commit并原子rename整个目录。`load`重新核对完整清单及hash，返回文件支持的流（不是bulk字节）；重新读blob仍验证hash。缓存本身无密钥，不提供签名信任，应用前仍必须调用codec.open。
- 同ID已完成缓存只允许复用原manifest/commit，不得重新prepare再覆盖；已有完整旧快照即使源后来变化，也保留原点时内容可供重试。未完成的专用pending目录不可被load，重试时在锁内清理，失败不会删除其他已完成快照。
- 每进程只允许一个writer isolate；该isolate内队列与跨进程OS锁组合使用。根目录须由应用拥有；可配置合法根目录软链，根目录下的snapshot/part/blob/lock软链拒绝。不是对恶意同UID并发写入的安全沙箱。
- 预算不是磁盘剩余空间探测，也未提供缓存整体GC；ENOSPC失败不发布完成。dart:io没有目录fsync接口，不能承诺断电后绝对持久，重启必须重新完整校验。尚未验证跨进程崩溃/真实断电；测试只覆盖故障注入、重新打开及单isolate并发。

## 快照生成入口与继续增量的前提

`SyncPasswordExchangeRuntime.stageCurrentSnapshot` 是显式本地生成入口，调用 `SyncCurrentSnapshotProducer`，连接本地身份/根密钥/签名密钥、Native binding、当前业务内容、序列覆盖位置和磁盘暂存。缓存位于 Exchange 下 `Snapshots/Local`，**不进入旧V1 Outbox队列**；旧消费者不应误读为增量批次。该方法尚未由UI/自动同步触发。

调用者必须提供覆盖所有业务/文件写入、导入、导出序列预留和回执处理的 `SyncSnapshotWriterScope`，并从采集开始保持到暂存结束。没有默认的“只锁快照自己”的mutex，因为那不能防止既有业务写入。Native binding必须对应同一数据库/空间，在最后校验后由调用方dispose。暂存期间复核身份、解锁session、业务版本及序列位置；缓存重试使用本地密钥验签原字节，不重新采集今天的heads替换旧快照。

`SyncCurrentSnapshotFrontier` 只从可信本地数据库读取位置，不以远端文件名或MAX(sequence)冒充完整覆盖。需核对连续的本地batch链、业务change状态和远端已提交的导入cursor，拒绝未完成的序列预留、前序缺口、状态矛盾、部分导入及采集期间数据库变更。具体接受的持久状态以实现及回归测试为准。

**删除因果状态已加入V2快照**：source枚举活跃与已删除映射，delete只携带UUID/revision/vector与受保护的删除时间，不搬历史正文。生成端不再一概拒绝墓碑，仍要求真实完整source；原先V1当前内容缓存即使签名正确也不能作为新恢复基线。新空空间有原子删除状态安装子步骤，正式恢复完成、游标安装和远端历史门禁仍未放行。具体边界见下节。


## V2删除因果状态与空空间安装子步骤

- 独立快照版本/签名域升级为2，防止旧的current-only缓存被误当成完整的因果基线。旧增量V1不变；不覆盖旧ID缓存，应保留旧产物并选择新的V2快照ID。
- delete的受保护JSON严格为 `{schemaVersion:1, kind, deleted:true, deletedAt}`，deletedAt为正JS-safe毫秒整数；operation保留UUID/revision/vector。不得带blob、历史record/trash内容或关系依赖，活跃关系也不得指向墓碑。upsert不得混入delete标志。
- source支持九种实体的墓碑，包括导入后没有change_log的映射；允许删除映射的本地行已清理，不调用Native正文/文件读取。缺版本、错误字段、仍残留活跃业务行和总量超限均拒绝。活跃与删除状态共用完整性fence。
- `SyncSnapshotTombstoneInstaller.install` 只接受可信codec已验证的V2快照和本地目标rootKey。在事务前解密/校验所有记录，再确认目标为空、vault匹配、UUID无跨空间冲突；事务内仅安装规范t_sync_entity墓碑，原子全成或全败。不捏造增量batch/sequence，不写applied marker、cursor或ACK。精确重试只允许目标仍为同一批墓碑（或其子集），不能在活跃恢复后盲目重跑。
- 安装器保守拒绝目标DB已有任何applied-operation历史，因此尚未支持“同一数据库其他空间已有同步历史”的通用恢复。空间级写排他、完整恢复状态机、文件journal收敛和最终游标安装仍必须单独实现。
- UUID冲突查询和插入按400条分块，避免每实体单独查询/跨平台通道调用；外层SQLite事务保持原子性。真实密码/文件upsert applier验证：旧版本被忽略，并发版本进入冲突，删除状态不被静默复活。这不是所有UI流程或端到端恢复验收。
