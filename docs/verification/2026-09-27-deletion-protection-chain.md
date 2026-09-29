# 删除保护与暂存空间：链子断在哪、改了什么（2026-09-27）

## 用户反馈

现场截图（iPhone 17 Pro Max 模拟器，设置页）：删除保护卡写着 `已开启`、`最近清理 刚刚`、
`等待确认 0 台设备`、`活跃设备 0 台`，脚注却是「尚未获得可信检查点，本次安全清理已跳过」；
下面暂存空间永远 `0 B / 0 个批次 · 0 个文件`。用户问：**「这个删除保护和暂存空间现在还真的生效吗？业务逻辑是什么」**。

## 现场证据（先查数据，再改代码）

模拟器 App 容器 `state.db`：

| 事实 | 值 |
| --- | --- |
| `garbage_collection_runs` 总行数 | 97 |
| `completed`（真正清理过） | **0** |
| `failed` | 0 |
| `skipped / no-candidates` | 60（当前配置 51 次，9-26 16:38 → 9-27 00:13） |
| `skipped / checkpoint-missing` | 37（当前配置 23 次，9-27 00:54 → 10:16 连续） |
| `no-candidates` 行的真实计数 | `active_device_count=1`、`checkpoint_id=v1-88298f…` |

App Group（格间侧）里的证据说明**不是格间没干活**：

- `Control/SyncCheckpoint/<be112799…>/current.json`（10:11 更新，checkpointId `v1-54c5db05…`，
  `coveredSequences={producer:7}`）—— 用 descriptor 里的 Ed25519 公钥离线验签**通过**；
- `gc-candidates.json`（10:18）：1 条候选，seq 5 墓碑，`retentionHoldUntil=2026-10-27`，
  引用一份已上传的 retention manifest；
- 同一时刻 10:04 的 blob/batch 上传在 `transfer_jobs` 里全是 `completed`：该远端位置可写。

`<support>/staging/` 下只有一个**空的** profile 目录（旧版加密 selected-folder 的 ID），
与卡片上的 `0 B / 0 个批次 · 0 个文件` 完全一致。

## 根因：两个「从未创建过的目录」被当成致命/致命性跳过

9-26 那批 `no-candidates` 证明整条链当时是通的。断点在 9-27 00:13 → 00:54 之间换上的构建里
（对应 commit `6f871317` 把 WebDAV `list()` 的 404 从「当空目录」改成抛
`RemoteObjectNotFoundException`）。

1. **格间的 checkpoint 没有 `parts/`**：适配器恒返回 `parts: const []`，发布器也就从不创建
   `checkpoints/<id>/parts/`。而恢复端**无条件**去列这个目录；WebDAV 对不存在的集合回 404 →
   抛异常 → `recoverLatest` 把这个候选当「不可用」跳过。结果：每个候选都被跳过，
   `checkpointId` 永远为 null → 每次 GC 都记 `checkpoint-missing`，**候选清单根本不会被读**。
2. **没有 ACK 就没有 `acknowledgements/` 集合**：`RemoteAcknowledgementReader` 无条件列该前缀，
   单设备 vault 从来没有 ACK，于是即使修好第 1 条，GC 也会在 `gc-error` 上失败。

两处都属于「把『集合从未创建』当成『读不到』」。与明文镜像那次不同：**这里的方向是 fail-closed**
（读不到 checkpoint/ACK 只会让清理继续跳过，不会授权删除），所以「从未创建 = 空」是正确语义。

## 修复

- 新增可选能力 `CheckpointWithoutPartsDatasetAdapter`（`lib/sync_core/contracts/sync_dataset_adapter.dart`）：
  声明「本数据集的 checkpoint 不带 parts」的数据集，恢复时**不再探测** `parts/` 集合。
  格间适配器实现它；带 parts 的数据集保持原有严格行为（parts 目录消失 → 仍然跳过该候选，不放宽）。
- `SyncCheckpointRecovery._committedCandidates`：`checkpoints/` 集合 404（还没发布过 checkpoint）
  = 「没有检查点」，返回空结果而不是让整次同步运行失败。
- `RemoteAcknowledgementReader.read`：`acknowledgements/` 集合 404 = 「谁都没确认过」，
  与空集合同一个 GC 决策（只会阻止删除，不会授权删除）。
- 未放宽：签名/覆盖/commit 可见性/保留清单/活跃设备 ACK/引用检查全部不变；
  checkpoint 发布失败仍然只是「本次没有检查点」。

## 界面口径（同一轮修掉）

- 徽章不再写死 `已开启`：没有可信检查点时显示 **尚未生效**（`AppTone.attention` + 时钟图标）。
- `最近清理` 只显示**真的回收过对象**（`state == 'completed'` 且 `deletedObjectCount > 0`）的时间；
  跳过/失败/「完成了检查但保留期没到、一个都没删」都显示 `尚未执行`
  （跳过也会写 `completed_at`，旧逻辑因此刚跳完就显示「刚刚」；设备实测 10:37 那次正是
  `completed / 候选 1 / 可清理 0 / 删除 0`）。
- `等待确认` / `活跃设备` 在没跑到那一步时显示 **尚未统计**，不再拿 DB 初始值 `0 台设备` 冒充事实。
- 脚注第一句按真实状态分派，跳过时写成「上次检查：<相对时间>。尚未获得可信检查点，本次安全清理已跳过。」。
- **删除「暂存空间」卡片**：唯一写入方（旧版加密 selected-folder）已从界面与后台调度中淘汰，
  格间只用该目录做剩余空间预检，明文同步不经过它；卡片永远 `0 B`，`清理` 是空操作。
  `StagingSpaceManager` / `SyncSettingsService.cleanupStaging` / 脱敏诊断里的暂存用量保留
  （诊断仍要报告用量；旧版页面代码路径未动）。

## 验证

- `test/sync_core/sync_checkpoint_recovery_test.dart`（6 项）：新增「无 parts 的 checkpoint 在
  404 集合的 provider 上仍可恢复」「带 parts 的数据集在 parts 目录消失时仍跳过该候选」
  「第一个 checkpoint 发布前没有检查点」。
- `test/sync_core/sync_profile_runner_test.dart`：新增端到端回归
  「collects garbage for a partless checkpoint on a single-device vault」——
  单设备、无 ACK、无 parts、provider 对未创建集合回 404，GC 真的跑完并删掉 1 个对象，
  诊断行是 `completed`（修之前这一行必然是 `checkpoint-missing`）。
- `test/sync_core/remote_acknowledgement_reader_test.dart`：新增「acknowledgements 集合从未创建」。
- `test/features/sync_profiles/sync_settings_deletion_protection_test.dart`：新增 `尚未生效 /
  尚未执行 / 尚未统计×2 / 上次检查：…` 两条状态测试，并在原测试里断言暂存空间卡片与
  `cleanup-staging` 按钮都不存在。
- `test/features/sync_profiles/sync_settings_english_test.dart`：英文页仍无中文，且不再出现
  `Staging space` 与旧暂存卡文案。
- `test/features/sync_profiles/sync_settings_deletion_protection_test.dart` 另加「completed 但 0 删除」
  一条（设备真实状态）。
- 新增 `test/features/sync_profiles/deletion_protection_visual_qa_test.dart`（真实 CJK 字体渲染三种状态：
  尚未生效 / 已开启但没删任何东西 / 已开启且真的清理过，输出到
  `ui_test_results/deletion-protection-20260927/`）。
- `ui_test_harness/CrossAppUITests/CrossAppUITests.swift` 的
  `testDeletionProtectionSettingsVisible` 不再断言 `删除保护：已开启`（状态相关），
  改为断言卡片与三行标签可见（该 XCUITest 本轮**未执行**，只做了静态修改）。

## 设备实测（同一台 iPhone 17 Pro Max 模拟器 + 用户真实 NAS）

修好后重新构建安装 Debug 包并启动，**第一条** GC 记录（10:37）就从 `checkpoint-missing` 变成：

| state | checkpoint_id | 活跃设备 | 等待确认 | 候选 | 可清理 | 已删除 |
| --- | --- | --- | --- | --- | --- | --- |
| **completed** | `v1-54c5db05cb5c7ea2ee875505e1cee346`（真的从远端恢复） | 1 | 0 | 1 | 0 | 0 |

即：检查点恢复成功、候选清单真的被读到（格间 `gc-candidates.json` 那条 seq 5 墓碑）、
活跃设备数第一次是**测量值 1**（不是初始值 0）；删除被保留期正确扣下（`eligible=0`）。
这同时证明更早的构建一直在正常**发布** checkpoint（远端确实有 `checkpoint.commit`），
断的只是恢复读取。

## 边界（不要当成已完成的事实）

- 真实 NAS 路径已由上面这次设备实测覆盖（App 内 `parcool` 账号的 `USB_HDD_8T/111` scope）；
  仓库里的 `webdav` 账号看不到该 scope，本轮只用它核对了「同一台 NAS/FN 主机对不存在集合回 404」。
- 即使链子修好，当前唯一候选（seq 5 墓碑，`retentionHoldUntil=2026-10-27`）也要到
  **约 2026-12-03**（保留 30 天 + 缓冲 7 天 + hold 到期）才可能满足 cutoff，在那之前
  `no-candidates` 之外仍会是「候选不满足条件」，属于设计如此，不是故障。
- 仍不在本轮范围：下载引擎按 producer 列 `commits/` 前缀时遇到「远端 producer 还没有提交」
  的同类 404（既有严格行为，涉及历史完整性门禁，未动）。
