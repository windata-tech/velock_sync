# Velock Sync 技术规格（Technical Specification）

- 文档版本：2.0
- 协议版本：Velock Sync Protocol V1 + Generic Vault V1
- 状态：已确认，进入实施
- 更新日期：2026-09-12
- 产品需求：[`PRD.md`](./PRD.md)
- 协议参考：[`SYNC_PROTOCOL_V1.md`](./SYNC_PROTOCOL_V1.md)
- UI 基线：[`UI_REDESIGN_SPEC.md`](./UI_REDESIGN_SPEC.md)

## 1. 目标

本规格把新的产品定位映射为工程实现：

- 格间 Managed Profile 继续作为零知识远程备份，换机恢复只是恢复路径；
- 恢复通用文件夹同步数据集，并按现代同步盘逻辑提供完整生命周期；
- 两类数据集共享同一 Dispatcher、Sync Core、远端 Provider 和本地状态数据库；
- 保留已有持久化数据和协议兼容性；
- UI 明确分为「格间备份」和「文件夹同步」，不再把整个产品描述成换机助手。

关键词：

- **MUST / 必须**：安全或数据正确性的硬要求；
- **SHOULD / 应该**：无特殊理由必须遵循；
- **MAY / 可以**：可选优化。

## 2. 当前代码基线与问题

### 2.1 已有能力

- `SyncProfileRepository` 统一读取 V1 Profile；
- `SyncProfileRunner`、`SyncUploadEngine`、`SyncDownloadEngine` 已支持批次、checkpoint、commit、ack 和恢复；
- `SyncGarbageCollector`、`RemoteRetentionManifestService` 已支持删除保护和保留清单；
- WebDAV、Google Drive、OneDrive 已实现 `RemoteObjectStore`；
- Velock Exchange 通过 App Group/平台桥接读取 opaque artifacts；
- 后台任务已统一调用 `SyncProfileDispatcher`。

### 2.2 当前缺口

- `SyncDatasetKind` 只剩 `velockManaged`；
- 通用文件夹实现曾被 `f702cf5` 从 Dart 层整体移除；
- `SyncProfileDispatcherFactory` 只注册 Velock executor；
- Sync 首页把所有 Profile 都视为格间数据；
- 空状态和主导航以「换机恢复」为主叙事；
- 通用 Profile 的密钥存储、扫描器、批次编译、冲突解决和 UI 路由缺失；
- 当前 `ConflictResolutionService` 只保留 Velock opener，不支持 selected-folder 三策略。

### 2.3 保留的兼容基础

- SQLite 中仍保留 Generic Vault 所需的 `scan_entries`、`incoming_batches`、`remote_objects`、`transfer_jobs`、`conflicts` 等表；
- `SyncProfileEnvelope` 已允许 `dataset` 保存非秘密类型化字段；
- 后台调度以 Dispatcher 为中心，可以新增 executor 而无需复制任务调度；
- iOS AppDelegate 仍保留 selected-folder document picker/security-scoped bookmark 控制；
- Android SAF 原生桥接仍存在。

## 3. 总体架构

```text
Flutter UI
  -> Application / Profile lifecycle
    -> SyncProfileDispatcher
      -> VelockManagedExecutor
        -> VelockSyncService
          -> Velock Exchange Adapter
      -> SelectedFolderExecutor
        -> SelectedFolderSyncService
          -> SelectedFolder Dataset Adapter
    -> Shared Sync Core
      -> Upload / Download / Checkpoint / GC
      -> RemoteObjectStore
        -> WebDAV / Google Drive / OneDrive
    -> SyncStateDatabase
    -> Platform secure storage
```

依赖规则：

- UI 不直接访问 Provider 或数据集内部；
- Sync Core 不依赖 Flutter Widget；
- 数据集不直接调用具体 Provider；
- Provider 不知道数据集明文、文件路径或密钥；
- 平台权限、App Group、SAF、security-scoped bookmark 位于平台适配层；
- 前台和后台只能通过同一 Dispatcher 组合执行。

## 4. Profile 模型与兼容性

### 4.1 持久化 kind

保留稳定 persisted value：

```dart
enum SyncDatasetKind {
  selectedFolder('selected-folder'),
  velockManaged('velock-managed'),
}
```

不得把 enum 名称或中文文案写入持久化协议。

### 4.2 语义映射

| kind | 产品名称 | 主职责 | 恢复方式 |
| --- | --- | --- | --- |
| `velock-managed` | 格间备份 | 零知识远程备份 | 格间账号/恢复 + 同远端回灌 |
| `selected-folder` | 文件夹同步 | 通用双向同步 | 恢复材料 + 选择文件夹 + 远端 |

### 4.3 公共 Envelope

继续使用：

- `profileId`；
- `datasetId`；
- `vaultId`；
- `deviceId`；
- `displayName`；
- `connectionId`；
- `state`；
- `background`；
- `dataset`；
- `createdAt`。

安全存储引用规则：

- `rootKeyRef`、`signingKeyRef`、Provider credential ref 可以进入 `dataset`；
- password、token、secret、seed、私钥、master key 等字段不得以明文进入 Envelope；
- `SyncProfileEnvelope` 保持 secret key 名称校验。

### 4.4 已有数据

- 已有 `velock-managed` payload 无需迁移；
- 新增 selected-folder 不改变 schemaVersion；
- 未知 kind 继续保持 isolated，不删除记录；
- 移除 Profile 继续使用 `removed` 状态，不物理删除历史运行记录。

## 5. Dispatcher 与执行

### 5.1 注册顺序

`SyncProfileDispatcherFactory` 必须注册：

```text
SelectedFolderSyncProfileExecutor
VelockSyncProfileExecutor
```

两者接收同一个 `SyncProfileRepository`。后台任务必须使用同一个 factory。

### 5.2 执行契约

`SyncProfileExecutor.run` 输入公共 `SyncProfileExecutionRequest`，输出公共 `SyncProfileRunResult`。

- Dispatcher 只读取 Profile、选择 executor、合并 in-flight 请求；
- 数据集服务负责解析自己的 Envelope；
- 数据集服务负责构造 Provider-neutral dataset adapter；
- 上传/下载/checkpoint/GC 由共享 Sync Core 执行。

### 5.3 前台

`_ForegroundSyncProfileRunService` 构造：

- `SelectedFolderSyncService`；
- `VelockSyncService`；
- 共享 `SecureCredentialStore`、`SecureVaultKeyStore`、`SecureDeviceSigningKeyStore`；
- 统一 `SyncProfileDispatcherFactory`。

### 5.4 后台

`runEnabledBackgroundProfiles` 必须构造与前台相同的 executor 组合。单个 Profile 失败不得阻塞同类或其他类 Profile。

## 6. 格间备份技术规格

### 6.1 信任边界

- Velock Sync 不访问格间 SQLite、明文或密钥；
- Exchange 中 artifact 全部按不可信字节处理；
- 签名、hash、长度、sequence 和 receipt 必须验证；
- 业务冲突在 Velock 内解决；
- Sync 不实现格间恢复时间线或文件级最近删除 UI。

### 6.2 备份数据流

```text
Velock business transaction
  -> encrypted/authenticated Exchange artifact
  -> VelockDatasetAdapter READY outbox
  -> SyncUploadEngine
  -> blobs -> batch -> commit
  -> RemoteObjectStore
```

下载：

```text
remote commit
  -> SyncDownloadEngine
  -> Velock Exchange inbox
  -> Velock business validation/apply
  -> trusted receipt
  -> acknowledgement
  -> applied cursor
```

### 6.3 首次基线

- 首次同步建立完整基线；
- 批次按操作数和字节上限切分；
- 单个不可拆分的大文件允许单独成批；
- 已存在且 hash 相同的远端对象不得重复上传；
- 中断后从 checkpoint/对象状态恢复。

### 6.4 删除保护与 GC

- 删除先进入 Velock 业务「最近删除」；
- 远端保留期当前为 30 天；
- GC 额外安全缓冲 7 天；
- GC 必须验证 Retention Manifest、checkpoint、活跃设备 ACK 和对象引用；
- 未满足条件时必须跳过并记录原因；
- 不得把远端列表缺失直接解释为可清理。

### 6.5 UI 状态

`velock-managed` Profile 状态映射：

| 数据状态 | UI |
| --- | --- |
| 无 profile | 未开启备份 |
| 初始化/配对 | 准备中 |
| running + transfers | 备份中 |
| latest run completed + no attention | 已保护 |
| access/reauthorization required | 需要处理 |
| paused | 已暂停 |
| blocked/error | 无法备份 |

首页文案必须强调持续备份；换机引导只出现在恢复区域。

## 7. 文件夹同步技术规格

### 7.1 数据集组成

恢复的实现模块：

```text
lib/dataset_adapters/selected_folder/
  selected_folder_access_authorizer.dart
  selected_folder_storage.dart
  android_document_tree_access.dart
  apple_security_scoped_folder_access.dart
  selected_folder_scanner.dart
  selected_folder_change_planner.dart
  selected_folder_batch_preparer.dart
  selected_folder_dataset_adapter.dart
  selected_folder_incoming_applier.dart
  selected_folder_conflict_resolver.dart
  selected_folder_sync_profile.dart
  selected_folder_profile_provisioner.dart
  selected_folder_sync_service.dart
  selected_folder_sync_profile_executor.dart
```

并恢复：

```text
lib/sync_core/crypto/generic_vault_*.dart
lib/sync_core/crypto/vault_recovery_package.dart
lib/sync_core/engine/generic_vault_batch_compiler.dart
lib/infrastructure/secure_storage/vault_key_store.dart
lib/infrastructure/secure_storage/device_signing_key_store.dart
```

### 7.2 目录授权

- iOS 只持久化 security-scoped bookmark；
- Android 只持久化 SAF tree URI；
- 桌面/测试可以使用 `localPath`；
- 每次实际扫描、读取或写入时获取临时访问 session；
- 路径必须规范化并验证仍在授权根目录内；
- 符号链接不得跟随到根目录之外。

### 7.3 扫描与变化检测

扫描要求：

- 递归枚举授权目录；
- 排除协议临时文件和忽略路径；
- 使用相对路径、类型、大小、mtime、file identity 判断变化；
- 大规模删除需要保护策略；
- 扫描完成后才提交 generation；
- 扫描失败不得把不完整枚举解释为删除。

数据库使用：

- `scan_entries`；
- `entityId` 跨路径稳定；
- `scan_generation`；
- `pending_generation`；
- `deleted_at`。

### 7.4 加密与身份

- 每个 Generic Vault 使用独立随机 32-byte root key；
- root key 只进入平台安全存储，Profile 保存 `rootKeyRef`；
- 每台设备创建自己的 Ed25519 签名身份，Profile 只保存 `signingKeyRef`；
- operations 和 blob 使用 Generic Vault 加密；
- envelope 包含 vault、device、sequence、batch、keyId、hash 和签名；
- 相同 logical key 只能重放完全相同内容；
- 密钥、恢复口令和明文不得写日志。

### 7.5 恢复材料

- 导出使用 PBKDF2-HMAC-SHA256 派生包裹密钥；
- 建议最低迭代次数由 codec 固定校验；
- v2 bundle 至少包含 vaultId、root key 和重新加入所需的可信设备公钥；
- 恢复时必须验证 expected vaultId 和 trust anchors；
- 导入后创建新的本地签名密钥；
- 已在平台安全存储中的 root key 可直接生成 bundle。

### 7.6 冲突

支持三种策略：

- `keepLocal`；
- `keepRemote`；
- `keepBoth`。

冲突解决必须先获得耐久 intent，再执行文件操作。完成 artifact 与解决结果必须可审计，失败不得让冲突处于“看起来已解决”的状态。

### 7.7 删除与恢复

- 删除写 tombstone；
- 远端对象按批次和 checkpoint 保留；
- 用户可在冲突/删除保护确认后继续；
- 移除 Profile 不等于删除远端数据；
- 用户删除远端空间的语义必须在 UI 中单独确认。

## 8. UI 与路由

### 8.1 新增/调整路由

保留现有：

- `/dashboard`：备份与同步首页；
- `/sync-profiles/new`：数据类别选择页；
- `/sync-profiles/new/velock`：格间备份向导；
- `/sync-profiles/new/selected-folder`：文件夹同步向导或列表入口；
- `/sync-profiles/:profileId`：统一详情。

### 8.2 首页结构

`SyncProfilesHome` 必须从数据库读取全部 Profile，再按 kind 分组：

- `velockManagedProfiles`；
- `selectedFolderProfiles`。

页面结构：

```text
标题：备份与同步

[格间备份]
状态、最近成功、目标、立即备份、恢复说明

[文件夹同步]
配置列表、状态、立即同步、新建文件夹同步
```

没有 Profile 时不使用单一居中空状态；应显示两个明确入口，格间备份优先。

### 8.3 详情

- Velock Profile 使用备份语义；
- Selected Folder Profile 使用通用同步语义；
- 两类共享运行历史、传输和冲突读取，可针对 kind 显示不同操作；
- 恢复入口：
  - Velock：打开格间完成恢复；
  - Selected Folder：导入恢复材料并加入空间。

## 9. 安全要求

- Provider 凭据只保存安全存储引用；
- OAuth 使用系统浏览器、PKCE 和最小 scope；
- 客户端不内置 Provider secret；
- 远端路径编码必须防止路径穿越；
- 所有远端对象视为不可信外部输入；
- fail closed 条件包括未知生产者、签名/hash 错误、非法版本、未授权成员和伪造 receipt；
- 日志和诊断导出不得包含凭据、密钥、恢复口令、原始路径或业务明文。

## 10. 错误与恢复

错误分类：

- `userActionRequired`；
- `authentication`；
- `authorization`；
- `network`；
- `providerTransient`；
- `localAccessLost`；
- `integrity`；
- `conflict`；
- `permanent`。

每个失败必须记录：

- runId；
- profileId；
- 时间；
- 归一化 error code；
- retryable；
- suggested action。

UI 不显示 UUID、异常类名或原始 Provider 响应体。

## 11. 测试规格

### 11.1 单元测试

- Profile Envelope 两类 kind 往返；
- Secure key store 读写与无明文持久化；
- Generic Vault 加密/签名测试向量；
- 扫描变化检测、路径穿越、符号链接和大小写冲突；
- batch 编译、重放、乱序和 hash 校验；
- tombstone、删除保护和 GC 条件；
- 冲突三策略与耐久 intent；
- Dispatcher 两类 executor 路由。

### 11.2 组件测试

- 同步首页按 kind 分组；
- 新建同步类别选择；
- 格间空状态强调备份不是换机；
- 文件夹同步向导；
- Profile 详情按 kind 显示不同操作；
- 恢复材料导出/导入错误态。

### 11.3 集成/回归

- 既有 Velock managed 全链路不回归；
- Selected Folder 上传、下载、重启恢复；
- 后台同时运行两类 Profile；
- Provider 故障注入；
- 物理设备目录授权；
- `flutter analyze` 干净。

## 12. 实施阶段

| 阶段 | 内容 | 出口标准 |
| --- | --- | --- |
| P0 | 本 PRD/SPEC、兼容性审计 | 文档与持久化方案确认 |
| P1 | 恢复 Generic Vault/安全存储/Selected Folder Dart 层 | 编译通过，核心单测通过 |
| P2 | Dispatcher、前台、后台接入 | 两类 profile 可被正确路由 |
| P3 | 同步首页、新建类别选择、详情和文案 | 两类入口完整，格间定位正确 |
| P4 | 恢复/冲突/后台/Provider 回归 | 测试与分析通过，实机冒烟 |

## 13. 迁移与回滚

迁移：

- 不修改 `velock-managed` persisted value；
- 不重写现有 Profile；
- 新 Profile 只在用户创建时写入；
- Generic Vault 文件从旧实现恢复后使用同一 crypto format 和测试向量。

回滚：

- 删除 selected-folder UI/executor 不得影响 Velock managed；
- 未知 selected-folder Profile 在旧版本中应作为 isolated/unsupported 显示，不能被删除；
- 移除 executor 不得删除远端对象、密钥引用或历史记录。
