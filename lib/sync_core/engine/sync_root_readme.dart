/// Builds the human-readable manifest stored at the remote sync root.
///
/// The document intentionally contains only protocol metadata. It never
/// includes credentials, vault keys, plaintext business data, or remote paths
/// supplied by a provider.
String buildSyncRootReadme({
  required String vaultId,
  required String datasetId,
  required String displayName,
  required String producerDeviceId,
  required String consumerDeviceId,
  required DateTime generatedAt,
}) {
  final generated = generatedAt.toUtc().toIso8601String();
  return '''
# Velock Sync 远程同步目录说明

> 本文件由 Velock Sync 自动生成，每次同步都会更新。请勿手动修改、移动或删除。

## 这个目录是什么

- 数据来源：格间（Velock）生成的加密 Exchange artifacts。
- 传输程序：Velock Sync。
- 目录用途：在格间设备和远端存储之间可靠传输、恢复和校验同步数据。
- 安全边界：这里只有密文和协议元数据。Velock Sync 不解密业务数据，也不保存格间主密钥、同步密钥或 WebDAV 密码。
- 原始文件名和文件内容不会以明文出现在这里。

## 当前同步空间

- 显示名称：$displayName
- Vault ID：$vaultId
- Dataset ID：$datasetId
- 本地格间生产设备 ID：$producerDeviceId
- Sync 消费设备 ID：$consumerDeviceId
- 协议版本：V1
- 本文件更新时间（UTC）：$generated

## 目录层次

```text
<同步根目录>/
├── README.md
└── v1/
    └── <vaultId>/
        ├── protocol.json
        ├── members/
        │   └── <deviceId>.member
        ├── blobs/
        │   └── <两位前缀>/<blobId>.blob
        ├── devices/
        │   └── <producerDeviceId>/
        │       ├── batches/
        │       │   └── <20位序号>/<batchId>/
        │       │       ├── envelope.json
        │       │       └── operations.enc
        │       └── commits/
        │           └── <20位序号>-<batchId>.commit
        ├── acknowledgements/
        │   └── <consumerDeviceId>/<producerDeviceId>/<20位序号>.ack
        ├── checkpoints/
        │   └── <checkpointId>/
        │       ├── envelope.json
        │       ├── parts/<partNumber>.enc
        │       └── checkpoint.commit
        ├── retention/
        │   └── <trashBatchId>.json
        └── gc/
            └── <planId>.manifest.json
```

目录中的部分目录会按实际使用情况出现；空目录不代表同步失败。

## 各类文件的作用

| 文件或目录 | 作用 | 是否应手动修改 |
|---|---|---|
| `README.md` | 当前说明文档，每次同步自动更新 | 否 |
| `protocol.json` | 识别 Vault 和协议版本，用于确认远端空间身份 | 否 |
| `members/*.member` | 已授权设备成员信息 | 否 |
| `blobs/**/*.blob` | 文件内容的加密数据，按内容哈希寻址 | 否 |
| `envelope.json` | 描述一个批次的设备、序号、批次 ID、密文大小和哈希 | 否 |
| `operations.enc` | 加密后的业务操作，例如新增、修改或删除 | 否 |
| `*.commit` | 批次可见性标记。只有 commit 写入成功后，批次才完整可同步 | 否 |
| `*.ack` | 消费端确认已处理的批次，用于推进已应用游标 | 否 |
| `checkpoints/` | 恢复检查和断点恢复材料 | 否 |
| `retention/<trashBatchId>.json` | 最近删除恢复所需的 opaque blob 保留清单 | 否 |
| `gc/` | 垃圾回收计划，用于安全清理已确认的历史对象 | 否 |

## 同步和恢复流程

1. 格间在本地事务中生成加密、已认证的 Exchange artifacts。
2. Velock Sync 从格间的 Outbox 读取并校验这些 artifacts。
3. Sync 先写入 blob、批次文件和 commit，commit 最后写入，确保批次不会半成品可见。
4. 其他受信任设备从远端下载批次，由 Sync 写入格间 Inbox。
5. 格间处理后返回可信 receipt，Sync 才推进已应用游标。
6. 删除操作会先以加密删除操作记录并提交；历史对象不会立即从远端物理删除，后续由垃圾回收安全清理。

## 删除保护策略

- 普通删除会进入格间的「最近删除」，计划保留 30 天。
- 删除尚未安全同步时，本机不会静默清理。
- Sync 的实际清理还会增加安全缓冲，当前策略为 30 天 + 7 天。
- 只有保留期、签名 Retention Manifest、checkpoint、所有活跃设备 ACK 和引用检查
  全部满足后，远端对象才会进入安全 GC。

## 管理规则

- 不要把这里当成普通文件目录使用。
- 不要用 NAS 文件管理器重命名、移动、编辑或删除 `v1/` 下的任何对象。
- 不要修改 `protocol.json`、`*.member`、`*.blob`、`envelope.json`、`operations.enc`、`*.commit`、`*.ack`、retention 清单或 checkpoint 文件。
- 备份时可以整体复制同步根目录；恢复时应保持目录层次不变。
- 远端根目录或 WebDAV 子路径改变后，同步配置需要重新验证。
- 如果需要诊断，请保留本文件、协议文件和完整的 `v1/` 目录结构。
- 远端凭据不会写入此目录；请通过系统安全存储或同步连接设置管理。
''';
}
