# 历史缺失处理入口与详情页导航（2026-09-26）

## 用户反馈

1. 「有一件事需要你处理 → 查看并处理」进入普通管理页，用户不知道应该改哪项。
2. 配置后的备份详情没有返回按钮，也不包含首页底部导航，无法离开。

## 原因与本次改动

- 历史缺失原来与通用管理共用 `BackupAction.manage`。新增精确匹配 `remote.velock_history_incomplete` 的 `reviewHistory` 操作；首页和详情均进入专用说明页，而不是后台策略/断连页面。授权、冲突、运行中等原有优先级不变。
- 顶部明确为「云端备份不完整 / 查看原因和下一步」。说明页展示缺少记录、当前选定保存路径（连接根路径 + profile远端子目录）、只读浏览入口和找不到旧备份时的能力限制。连接名称加「连接：」前缀，避免名字叫“新建连接”时被误认为按钮。
- 查看说明不运行同步、不重新授权、不改状态、不改目录、不删除任何记录。浏览按钮明确只用于核对，从连接起始目录打开，不假装已更换位置或修好备份。缺失连接/无效配置不伪装为根目录。
- **底层历史缺失仍然存在**：本轮未实现“将本机全部业务数据重建为完整新备份”的上传/恢复流程，也未放宽历史完整性门禁。UI明确说明新建空目录和重新授权不能补齐旧记录，不把失败改成成功。
- 配置完成时原来 `go('/sync-profiles/:id')` 替换了整棵导航栈，但详情在 shell 外，且默认返回按钮只在有上一页时显示。现在成功结束配置后 `go('/')`（实际落到 `/dashboard`），回带三入口导航的首页。
- 详情加载、错误、已删除及正常状态均显式提供统一 `AppBackButton`；有历史就 pop，无历史则回对应产品首页（格间 `/dashboard`、普通文件 `/files`）。系统返回采用相同兜底，详情子页仍先返回详情。

## 自动化与构建

产物：`../velock_sync-artifacts/work/history-help-20260926/`。

- 最终相关回归 **452 passed**：
  `flutter test --no-pub --reporter expanded test/widgets test/features test/appearance test/providers/webdav test/sync_profiles test/dataset_adapters/velock_exchange test/sync_core/join_approval_applier_test.dart`
- 定向静态分析 **No issues found**。
- 新说明页6项widget测试：真实详情CTA、完整路径、无隐式run/状态修改、真实连接导航、旧备份缺失提示、缺失连接、中英文1.8倍字号。大字号测试断言提示实际打开，不把未命中点击当成功。
- 新导航8项真实GoRouter回归：iOS/Android直达不存在的详情、两产品直达详情、普通push返回、Android系统返回。独立go无历史条件由此验证，不靠重建真实备份配置。
- Sync iOS Simulator Debug构建成功，覆盖安装至现有iPhone17ProMax（`26CC5821-DEF4-47D3-978D-A11D7293AD61`），没有抹除模拟器。

## GUI 实测

由持有GUI租约的DeepSeek操作，主模型复核截图：

- 首页 → 备份详情与管理：顶部单chevron返回可见。
- 详情 → 查看原因和下一步：进入「备份为什么停止」而非管理；保存位置包含选定子目录。
- 说明页返回 → 详情，仍为不完整；详情返回 → 首页。
- 文件同步 → 设置 → 格间三个底部入口可切换，最终停在格间首页。
- 「原来的备份找不到了？」打开明确的只读能力限制说明；未在GUI中手动启动备份/恢复或改设置、断连、删除、批准，也未为本轮验证进入NAS浏览。正常App已有后台策略未修改。

截图：`navigation-final-detail-back.png`、`navigation-final-home-tabs.png`；前一轮说明页截图 `backup-incomplete-help.png`（连接名称前缀为后续小修前）。

## 协作

Qwen worker完成状态映射边界测试；其Flutter执行被SDK沙箱写权限拦截后由主模型运行。后续导航测试worker超时未产出，主模型确认无修改后接管。GUI两轮由DeepSeek串行完成；均关闭worker后释放租约。
