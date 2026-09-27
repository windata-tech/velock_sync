# 同步重复触发与运行状态刷新（2026-09-26）

## 现场证据与边界

用户从格间新增数据后回到 Sync，点击同步看到短暂失败 Toast，详情长期显示“正在传输，请稍候”。只读检查当前模拟器数据库：对应最近任务在 17:20:39 启动、17:20:44 已 completed，无错误且无残留锁；实际配置子目录仍为 `USB_HDD_8T/111`。这证明页面残留运行状态，不能证明用户刚新增的业务记录已完整备份。没有捕获闪过的 Toast 原文，不把并发异常推断写成已证实的现场错误。

代码确认前台自动触发与手动触发使用不同 dispatcher 实例，旧的实例内去重无法合并两者；目录保护锁的 StateError 又会将重复触发显示成同步失败。详情只读一次状态，没有持续观察另一任务结束。

## 修复

- 同一 isolate 的 dispatcher 按数据库文件身份 + profile ID 共享进行中的 Future；不同内存数据库隔离，完成后释放映射。
- 跨 isolate/目录锁忙返回 SyncRunBusyException，dispatcher 将其作为未重复启动处理，不伪造失败记录；界面明确“同步已在进行中，无需重复启动”。不撤销锁，不自动重试。
- 首页与详情在已有任务 running 时每秒重新读取本地状态，任务终态停止轮询；回到前台刷新；销毁取消 Timer，generation 防止旧请求安排新轮询。刷新保留原正文而非整页 loading。
- 真实失败采用平台自适应确认弹窗，保持到用户确认，不能点击遮罩消失；抛异常和返回失败均接入。展示结果前解除本地 running 标记、刷新持久状态。
- 选原备份文件夹仍仅保存目录，不自动同步。未改历史连续性、签名、授权、恢复或数据完成门禁。

## 验证

- `flutter test test/features/cloud_backup test/widgets test/features/connection test/sync_profiles test/background test/dataset_adapters/velock_exchange`：437 项通过。
- 新回归涵盖独立 dispatcher/数据库句柄共用一次执行、不同数据库隔离、busy 不记失败；首页/详情后台 running→completed/failed 无点击刷新；iOS/Android 两种结果入口与异常弹窗 6 秒后仍可读、遮罩不关闭、明确确认关闭，忙状态不报失败。
- 10 个本轮代码/测试文件 analyze 无问题；git diff --check 通过。
- XcodeBuildMCP 在既有 iPhone 17 Pro Max 模拟器构建、安装并启动 Debug 新版成功，保留原有应用数据；未做真实 NAS 内容级 E2E。
- 日志：项目外 `../velock_sync-artifacts/work/stuck-sync/`（regression.log、final-analyze.log、build.log）。
- worker 在受限环境无法直接执行 Flutter SDK 测试，保留其指定范围补丁，由主模型接管审查、集成及实际回归。没有扩大 worker 权限。

本轮未主动点击真实 NAS 同步、未删除/重置数据；测试为受控逻辑/widget 回归，不宣称新增业务项完整备份/恢复已验收。
