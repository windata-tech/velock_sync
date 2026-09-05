# Velock Sync Protocol V1

## 范围

本协议定义 Velock 已加密 Exchange artifacts 的远端同步封装。协议不定义业务加密算法，也不授权 Velock Sync 访问密钥或明文。

## 不可变对象

- envelope；
- `operations.enc`；
- opaque blob；
- commit marker；
- receipt / acknowledgement；
- checkpoint。

对象通过 `vaultId`、`sourceDeviceId`、`sequence` 和 `batchId` 标识。相同逻辑键只能重放完全相同的内容；内容冲突必须拒绝。

## 完整性

Velock Sync 仅处理外层完整性：

- artifact 长度；
- SHA-256；
- envelope schema 和版本；
- producer identity、sequence 和前序引用；
- Velock 生成的签名与可信 receipt。

`operations.enc` 和 blob 的内部加密格式属于 `velock_codex`。Sync 不解析、解密或重新加密。

## 入站提交

Sync 下载并校验远端对象后，将其原样发布到 Velock Exchange inbox。只有 Velock 完成业务验证和事务应用并返回可信 receipt 后，Sync 才能推进 applied cursor。

## 安全失败

未知生产者、错误签名/hash、序列分叉、路径穿越、超限 artifact、错误版本或伪造 receipt 必须 fail closed。
