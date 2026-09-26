# Sync → 格间管理入口与旧批准页返回修复（2026-09-26）

## 用户现象与原因

Sync「恢复卡与已授权设备」原来复用了 `velock://open`，只唤醒格间而不指定页面。若格间停在旧批准页，就继续用旧 requestId 查找请求，显示「没有找到这次连接请求」。原跨 App 导航只去重栈顶相同请求，其他情况继续 push，产生残留批准页。

## 修复边界

- Sync 该管理行使用独立、可注入的 launcher，固定打开 `velock://sync-settings`，不携带 requestId，不发起连接或授权。原通用打开入口、真实配对入口保持不变。
- 格间 iOS 使用一个最新导航 inbox，Flutter 原子消费；通知不携带可重复回放的 URL。锁定时只保留最新有效意图，解锁后消费一次；管理意图可以替代旧配对意图。
- 外部导航使用 go 到规范云备份页，而非不断 push。每次外部进入指定新的 page key：即使重复同一个 URL，也移除旧页附着的 Navigator.push 详情/弹窗。普通内部页面保持原有 key。
- 外部进入的云备份/批准页没有上层时，返回设置；普通内部进入保留原返回栈。临时批准页成功打开 Sync 后清理；打开失败、旧异步回调或离开原页面时不清理新页面。
- 不改变请求验签、过期检查、授权、恢复卡、业务数据或远端内容；此修复不是同步/恢复完整性验收。

## 自动化与构建证据

产物目录：`../velock_sync-artifacts/work/management-link-20260926/`。

- Sync：`flutter test --no-pub --reporter expanded test/widgets test/features test/appearance test/providers/webdav test/sync_profiles test/dataset_adapters/velock_exchange test/sync_core/join_approval_applier_test.dart` — **434 passed**。
- 格间：路由、批准流程/面板、云备份面板、刷新生命周期、配对激活/控制面测试 — **94 passed**。
- 新路由回归覆盖：URI校验；锁定后最新意图/单次消费；多层旧批准页清除；同一/不同请求不叠加；相同管理 URL 清除手动 push 的详情；一次返回到设置。
- 两仓库变更文件 targeted `flutter analyze --no-pub`：**No issues found**。
- 两 App 的 iOS Simulator Debug 原生构建成功，已覆盖安装到现有 `iPhone 17 Pro Max`（`26CC5821-DEF4-47D3-978D-A11D7293AD61`），未清空模拟器数据。构建日志见产物目录。

## 人工式 GUI 验证

使用带 GUI 租约的 DeepSeek Computer Use，现有 Device Hub 模拟器：

1. Sync 格间备份详情 →「恢复卡与已授权设备」→ 格间锁屏，解锁后显示「云备份」，不显示旧批准/请求未找到。
2. 应用内「返回 设置」一次 → 设置，没有再露出旧批准页。
3. 再次从 Sync 打开同一入口 → 解锁后仍为云备份。
4. 打开「管理授权」（只查看授权状态与设备列表，不打开恢复卡），返回 Sync 再进入，解锁后实际回到「云备份」而非旧「管理授权」；再点一次应用内返回到设置。
5. 最后一轮曾因 GUI 输入未落到实际密码框触发「密码不能为空」；刷新 AX、正确聚焦输入后提交成功，未把锁屏覆盖层当作导航完成证据。非敏感截图：`final-route-cloud-backup-after-unlock.png`（主模型已查看）。

没有批准、拒绝、撤销、上传/恢复或 NAS 修改。锁屏仍属于格间原有安全行为，不为简化跳转而关闭。

## 协作说明

Sync 小范围修改先由统一 Qwen worker 执行，超时后主模型检查已有差异并补全/修正测试；格间路由测试 worker 超时且无文件产出后由主模型实现。未把超时当服务故障换模型。GUI 验证单独交给持有全局租约的 DeepSeek；主模型负责设计、原生/路由修复及差异/测试验收。

配套格间提交：`013df68`（`codex/simple-cloud-backup`）。
