# Velock Sync V1 完成规格

Velock Sync V1 只包含同步职责：Velock 业务数据由 `velock_codex` 负责加密并生成 Exchange artifacts，本项目负责传输、重试、恢复、游标和远端 Provider。

## 必须满足

- Velock Sync 不读取 Velock 明文、数据库或密钥；
- 不生成、保存或恢复 Velock 数据加密密钥；
- 不对 `operations.enc`、密文 blob 或其它 Velock artifacts 做二次加密；
- 所有前台/后台入口复用同一 Sync Core 和 Profile Dispatcher；
- WebDAV、Google Drive、OneDrive 通过统一 RemoteObjectStore 契约；
- 未收到可信 Velock receipt 前，不推进入站已应用游标；
- 发布构建中的 App Group、签名和配对配置必须 fail closed。

## 不属于 V1

- 其它非 Velock 数据集；
- Velock 业务冲突的明文合并；
- 百度/阿里云盘的未授权 Token Broker 集成。
