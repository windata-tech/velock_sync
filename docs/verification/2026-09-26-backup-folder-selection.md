# WebDAV / NAS 备份文件夹选择修复（2026-09-26）

## 用户阻塞与实际排查

用户在“开始格间备份”选择已有云位置并确认后收到 `provider.webdav.collection_not_writable` 提示。旧提示要求进入实际共享文件夹，但向导根本没有文件夹选择操作：只有一个连接时直接跳到最终确认，确认页仅显示连接名和服务器信息；WebDAV 设置的“子路径”只有手填文本框。

通过独立 Computer Use 只读核对了实际旧 UI，未执行最终开始备份、预检、保存连接或授权。不能仅由当前截图断言 NAS 的全部写权限正常；这次确认的是产品缺失可操作的目录选择步骤。此前 NAS 根入口 MKCOL 405 的隔离实验见 `cloud-backup-follow-up.md`。

## 新用户流程

```text
格间允许本次连接
  → 选择已有云位置 / 添加位置
  → WebDAV：打开共享文件夹，进入目标保存目录
  → 使用这个文件夹
  → 确认页显示完整目录
  → 用户确认开始
  → 对同一目录预检
  → 保存同一目录的格间配置并开始传输
```

- 浏览只发送 `PROPFIND Depth: 1`，不写入文件、不新建目录、不修改原连接。
- 可进入子目录、返回上级、取消；加载或读取失败时不能选择。401/403 不自动重试，不把读取失败当作空目录。
- 错误保留在向导中，并提供“重新选择文件夹”，不再仅显示短暂 toast。
- 保存位置包含账号/连接名称与实际目录；OAuth 保留其原有根目录选择流程，不套用 WebDAV 子路径。

## 路径一致性与兼容

`VelockSyncProfile.remoteRootSegments` 保存相对于原连接的 decoded 路径段，独立于通用连接。它是非秘密目录信息，不包含密码或 token。

- 不改写共用连接，不复制或复用新 credential ownership；普通同步任务和其他备份不被改到新的目录。
- profile 序列化、恢复、copyWith、join approval 重建均保留目录；旧配置没有该字段时仍使用原连接根。
- 预检、恢复查找、实际 Velock runner、远端清单扫描使用同一 scoped protocol。
- 重授权保留已选择目录，换连接重置目录；取消选择不预检、不创建 profile。
- 中文、空格、百分号、`#`、`?` 路径段使用 URI pathSegments 编码一次，拒绝空段、点路径、斜杠/反斜杠和控制字符。
- 浏览只接受同源、当前目录的直接子 collection，忽略文件、外源 href、跨层级条目、无有效 DAV 类型/状态的响应；不跟随认证重定向。
- 修复 `protocol.path` 为 `/` 或以 `/` 结尾的合法 collection 路径被错误拒绝的问题。

## 测试与构建

```sh
flutter test --no-pub --reporter expanded \
  test/features/cloud_backup \
  test/features/connection/remote_object_store_factory_test.dart \
  test/providers/webdav \
  test/sync_profiles \
  test/dataset_adapters/velock_exchange \
  test/sync_core/join_approval_applier_test.dart
```

**331 项通过**，改动范围 24 个 Dart 文件 analyze **No issues found**。包含浏览/取消/错误/重试、窄屏中英 2x 字体、真实路由返回、目录参数传递与恢复、签名授权到期、防覆盖与并发、scope 持久化与执行路径等回归。

组合回归 `backup_folder_destination_test.dart` 使用模拟 NAS 和生产 WebDAVObjectStore：根入口 MKCOL 405 时不 PUT；经真实浏览解析选中中文/空格/百分号子目录后，同一生产预检通过，写入全部位于选中目录，探针文件清理，原连接不变。这是 fixture 验收，不能冒充真实 NAS 成功。

XcodeBuildMCP 已成功构建、安装并启动 **Sync Debug simulator**，复用 `26CC5821-DEF4-47D3-978D-A11D7293AD61`（iPhone 17 Pro Max），未擦除/新建模拟器。实际安装路径为 `../velock_sync-artifacts/DerivedData/Build/Products/Debug-iphonesimulator/Runner.app`。

## 真实设备验收边界

安装后 Computer Use 实际打开 Sync→开始备份，当前停在“1 · 连接格间”，没有可复用的有效批准，故没有进入新的真实 NAS 列表。已请用户自行允许新连接后继续验证。没有代用户批准、输入密码、发送新配对请求、改连接、执行真实 NAS 预检或业务传输。

**本轮不能宣称真实 NAS 目录列表、预检、完整备份/恢复已全部通过。** 之前四并发 401 未重试或掩盖；全量快照/迁移/恢复原有未完成边界不变。

代码与测试经统一 CLI worker 分工，GUI 经带锁的 DeepSeek Computer Use 分工，主模型负责集成、纠正测试 fixture、实际测试和安装。所有日志位于项目外 `../velock_sync-artifacts/work/destination-folder-20260926/`：`regression-final.txt`、`analyze-final.txt`、`build.txt`、`install.txt`、`launch.txt`、worker reports。

附：额外只读审查 worker 在本轮时限内退出（124），未返回可用审查结论；未切换第三个模型。主模型接管复核 scope 的序列化、真实 runner/预检/清单调用链、URI 编码、DAV href 限界与授权到期检查。不得把这次超时记录成独立审查通过。
