# Velock Sync V1 完成规格

Velock Sync V1 包含两类共享同一传输核心的数据集：

- `velock-managed`：格间零知识远程备份；
- `selected-folder`：用户选择文件夹的通用双向同步。

## 必须满足

### 公共要求

- 前台、后台和手动入口复用同一 `SyncProfileDispatcher`；
- WebDAV、Google Drive、OneDrive 使用统一 `RemoteObjectStore`；
- 进程退出、断网和重复执行后可恢复；
- 未完成下载不得暴露给数据源；
- 日志和诊断不包含凭据、密钥、恢复口令或业务明文；
- 未知或损坏的 Profile 保持 isolated，不静默删除。

### 格间备份

- Sync 不读取格间明文、数据库或密钥；
- 只处理 opaque Exchange artifacts；
- 未收到可信格间 receipt 前不推进入站已应用游标；
- 删除保护、Retention Manifest、checkpoint、活跃设备 ACK 和引用检查共同约束 GC；
- Sync 不提供格间内容时间线或文件级恢复；
- 换机与重装通过同一恢复链路完成。

### 文件夹同步

- 目录授权只保存平台稳定引用；
- Generic Vault root key 和设备签名私钥只保存平台安全存储；
- 支持新增、修改、重命名、移动、删除、tombstone 和断点恢复；
- 首次发现大规模删除时执行保护确认；
- 支持保留本地、远端或双方三种冲突策略；
- 支持导出和导入带恢复口令的恢复材料；
- Android SAF、iOS security-scoped bookmark 和桌面路径均通过统一存储接口。

## 发布检查

- `flutter analyze` 无问题；
- 全量单元/组件测试通过；
- iOS/Android 至少各完成一次真机目录授权和同步冒烟；
- 至少完成一次新设备恢复演练；
- Provider 真实账号端到端和故障注入通过；
- 发布构建的 entitlement、签名、后台任务和凭据 fail-closed 配置全部验证。
