# Velock Sync Protocol V1

- 协议名称：Velock Sync Protocol
- 协议版本：1
- 文档版本：0.1
- 状态：Draft
- 更新日期：2026-07-14
- 产品需求：[`PRD.md`](./PRD.md)
- 技术规格：[`TECHNICAL_SPEC.md`](./TECHNICAL_SPEC.md)

## 1. 范围

本协议定义 Velock Sync 在不同设备、数据源和远端 Provider 之间，以 `managedVault` 布局交换增量变化的通用格式。用户可见的 `visibleMirror` 是技术规格中的扩展布局，不属于本协议 V1 最小集合。

协议覆盖：

- Vault、设备、批次和序列身份；
- 远端逻辑对象布局；
- 不可变 batch、blob 和 commit marker；
- 增量 operation；
- version vector；
- tombstone；
- 加密、签名和完整性；
- App Group Exchange 包布局；
- ack、checkpoint 和兼容性。

协议不定义：

- WebDAV、Google Drive 等 Provider 的具体 API；
- 格间内部业务表结构；
- UI；
- 普通文件系统的具体扫描实现；
- 用户账号或付费系统。

## 2. 设计目标

1. Provider-neutral；
2. Dataset-neutral；
3. 增量、双向、多设备；
4. 离线可写；
5. 不依赖全局远端锁；
6. 重复和乱序交付安全；
7. 支持端到端加密；
8. 格间模式下传输层无法解密；
9. 可流式传输大文件；
10. 可通过 checkpoint 压缩历史。

## 3. 标识符

所有标识符均使用小写、无大括号的 UUID 字符串，除非字段另有说明。

| 字段 | 作用 | 生成方 |
| --- | --- | --- |
| `vaultId` | 同步空间身份 | 创建 Vault 的可信数据源 |
| `deviceId` | 设备安装实例身份 | 当前设备可信组件 |
| `batchId` | 一个不可变批次 | 批次生产者 |
| `operationId` | 一条不可变操作 | 操作生产者 |
| `entityId` | 跨设备稳定实体身份 | 首次创建实体的设备 |
| `revisionId` | 实体版本身份 | 修改实体的设备 |
| `blobId` | 不透明 blob 身份 | blob 生产者 |
| `checkpointId` | checkpoint 身份 | checkpoint 生产者 |

要求：

- 不得从邮箱、手机号、文件路径或硬件序列号直接派生；
- 不得在不同 Vault 之间复用 `entityId` 或 `blobId`；
- `blobId` 为随机不透明 ID，不表达文件名或内容 hash；
- 内容 hash 通过独立字段传输。

## 4. 设备序列

每台设备在一个 Vault 中维护独立的无符号 64 位序列：

```text
1, 2, 3, ...
```

规则：

- 一个已发布 batch 占用一个 sequence；
- 同一设备的已提交 sequence 必须连续；
- sequence 只在 commit marker 成功后视为已发布；
- 崩溃恢复必须重用尚未确认的 sequence 和 batchId；
- sequence 达到实现上限时必须迁移协议，不得回绕；
- 不同设备之间没有全局 sequence。

## 5. 远端逻辑布局

Provider 必须把以下 logical key 映射到自己的对象模型：

```text
velock-sync/v1/<vaultId>/
├── protocol.json
├── members/
│   └── <deviceId>.member
├── blobs/
│   └── <blobId[0:2]>/
│       └── <blobId>.blob
├── devices/
│   └── <deviceId>/
│       ├── batches/
│       │   └── <sequence-20-digits>/
│       │       └── <batchId>/
│       │           ├── envelope.json
│       │           └── operations.enc
│       └── commits/
│           └── <sequence-20-digits>-<batchId>.commit
├── acknowledgements/
│   └── <consumerDeviceId>/
│       └── <producerDeviceId>/
│           └── <sequence-20-digits>.ack
├── checkpoints/
│   └── <checkpointId>/
│       ├── envelope.json
│       ├── parts/
│       └── checkpoint.commit
└── gc/
    └── <planId>.manifest.json
```

例如 sequence `42` 格式化为：

```text
00000000000000000042
```

### 5.1 远端对象规则

- `blob`、`operations.enc`、正式 `envelope.json` 和 commit marker 必须不可变；
- 一个设备只能写自己的 `devices/<deviceId>/` 命名空间；
- ack 只能由 `consumerDeviceId` 对应设备写入；
- commit marker 必须最后写入；
- 没有 commit marker 的 batch 不得被消费；
- `protocol.json` 只用于发现，不作为信任根；
- Provider 不支持目录时，可以把 logical key 映射为扁平对象名；
- Provider 内部 file ID 不得进入协议对象。

## 6. protocol.json

`protocol.json` 是非敏感发现文件：

```json
{
  "protocol": "velock-sync",
  "protocolVersion": 1,
  "vaultId": "0190d4de-1111-7777-8888-123456789abc",
  "createdAt": "2026-07-14T12:00:00.000Z",
  "minimumReaderVersion": 1,
  "minimumWriterVersion": 1,
  "cryptoSuite": "VLS1-A256GCM-HKDFSHA256-ED25519"
}
```

该文件可以被攻击者修改。客户端必须通过本地保存或配对获得的 `vaultId`、密钥和成员信息验证正式批次，不得仅信任该文件。

## 7. 成员描述

```json
{
  "protocolVersion": 1,
  "vaultId": "...",
  "deviceId": "...",
  "signingPublicKey": "base64url-ed25519-public-key",
  "friendlyNameCiphertext": "base64url-optional",
  "status": "active",
  "issuedAt": "2026-07-14T12:00:00.000Z",
  "issuedByDeviceId": "...",
  "issuerSignature": "base64url-ed25519-signature"
}
```

成员信任必须在以下任一流程建立：

- 扫码配对；
- 恢复码恢复；
- 已信任设备签发；
- 格间自己的可信设备管理流程。

仅仅在远端看到一个 `.member` 文件，不足以信任该设备。

## 8. 批次目录

一个远端批次包含：

```text
<batchId>/
├── envelope.json
└── operations.enc
```

blob 位于 Vault 级公共 blob 区，不复制到每个 batch 目录。

### 8.1 envelope.json

```json
{
  "protocol": "velock-sync",
  "protocolVersion": 1,
  "vaultId": "...",
  "batchId": "...",
  "sourceDeviceId": "...",
  "sequence": 42,
  "batchKind": "incremental",
  "createdAt": "2026-07-14T12:00:00.000Z",
  "keyId": "metadata-key-1",
  "operations": {
    "logicalName": "operations.enc",
    "cipherSize": 16384,
    "cipherSha256": "lowercase-hex-sha256",
    "compression": "none",
    "operationCount": 8
  },
  "blobs": [
    {
      "blobId": "...",
      "logicalKey": "blobs/ab/<blobId>.blob",
      "cipherSize": 8388608,
      "cipherSha256": "lowercase-hex-sha256",
      "protection": "source-opaque",
      "chunkSize": 0
    }
  ],
  "previousBatchId": "...",
  "previousSequence": 41,
  "signatureAlgorithm": "Ed25519",
  "signature": "base64url-signature"
}
```

### 8.2 batchKind

允许值：

```text
baseline
incremental
checkpoint-part
membership
```

### 8.3 Envelope 签名

签名输入为：

1. 移除 `signature` 字段；
2. 使用 JSON Canonicalization Scheme（JCS）规范化 UTF-8 JSON；
3. 计算 Ed25519 签名；
4. 使用无 padding 的 base64url 编码。

签名覆盖：

- Vault 和设备身份；
- sequence；
- operations ciphertext hash；
- 所有 blob ID、大小和 hash；
- previous sequence 链；
- crypto key ID。

接收方必须：

1. 验证 `vaultId`；
2. 查找已信任的 `sourceDeviceId` 公钥；
3. 验证签名；
4. 验证 sequence 链；
5. 再下载和处理内容。

## 9. commit marker

commit marker 最后写入：

```json
{
  "protocolVersion": 1,
  "vaultId": "...",
  "sourceDeviceId": "...",
  "sequence": 42,
  "batchId": "...",
  "envelopeSha256": "lowercase-hex-sha256",
  "committedAt": "2026-07-14T12:01:00.000Z"
}
```

规则：

- commit marker 不需要成为信任根；
- envelope 的签名和 hash 才决定批次是否有效；
- commit marker 存在表示生产者认为相关对象已完整发布；
- 客户端发现 marker 后仍必须验证所有 hash；
- marker 存在但内容缺失时属于可重试的远端不一致；
- 超过策略阈值仍缺失时标记为远端损坏。

## 10. operations.enc

### 10.1 明文结构

解密后的 UTF-8 JSON：

```json
{
  "protocolVersion": 1,
  "vaultId": "...",
  "batchId": "...",
  "sourceDeviceId": "...",
  "sequence": 42,
  "operations": [
    {
      "operationId": "...",
      "entityId": "...",
      "entityKind": "file",
      "operationType": "upsert",
      "revisionId": "...",
      "previousRevisionIds": ["..."],
      "versionVector": {
        "device-a": 12,
        "device-b": 4
      },
      "timestamp": "2026-07-14T12:00:00.000Z",
      "payload": {},
      "blobRefs": ["..."]
    }
  ]
}
```

### 10.2 operationType

V1 规范值为：

```json
["upsert", "delete", "resolve-conflict"]
```

未知 operation type 必须拒绝整个 batch，除非未来协议明确声明可忽略扩展。

### 10.3 标准文件 payload

文件：

```json
{
  "entryType": "file",
  "parentEntityId": "...",
  "name": "report.pdf",
  "size": 123456,
  "modifiedAt": "2026-07-14T11:00:00.000Z",
  "contentBlobId": "..."
}
```

目录：

```json
{
  "entryType": "directory",
  "parentEntityId": "root",
  "name": "Documents",
  "modifiedAt": "2026-07-14T11:00:00.000Z"
}
```

删除：

```json
{
  "deletedAt": "2026-07-14T11:00:00.000Z",
  "reason": "user-delete"
}
```

### 10.4 格间 payload

格间可以定义自己的 `entityKind` 和 payload schema，但必须满足：

- payload 只位于 `operations.enc` 内；
- Velock Sync 不解析；
- 不使用本机 SQLite 自增 ID 作为跨设备主键；
- 关系使用稳定 `entityId`；
- 业务 schema 自带版本号；
- 格间导入器拒绝未知且不可安全忽略的 schema。

示例：

```json
{
  "velockSchemaVersion": 1,
  "recordType": "password",
  "record": {
    "title": "...",
    "encryptedFilename": "..."
  }
}
```

该示例位于已加密 operations 内容中，不是远端明文。

## 11. operations.enc 二进制格式

多字节整数使用 big-endian。

```text
Offset  Size  Field
0       4     Magic ASCII "VLSO"
4       1     Format version = 1
5       1     Flags
6       2     Header length
8       N     Header JSON (JCS UTF-8)
8+N     12    AES-GCM nonce
...     M     Ciphertext
...     16    AES-GCM authentication tag
```

Header JSON：

```json
{
  "vaultId": "...",
  "batchId": "...",
  "sourceDeviceId": "...",
  "sequence": 42,
  "keyId": "metadata-key-1",
  "compression": "none"
}
```

### 11.1 加密

- 算法：AES-256-GCM；
- 密钥：Metadata Encryption Key；
- nonce：96 位随机值；
- 同一个 key 下 nonce 不得复用；
- AAD：Header JSON 的 JCS UTF-8 字节；
- 压缩：V1 允许 `none` 和 `gzip`；
- 压缩发生在加密之前；
- 解密后总大小必须受本地安全上限约束。

## 12. Blob 格式

### 12.1 protection 类型

```text
source-opaque
vlsb1
plain
```

- `source-opaque`：数据源已经加密，例如格间现有加密文件；
- `vlsb1`：通用端到端加密文件格式；
- `plain`：普通镜像模式，仅在用户明确选择时允许。

### 12.2 source-opaque

协议不解释内部格式。必须依赖：

- Envelope 签名；
- `cipherSize`；
- `cipherSha256`；
- 数据源自身的解密和格式校验。

### 12.3 VLSB1 流式加密格式

多字节整数使用 big-endian：

```text
File Header
Offset  Size  Field
0       4     Magic ASCII "VLSB"
4       1     Format version = 1
5       1     Flags
6       4     Chunk size
10      8     Plaintext size
18      8     Nonce prefix
26      2     Key ID length
28      N     Key ID UTF-8

Repeated Chunk
0       4     Chunk plaintext length
4       M     AES-GCM ciphertext
4+M     16    AES-GCM tag
```

每个 chunk：

- 使用同一个 blob-specific key；
- nonce = 8 字节随机 prefix + 4 字节 chunk index；
- chunk index 从 0 开始；
- AAD 包含 `vaultId`、`blobId`、chunk index、总明文大小和当前 chunk 明文大小；
- AAD 的精确二进制编码为：`"VLSA"`（4 ASCII bytes）、version（`0x01`，1 byte）、`vaultIdLength`（uint16）+ UTF-8 `vaultId`、`blobIdLength`（uint16）+ UTF-8 `blobId`、`chunkIndex`（uint32）、`plaintextSize`（uint64）和 `chunkPlaintextLength`（uint32）。所有整数均为 big-endian；ID 长度不得超过 65535 bytes；
- 最后一个 chunk 可以小于 chunk size；
- chunk 数不得超过 `2^32`；
- 默认 chunk size 为 4 MiB；
- 恢复上传时必须复用相同 header、key 和 nonce prefix，保证 ciphertext 稳定。

Blob-specific key：

```text
HKDF-SHA256(
  inputKeyMaterial = Blob Encryption Key,
  salt = UTF8(vaultId),
  info = UTF8("velock-sync/v1/blob/") || UTF8(blobId),
  length = 32
)
```

### 12.4 plain

- 远端内容为原始文件；
- `cipherSha256` 字段在此模式表示远端原始字节的 SHA-256；
- Envelope 中仍不得暴露绝对本地路径；
- 文件名是否在远端可见由普通镜像 Provider 映射策略决定。

## 13. 密钥派生

Crypto Suite：

```text
VLS1-A256GCM-HKDFSHA256-ED25519
```

从 32 字节 Vault Root Key 派生：

```text
Metadata Encryption Key:
HKDF-SHA256(root, salt=UTF8(vaultId), info="velock-sync/v1/metadata", 32)

Blob Encryption Key:
HKDF-SHA256(root, salt=UTF8(vaultId), info="velock-sync/v1/blob-root", 32)

Identifier Key:
HKDF-SHA256(root, salt=UTF8(vaultId), info="velock-sync/v1/identifier", 32)
```

要求：

- Root Key 不进入同步包；
- 格间模式 Root Key 不进入 Velock Sync；
- 密钥使用 `keyId` 支持轮换；
- `keyId` 不是密钥；
- 旧 key 在仍需读取历史时必须保留；
- 移除设备不能自动撤销其已经获得的历史明文能力，敏感场景需要轮换 key 并生成新 checkpoint。

## 14. Version Vector

### 14.1 更新

实体本地版本：

```json
{"device-a": 4, "device-b": 2}
```

设备 A 修改后：

```json
{"device-a": 5, "device-b": 2}
```

### 14.2 比较伪代码

```text
compare(a, b):
  aGreater = false
  bGreater = false

  for device in union(keys(a), keys(b)):
    av = a[device] or 0
    bv = b[device] or 0
    if av > bv: aGreater = true
    if bv > av: bGreater = true

  if !aGreater && !bGreater: return equal
  if aGreater && !bGreater: return dominates
  if !aGreater && bGreater: return dominated
  return concurrent
```

### 14.3 冲突解决

解决并发版本时，新版本向量取双方逐分量最大值，再递增解决设备分量。

例如：

```text
A = {device-a: 5, device-b: 2}
B = {device-a: 4, device-b: 3}
max = {device-a: 5, device-b: 3}
由 device-a 解决后 = {device-a: 6, device-b: 3}
```

## 15. Tombstone

删除必须作为 operation 传播。Tombstone 至少包含：

```json
{
  "entityId": "...",
  "revisionId": "...",
  "versionVector": {},
  "deletedAt": "...",
  "operationId": "..."
}
```

规则：

- 收到旧 upsert 时，若 tombstone 版本支配它，不得复活；
- 收到与 tombstone 并发的修改时创建删除/修改冲突；
- 只有 checkpoint 和设备 ack 满足 GC 条件后才能清理；
- 清理 tombstone 后仍需防止被已移除但长期离线设备复活，设备移除和 key 轮换策略必须配合。

## 16. Ack

ack 是不可变对象：

```json
{
  "protocolVersion": 1,
  "vaultId": "...",
  "consumerDeviceId": "...",
  "producerDeviceId": "...",
  "appliedThroughSequence": 42,
  "createdAt": "2026-07-14T12:10:00.000Z",
  "signatureAlgorithm": "Ed25519",
  "signature": "base64url-signature"
}
```

签名规则与 Envelope 相同。

- 只表示已经成功应用到该 sequence；
- sequence 必须连续；
- 可以每 N 个 batch 或每次运行结束发布；
- 新 ack 可以使旧 ack 失去 GC 用途，但旧对象不需要立即删除。

GC manifest 是不可变审计对象。执行删除前必须先发布 manifest；默认
dry-run 只发布计划，且 manifest 必须记录 checkpoint、候选对象和执行模式。
- 格间模式下，ack 必须由接收批次的格间主 App 生成并签名；Velock Sync 只能转发签名后的 ack artifact。
- 通用 Dataset 模式下，ack 可以由持有该 Dataset 设备签名私钥的 Velock Sync 生成。

## 17. Checkpoint

Checkpoint 表示某一时点的逻辑完整状态。

```text
checkpoints/<checkpointId>/
├── envelope.json
├── parts/
│   ├── 00000001.enc
│   ├── 00000002.enc
│   └── ...
└── checkpoint.commit
```

Envelope 包含：

- `checkpointId`；
- 创建设备；
- 创建时间；
- 覆盖的各设备 sequence；
- part 数量、大小和 hash；
- 使用的 key ID；
- 签名。

Checkpoint 必须最后发布 `checkpoint.commit`。未提交 checkpoint 不得用于恢复或 GC。

新设备加入流程：

1. 获取并验证最新可用 checkpoint；
2. 导入 checkpoint；
3. 从 checkpoint cursor 之后下载各设备增量；
4. 发布自己的 ack。

## 18. App Group Exchange 格式

本地交换包：

```text
<batchId>/
├── envelope.json
├── operations.enc
├── blobs/
│   └── <blobId>.blob
└── READY
```

`READY` 必须最后创建，内容：

```json
{
  "batchId": "...",
  "envelopeSha256": "...",
  "publishedAt": "2026-07-14T12:00:00.000Z"
}
```

规则：

- 构建时目录名为 `<batchId>.tmp`；
- `.tmp` 完成后原子重命名；
- 没有 `READY` 的包不得领取；
- 领取通过原子移动或平台协调锁完成；
- Velock Sync 只能读取包内相对路径；
- `logicalKey` 不能作为任意本地文件路径使用；
- blob 符号链接和硬链接默认拒绝；
- 包内文件数量和总大小必须与 Envelope 一致。

### 18.1 上传回执

```json
{
  "protocolVersion": 1,
  "batchId": "...",
  "vaultId": "...",
  "sourceDeviceId": "...",
  "sequence": 42,
  "remoteCommitKey": "devices/.../commits/...",
  "completedAt": "2026-07-14T12:01:00.000Z",
  "status": "published"
}
```

回执不包含 Provider Token 或真实账号信息。

### 18.2 导入回执

```json
{
  "protocolVersion": 1,
  "batchId": "...",
  "sourceDeviceId": "...",
  "sequence": 42,
  "completedAt": "2026-07-14T12:03:00.000Z",
  "status": "imported",
  "resultCode": "ok",
  "ackArtifactRelativePath": "ack/<producerDeviceId>-00000000000000000042.ack"
}
```

格间模式的 `ackArtifactRelativePath` 指向由格间签名的 ack 文件；Velock Sync 只能验证外层格式并原样上传。

## 19. 接收验证顺序

接收方必须按以下顺序处理：

1. 限制目录总文件数和声明大小；
2. 解析 Envelope，拒绝重复 JSON key；
3. 验证协议版本；
4. 验证 Vault ID；
5. 验证 source device 是否受信任；
6. 验证 Envelope 签名；
7. 验证 sequence 和 previous chain；
8. 验证 operations 大小和 SHA-256；
9. 验证所有 blob 大小和 SHA-256；
10. 验证 AES-GCM；
11. 解压并检查解压后大小；
12. 解析 operations；
13. 检查 operationId 幂等；
14. 比较 version vector；
15. 在事务中导入；
16. 写 applied operation 和 cursor；
17. 提交事务；
18. 写 receipt/ack。

任何一步失败都不得写入部分业务状态。

## 20. 限制

推荐默认值：

```text
maxEnvelopeBytes = 4 MiB
maxOperationsCipherBytes = 64 MiB
maxOperationsPlainBytes = 256 MiB
maxOperationsPerBatch = 500
maxBlobsPerBatch = 500
maxPathDepth = 128
maxNameUtf8Bytes = 1024
maxVersionVectorDevices = 256
maxClockFutureSkew = 24 hours（仅用于提示，不用于版本排序）
```

单个 blob 大小由平台和 Provider 能力决定，但必须使用 64 位长度并执行磁盘空间预检。

## 21. 兼容性

### 21.1 Reader/Writer

- Reader 只能读取其支持的 `protocolVersion`；
- Writer 必须满足远端 `minimumWriterVersion`；
- 未知必需字段或操作必须拒绝；
- 新增可选字段时旧 Reader 可以忽略，但该字段不得影响安全判断；
- crypto suite 变化必须显式版本化。

### 21.2 升级

协议升级流程：

1. 新客户端先支持读旧写旧；
2. 所有活动设备支持新协议后更新 Vault 最低 Reader；
3. 再启用写新；
4. 必要时生成新 checkpoint；
5. 未升级设备保持只读或停止同步，不得产生无法识别的数据。

## 22. 标准错误码

| Code | 含义 | 是否可重试 |
| --- | --- | --- |
| `VLS-PROTOCOL-UNSUPPORTED` | 协议版本不支持 | 否 |
| `VLS-VAULT-MISMATCH` | Vault 不匹配 | 否 |
| `VLS-DEVICE-UNTRUSTED` | 设备未受信任 | 需要用户操作 |
| `VLS-SIGNATURE-INVALID` | 签名无效 | 否 |
| `VLS-AEAD-INVALID` | AEAD 校验失败 | 否 |
| `VLS-HASH-MISMATCH` | 内容 hash 不一致 | 可重新下载有限次数 |
| `VLS-SEQUENCE-GAP` | sequence 缺口 | 是 |
| `VLS-REPLAY` | 重放或重复 | 幂等忽略/审计 |
| `VLS-BATCH-INCOMPLETE` | commit 存在但对象不完整 | 是 |
| `VLS-OP-UNSUPPORTED` | operation 不支持 | 否 |
| `VLS-IMPORT-CONFLICT` | 业务冲突 | 需要处理 |
| `VLS-PATH-INVALID` | 非法路径 | 否 |
| `VLS-SIZE-LIMIT` | 超过安全上限 | 否 |
| `VLS-SPACE-INSUFFICIENT` | 本地空间不足 | 条件变化后重试 |

## 23. 安全注意事项

- App Group ID、Vault ID 和协议不是秘密；
- 不得在外层 Envelope 写明文文件名和业务标题；
- SHA-256 对象 hash 不是认证，必须同时验证签名和 AEAD；
- 不得信任 Provider 返回的 MIME、大小或 hash；
- 不得把 logical key 直接拼成本地绝对路径；
- 不得提取包含符号链接的归档；
- 不得使用时间戳判断因果关系；
- 不得以“远端缺少文件”直接推断删除；
- 不得自动信任远端新设备成员；
- 不得把 OAuth client secret、Refresh Token 或 Vault Root Key 写入仓库；
- 日志不得包含 operations 解密结果。

## 24. V1 实现最小集合

V1 首次可用实现必须支持：

- `protocol.json`；
- 成员信任的本地记录；
- 不可变 blob；
- Envelope + Ed25519；
- AES-256-GCM operations；
- commit marker；
- 每设备 sequence；
- upsert/delete；
- version vector；
- tombstone；
- ack；
- App Group READY/receipt；
- WebDAV logical key 映射；
- 重复、断网和崩溃恢复测试。

Checkpoint、设备移除和远端 GC 可以在兼容 V1 格式的后续小版本启用，但实现必须从一开始保留相应字段和命名空间。
