# Velock Sync 产品需求

Velock Sync 是 Velock（格间）的独立同步伴侣，只负责在设备与远端 Provider 之间传输同步数据。

## 职责边界

- `velock_codex` 负责业务数据、数据库事务、加密、解密、签名和生成 Exchange artifacts。
- `velock_sync` 只负责发现/配对、读取和写入 Exchange、远端对象传输、游标、重试、恢复和冲突流程编排。
- Velock Sync 不读取 Velock 明文、数据库、master key 或 sync key，也不对 Velock artifacts 做二次加密。

## V1 范围

- Velock Exchange App Group / 平台桥接；
- WebDAV、Google Drive、OneDrive 等远端 Provider；
- 增量双向同步、不可变对象、幂等、断点恢复、后台调度和错误分类；
- 将 `velock_codex` 已生成的 `operations.enc`、密文 blob、envelope、签名和 receipt 作为 opaque 数据处理；
- 冲突交由 Velock 业务侧处理，Sync 仅验证并记录可信 receipt。

## 非目标

- 在 velock_sync 中创建或保存 Velock 数据加密密钥；
- 其它非 Velock 数据集；
- 读取、解密或合并 Velock 业务内容；
- 在客户端内置第三方 Provider secret。

## 验收原则

所有同步入口复用同一 Sync Core 和 Profile Dispatcher。任何 Velock artifact 在未经可信 Velock receipt 确认前，都不得被视为已应用。
