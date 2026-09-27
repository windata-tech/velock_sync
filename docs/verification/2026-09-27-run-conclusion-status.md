# 同步记录状态口径：0 对象的运行不再叫“已完成”（2026-09-27）

## 用户反馈

现场截图：`传输记录` 里一条运行记录打开后是 `同步记录 · 已完成`，可下面写着
`上传对象 0 个 · 0 B`、`恢复对象 0 个 · 0 B`、`传输明细：本次没有传输任何对象`。
用户原话：**「我感觉这个0对象的，不应该叫已完成，你给我想一个新的状态呢」**。

## 规则（新增）

- 存储的运行状态不改：`sync_runs.state` 仍是 `running` / `completed` / `failed`，
  所有调度、历史完整性、恢复门禁的判断都不受影响；只改**用户读到的那句话**。
- 一条运行到底移动过哪些对象，由该运行自己的时间窗决定：
  `runWindowTransfers(run, history)`（`lib/features/sync_profiles/model/sync_run_outcome.dart`）。
  这与运行记录弹层里“上传对象/恢复对象/传输明细”用的是同一份列表，
  所以**状态永远不会和它下面的计数打架**。
- 结论用词（`syncRunConclusionLabel`）：
  - `running` → 运行中
  - `failed` → 失败
  - `completed` 且本次 0 个对象 → **无需传输**
  - `completed` 且本次有对象 → 已完成
  - 未知状态原样显示，不被抹平成任何结论
- 不夸大：`无需传输` 只说“这次运行没有可传的对象”，不等于“云端已经是全部最新数据”
  （格间还没发布新批次时也会是这次结果）。这一点沿用了既有的“不得表述为完整备份”边界。
- English：`Nothing to transfer` / `Completed` / `Running` / `Failed`（`syncText` 双语文案）。

## 改动位置

- 新增 `lib/features/sync_profiles/model/sync_run_outcome.dart`。
- `lib/features/sync_profiles/ui/sync_profile_workspace_shared.dart`：
  运行记录弹层的标题与“结果”行改用新结论；删除了旧的 `runStateLabel`
  （它只会把 `completed` 一律说成“已完成”，没有对象信息可用，留着就会再犯同样的错）。
- `lib/features/sync_profiles/ui/sync_profile_detail.dart`：
  `传输记录` 列表每一行、以及概览页“传输记录”那行的副标题都用同一结论。
- 未改：活动页 `最近同步`（它的用词是“同步完成/同步失败”，且不显示对象计数，
  要按同样规则就得再补一条跨配置的传输历史查询，本轮没有做）。
  首页状态卡的“上次备份已完成”同样未改（它说的是“上一次运行结束了”，且带时间）。

## 验证

- 新增 `test/features/sync_profiles/run_conclusion_test.dart`：9 项。
  纯函数覆盖时间窗（窗口前/窗口后/其它配置/未完成）、四种结论与未知状态；
  widget 覆盖空运行弹层（`同步记录 · 无需传输`、`0 个 · 0 B`、且**全屏找不到“已完成”**）、
  有对象的运行仍是 `已完成 · 1 个 · 296 B`、英文弹层不回落中文；
  再用真实内存数据库跑完整页面：概览副标题、列表行、点击后的弹层三处口径一致。
- 新增 `test/features/sync_profiles/run_conclusion_visual_qa_test.dart`（真实 CJK 字体渲染，
  未设 `BACKUP_UI_FONT` / `BACKUP_UI_SCREENSHOT_DIR` 时只断言、不写文件）。
- `flutter analyze`：No issues found。`flutter test`：见日志（含新增两个文件）。
- 真实字体渲染证据 `ui_test_results/run-conclusion-20260927/`：
  `02-transfer-history.png`（列表：无需传输 / 失败 / 已完成）、
  `03-run-record-nothing-to-transfer.png`（弹层：`同步记录 · 无需传输`）。
  这两张是 widget + 内存 fixture 的渲染，不是模拟器/真机截图。

## 边界

- 本轮只改文案口径，没有改数据库 schema、runner 写入的状态、也没有新增“本次运行移动了几个对象”
  的持久字段；因此老记录的归属仍按完成时间窗推断（与弹层计数同一规则），
  同一对象被后续运行重新下载时，旧运行可能显示为“无需传输”。
- 没有在真实设备/真实 NAS 上复跑同步；本改动不涉及传输逻辑。
