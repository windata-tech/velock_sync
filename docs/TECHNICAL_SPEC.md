# Velock Sync 技术规格

## 目标

Velock Sync 是一个同步传输层。`velock_codex` 负责 Velock 业务数据的本地存储、加密、解密、签名和 Exchange artifact 生成；`velock_sync` 负责把这些 artifact 在设备与远端 Provider 之间可靠传输。

## 边界

- Sync 不读取 Velock 数据库或明文。
- Sync 不持有、生成、恢复或派生 Velock 密钥。
- Sync 不解密或重新加密 `operations.enc`、密文 blob 和业务 payload。
- Sync 只验证外层 envelope、长度、hash、签名、sequence、cursor 和可信 receipt。

## 架构

```text
Velock Exchange -> Dataset Adapter -> Sync Core -> RemoteObjectStore -> WebDAV / Google Drive / OneDrive
```

前台、后台和手动触发统一经过 `SyncProfileDispatcher` 和 `SyncProfileRunner`。

## 数据流

1. `velock_codex` 在本地事务中生成已加密、已认证的 Exchange artifact。
2. Sync 读取 READY outbox，校验 envelope 与 artifact hash。
3. Sync 将 opaque artifact 作为不可变对象上传到 Provider。
4. 远端下载后，Sync 写入 Velock Exchange inbox；只有可信 Velock receipt 返回后才推进 applied cursor。
5. 冲突由 Velock 业务 UI 处理，Sync 只负责打开控制面并验证 receipt。

## 安全要求

- Provider 凭据只保存安全存储引用。
- 外部 artifact 一律按不可信输入处理。
- 所有对象必须幂等、不可变、可重试、可恢复。
- 发布配置缺失时 fail closed。

## 非目标

其它非 Velock 数据集、Velock 业务明文合并和客户端内置 Provider secret。
