# Velock Sync UI 统一设计规格（v1）

> 状态：待实施基线（本文档先于任何代码改动落地）
> 适用范围：`lib/appearance/`、`lib/widgets/`、`lib/features/**/ui/` 全部可见界面
> 审计方式：模拟器冷启动 + Computer Use 逐页走查（2026-09-12），截图存于 `ui_audit/redesign/`

---

## 1. 目标

把 Velock Sync 从「若干次局部修补拼起来的页面集合」收敛成**一套系统**：

1. **单一设计语言**：一套 token、一套组件、一套文案规则，iOS 优先、Material 等价可用。
2. **可预期的信息架构**：每页都有身份（标题）、每个区域都有层级、每个操作只有一处入口。
3. **可信的状态表达**：颜色/图标/文案三者在语义上永不冲突（尤其「正常」与「需处理」）。
4. **无死胡同**：空状态、错误态、被阻塞态都给出下一步可执行动作。
5. **用户看不到内部标识**：UUID、错误码、异常类名一律不进主文案。

非目标：不改变同步协议、数据库结构、Provider 行为、路由 path；不引入新的重量级 UI 依赖。

---

## 2. 现状审计（证据驱动）

截图：`ui_audit/redesign/01-dashboard.png` … `20-activity-bottom.png`

### P0 — 破坏整体感的问题

| # | 问题 | 证据 | 根因 |
|---|------|------|------|
| 1 | **所有页面没有标题**，二级页只有一个返回箭头 | `01/02/03/05/06/07/08/09/10/12/14/16` 全部 | `WDAppBar(showTitle:false)` 默认值 + `AdaptiveSliverScaffold(showTitle:false)` 调用 |
| 2 | **滚动内容与状态栏/灵动岛重叠** | `05b-settings-keys`： “删除保护” 与时钟同高 | 顶部无固定导航栏/毛玻璃背景，内容直接滚到状态栏下 |
| 3 | **语义色冲突**：正向的「已启用」与警告的「需处理」同色（米黄） | `01-dashboard`、`12-profile-overview` | `_profileStateColor(active)` 复用了 warning 色 |
| 4 | **泄露内部标识**：`配置 70fa13b9-238…`、`sync.unexpected`、`OAuthClientRegistrationMissingException`、`permanent` | `03-activity`、`14-profile-history`、`10-oauth-google`、`17-history-detail` | 直接渲染 `profileId` 截断与 `errorCode` 原文 |
| 5 | **重复操作**：配置详情同时有「立即同步」行与大号「立即同步」按钮 | `12-profile-overview` | 两个来源的 action 未收敛 |
| 6 | **死胡同**：已有配置时“新建同步”只显示一段说明，无任何按钮 | `18-wizard-step1` | 阻塞分支缺少 action |
| 7 | **句中截断**：说明文字被 `maxLines` 硬切（“…不会仅因长…”、“…跳过…”、“…Veloc…”） | `05b-settings-keys` | 单行 ellipsis 用于长解释文本 |

### P1 — 一致性与细节

| # | 问题 | 证据 |
|---|------|------|
| 8 | 日期/单位格式不统一：`2026-09-12 09:02`、`50.0 MiB`，无相对时间 | `03/05/17` |
| 9 | 表单值列不对齐（“服务器地址” 的输入起点比 “端口/用户名” 早 ~10pt）；placeholder 风格混用「例如：」/「请输入」 | `08-webdav` |
| 10 | 组件语言混用：iOS 分组列表 vs Material 全宽填充按钮、Material 对话框、OAuth 页嵌套卡片 + 边框输入框 | `10-oauth-google`、`12-profile-overview`、`17-history-detail` |
| 11 | 空状态图标重复：待处理与冲突都用同一个对勾 | `13-profile-pending`、`15-profile-conflicts` |
| 12 | 元数据语义混乱：概览卡把「数据集名 / 运行结果 / 开关状态」塞进同一行三个数字位 | `12-profile-overview`、`01-dashboard` |
| 13 | 图标语义：Google Drive 与 OneDrive 同为云朵；WebDAV 用文字 “DAV” 充当图标 | `07-protocols` |
| 14 | 连接详情错误态无连接名上下文，主操作只有「重试」，缺少「编辑连接」 | `11-connection-detail` |
| 15 | 二级页 nav 动作权重相同（“说明 / 保存” 同色同粗），保存无启用/禁用语义 | `08-webdav`、`10-oauth-google` |
| 16 | 帮助页 17pt 正文长墙，与其它页 13pt 说明风格割裂 | `09-help` |
| 17 | 状态徽章与行内快捷图标挤在一起（徽章 + ⚠️ + 同步 + ⋯ 四件套），标题被压到只剩 “Velock E2E R…” | `01-dashboard` |

---

## 3. 设计原则（做取舍时的判据）

1. **一屏一主操作**：主操作在底部安全区（大按钮）或 nav 右侧；次要操作降级为文字按钮/行内菜单。
2. **状态先于细节**：先回答「现在有没有问题」，再回答「细节数字是多少」。
3. **颜色即语义**：绿=正常/成功，橙=需关注，红=失败/危险，蓝=可交互，灰=中性/不可用。同色不得表示相反含义。
4. **系统优先，品牌点缀**：结构、控件、动效沿用 iOS 习惯；品牌蓝只用于可交互元素与选中态。
5. **可执行**：任何“没有内容/出错/被阻塞”的页面，必须给出一个下一步按钮。
6. **不截断关键信息**：标题 1 行 + 副标题最多 2 行；解释性文本一律换行完整显示。
7. **技术细节后置**：错误信息用中文结论 + 可选「技术详情」，代码/类名只在详情里出现。
8. **可访问**：点击区 ≥44pt，文本对比 ≥4.5:1，状态同时用颜色+图标+文字表达。

---

## 4. 设计系统（Tokens）

文件：`lib/appearance/design_tokens.dart`（扩展），`lib/appearance/theme.dart`（映射）

### 4.1 颜色

```
品牌      brand        #3F63D9    dark #9DB2FF
成功      success      #1E8E4E    dark #4CD07D
关注      warning      #B26A00    dark #FFB95E
危险      danger       #C62828    dark #FF6B6B
中性      neutral      label2     (secondaryLabel)
表面      page / groupedSurface / elevatedSurface
分隔线    separator @7~8% alpha
```

* 药丸/徽章：底色 = 语义色 12%，文字 = 语义色（浅色下加深至 ≥4.5:1）。
* **正向状态（已启用/已连接/已完成）用 success 或 neutral，禁止用 warning。**

### 4.2 字体（pt / lineHeight）

| 角色 | 规格 | 用途 |
|---|---|---|
| largeTitle | 30 / 36, w700 | 顶级 Tab 大标题 |
| navTitle | 17 / 22, w600 | 导航栏标题 |
| cardTitle | 20 / 25, w600 | 卡片主标题 |
| rowTitle | 17 / 22, w400–600 | 列表行标题 |
| rowSubtitle | 13 / 18, w400 | 列表行副标题 |
| body | 15 / 22 | 正文/帮助 |
| footnote | 13 / 18 | 区段脚注 |
| caption | 12 / 16, w600 | 区段头、徽章 |
| metric | 28 / 32, w700 | 数字指标 |
| mono | 13 / 18 | 只用于技术详情 |

### 4.3 间距 / 圆角 / 动效

* 间距：4 基（2/4/8/12/16/20/24/32）；页面左右 16；卡片内 16；行内上下 12；区块间距 24；区段头与卡片 8。
* 圆角：卡片 16，控件 12，药丸 999，底部弹层 20。
* 阴影：卡片不使用阴影（仅 0.5pt 描边）；弹层/浮层使用系统阴影。
* 动效：标准 200ms、快速 150ms、弹层 300ms，曲线 easeOutCubic。

### 4.4 图标

* iOS 用 `CupertinoIcons`，Material 用 `Icons`，统一走 `adaptiveIcon()`。
* 徽章容器 32pt（紧凑）/36pt（标准），圆角 10，底色为语义色 12%。
* 语义映射：WebDAV=`network`、Google Drive=`folder.badge.plus`、OneDrive=`cloud`、百度=`cloud.fill`、冲突=`exclamationmark.triangle`、待处理=`tray.and.arrow.down`、完成=`checkmark`。

---

## 5. 组件契约（`lib/widgets/app_components.dart` 新增，`adaptive_widgets.dart` 收敛）

| 组件 | 关键参数 | 规则 |
|---|---|---|
| `AppScaffold` | `title, largeTitle?, actions[], primaryAction?, onRefresh?, slivers/body` | 顶级 Tab 用大标题；二级页 inline 标题；滚动时导航栏有毛玻璃底 |
| `AppSection` | `header?, headerAction?, footer?, children[]` | 统一 header/footer 字号与间距；footer 完整换行 |
| `AppRow` | `leading?, title, subtitle?, subtitleMaxLines=2, trailing?, onTap?, chevron?` | 行高 ≥ 52；次级信息最多 2 行；`enabled` 用透明度 0.45 |
| `AppStatusPill` | `label, tone` | tone ∈ {ok, attention, danger, neutral, brand}；禁止直接传裸 Color |
| `AppNotice` | `tone, title, message?, action?` | 卡片内联提示；危险/关注/信息三态；带图标 |
| `AppMetricGrid` | `metrics[{value,label,tone}]` | 指标数字与标签成对；关注指标着色 |
| `AppPrimaryButton` / `AppSecondaryButton` | `label, onPressed, enabled` | 主按钮高度 50，圆角 12；禁用态 38% 透明 |
| `AppEmptyState` | `icon, title, message, primary?, secondary?` | 每种空状态用不同图标；至少一个动作（可为“查看帮助”） |
| `AppErrorView` | `title, message, retry, secondary?, details?` | 主文案中文结论；`details` 折叠在「技术详情」 |
| `AppDetailSheet` | `title, rows[], closeLabel` | 底部弹层（Cupertino modal / Material bottom sheet），行内标签列宽固定 96 |
| `AppFormRow` | `label, value/child, placeholder?, errorText?, keyboardType` | 标签列宽固定；值列左对齐同一起点；错误文案在行下方红色 |
| `AppSegmentedTabs` | `tabs[], index, onChanged` | ≥5 段时允许横向滚动；选中段用 surface + 阴影 |
| `AppMenu` | `items[], onSelected` | 危险项红色；与 `showCupertinoModalPopup` 行为一致 |

### 5.1 格式化工具（`lib/widgets/app_format.dart`）

* `formatRelativeTime(DateTime)`：<1 分钟「刚刚」，<1 小时「x 分钟前」，今天「今天 HH:mm」，昨天「昨天 HH:mm」，本年内「M月d日 HH:mm」，跨年「yyyy年M月d日」。
* `formatBytes(int)`：B/KB/MB/GB，1024 进制，最多 1 位小数，不显示 `.0`。
* `humanizeErrorCode(String?)` → 中文结论；`technicalErrorDetail` 保留原文用于详情。
* `profileDisplayName(profileId)`：查仓储拿 `displayName`，拿不到时显示「同步配置」而非 UUID。

---

## 6. 文案规范

* 结论句在前，技术细节在后：「无法连接到远端服务器」+「服务器拒绝了连接…」+ 折叠「技术详情」。
* 固定状态词：已启用 / 已暂停 / 需处理 / 已连接 / 未连接 / 同步中 / 已完成 / 失败 / 可运行 / 后台开启。
* 不出现：类名、异常名、协议码、UUID、`permanent`、`sync.unexpected`、`unknown`。
* 占位提示统一：「例如：…」（示例）与「请输入…」（必填输入）二选一，同一页只用一种。
* 空状态：一句结论 + 一句解释 + 一个动作。
* 危险操作标题用动词短语（移除同步配置），说明写清后果。

---

## 7. 页面规格

### 7.1 全局壳层
* 4 个 Tab 保留；每个 Tab 有标题（大标题），滚动时折叠为 nav 标题并带毛玻璃背景。
* 导航栏右侧动作 ≤2 个，尺寸 44×44，`label` 语义完整（无障碍）。
* 二级页：返回箭头 + 标题 + （可选）右侧主操作；标题不再隐藏。

### 7.2 同步（首页）
* 概览卡改为「注意力卡」：有问题→橙色/红色 `AppNotice` + 「N 项需要处理」+ 查看；无问题→绿色「同步运行正常」。
* 指标只保留 2 个有决策价值的：`同步配置数`、`需要处理`；「可运行/后台开启」移到配置页。
* 配置行：标题 1 行 + 副标题 2 行（数据集 · 后台状态），状态药丸语义化（已启用=success / 已暂停=neutral / 需处理=warning / 失败=danger）。
* 右侧只保留 `⋯` 菜单（立即同步/暂停/删除归入菜单，行点击=进入详情）。失败原因不再靠点小图标隐式展开，改为行内提示条或详情页。

### 7.3 连接
* 标题「连接」；右上 `+` 与刷新。
* 行：名称 + 地址 + 协议徽章 + 状态药丸（已连接=success、未连接=neutral、失败=danger）+ `⋯`。
* 失败行内联一行原因摘要（最多 2 行），点击行进入详情。

### 7.4 活动
* 标题「活动」。
* 概览：最近运行 / 待恢复 / 冲突；非零问题指标着色（冲突红、待恢复橙）。
* 行副标题：`配置名 · 相对时间`；失败行显示中文结论（如「远端拒绝访问」），错误码只在详情弹层。
* 行可点：打开详情弹层（时间、配置名、结论、建议操作、技术详情折叠）。
* 冲突行：单个「处理」按钮 → 弹层选择策略，避免 3 个并排按钮。

### 7.5 设置
* 标题「设置」。
* 后台同步卡：全局开关 + 系统后台状态（可用/受限）+ 脚注；开关行不带装饰图标，状态行带状态图标。
* 新配置默认策略卡：开关行 + 「默认蜂窝网络传输上限」值行（`50 MB`），脚注完整换行。
* 删除保护卡：状态行 + 「最近一次安全清理 / 等待设备确认 / 长期未确认设备」改为 `标签 + 右侧值` 形态，说明文本完整换行，不截断。
* 暂存空间：`0 B` 指标 + 「清理」按钮（tonal 按钮，不是蓝色文字）。
* 隐私与诊断：只读说明行（无 chevron）+ 「导出脱敏诊断」动作行（有 chevron）。
* 版本与许可：协议版本 / 应用版本 / 关于与开源许可。

### 7.6 新建连接 / 协议选择
* 标题「新建连接」「选择协议」。
* 顶部说明改为 `footnote` 级灰色说明（13pt），不再用 17pt 正文。
* 本地目标只有「格间」时渲染为静态来源行（无勾选列表）。
* 协议行：WebDAV/Google Drive/OneDrive 各自独立图标与品牌色；「其他服务」保持降级灰 + 锁图标。

### 7.7 WebDAV / OAuth / 百度 表单
* 标题「WebDAV 连接」「Google Drive 连接」「百度网盘」。
* nav：左返回、右「保存」（主，禁用态明显）；「说明」降级为信息图标按钮或首行文字链接。
* 表单行统一 `AppFormRow`：标签列宽固定 96，值列同一起点，placeholder 单一样式，错误在行下。
* OAuth 页去掉嵌套卡片：状态卡（需要配置/已就绪）+ 表单 + 主按钮「保存 Client ID」+ 技术详情折叠。
* 保存前校验失败时滚动到首个错误行并高亮。

### 7.8 连接详情（远端浏览）
* 标题 = 连接名；副标题 = 地址。
* 工具栏：路径面包屑 + 刷新；网格每行 4 个，名称最多 2 行。
* 错误态：`AppErrorView`，主操作「重试」，次操作「编辑连接」。
* 断连状态在页面顶部显示 `AppNotice`，而不是替换整页内容。

### 7.9 同步配置详情
* 标题 = 配置名；下方 `AppSegmentedTabs`（概览/待处理/历史/冲突/设置）。
* 概览：状态药丸 + 「最近同步（相对时间 + 结果）」+ 「数据集」+ 「后台同步」的键值卡；**删除重复的立即同步按钮**，只保留一个主操作与一个次要操作（暂停/恢复）。
* 问题提示：`AppNotice(danger/warning)` + 「查看详情」→ 技术详情弹层。
* 待处理 / 冲突空状态使用不同图标与文案，并给出下一步（如「查看历史」）。
* 历史行：`完成/失败` + 相对时间 + 中文结论；点按 → 详情弹层。
* 设置：后台策略卡 + 危险操作卡（红字 + 红图标 + 明确后果）。

### 7.10 新建同步向导
* 已有配置时：说明原因 + 主操作「打开同步配置」+ 次操作「返回」。

---

## 8. 实施阶段

| 阶段 | 内容 | 出口标准 |
|---|---|---|
| P0 | 本文档 + tokens + `app_components.dart` + 格式化工具 | `flutter analyze` 干净；组件可编译并在一页试用 |
| P1 | 壳层与 4 个 Tab（同步/连接/活动/设置）标题、导航栏背景、语义色、无重复操作 | 4 页截图通过验收清单 |
| P2 | 连接流程（新建/协议/WebDAV/OAuth/百度/详情）标题、表单对齐、错误态 | 6 页截图通过 |
| P3 | 同步配置工作区（详情 5 Tab + 向导）IA 与文案 | 6 页截图通过 |
| P4 | 全量视觉回归（浅/深色、动态字体、iPhone 尺寸）、`flutter analyze`、构建验证 | 回归截图 + 构建产物 |

**节奏约束**：每阶段结束必须能编译运行并截图；不允许跨阶段堆叠未验证的大改。

---

## 9. 验收清单（Definition of Done）

1. 每个页面都有可见标题；滚动时内容不与状态栏重叠。
2. 不存在 `配置 <uuid>`、`sync.unexpected`、类名等内部标识出现在主文案。
3. 「已启用/已连接/已完成」等正向状态不再使用警告色；状态永远是 图标 + 文字 + 颜色 三者一致。
4. 同一动作在同一屏只出现一次。
5. 没有空状态/错误态是无动作的死胡同。
6. 解释性文本无句中截断；标题截断必须保留可辨识前缀并提供完整信息入口。
7. 数字单位/时间格式统一走格式化工具。
8. 表单标签列对齐、placeholder 风格统一、错误可见。
9. 所有可点区域 ≥44pt，具备 Semantics 标签。
10. 深浅色模式、1.0–1.5x 动态字体下不破版。
11. `flutter analyze` 无新增问题；iOS 模拟器构建通过并完成逐页截图。

---

## 10. 风险与对策

| 风险 | 对策 |
|---|---|
| `sync_profile_workspace.dart` 单文件 3.4k 行，改动易回归 | 只替换呈现层组件与文案，不动状态/数据流；分页分批验证 |
| 双平台（Cupertino/Material）行为差异 | 新组件在 Cupertino 分支实现，Material 分支提供等价实现；每阶段跑 `flutter analyze` + Material 冒烟 |
| 文案/语义色改动影响既有测试 | 修改前 `grep` 断言字符串；同步更新 `test/` 与 `ui_test_harness/` 中的期望 |
| 深色模式对比度 | 语义色提供 dark 变体，药丸文字色单独校验 |

---

## 11. 实施状态（2026-09-12）

### 已落地

| 阶段 | 内容 | 关键文件 |
|---|---|---|
| P0 | 语义色 tone（`AppTone`）、字体阶（`AppType`）、间距/圆角/动效 token、格式化工具（相对时间、字节、错误摘要、技术详情） | `lib/appearance/design_tokens.dart`、`lib/widgets/app_format.dart` |
| P0 | 新组件：`AppNotice`、`AppMetricGrid`、`AppPrimaryButton`、`AppSecondaryButton`、`AppFormRow`、`AppSegmentedTabs`、`AppDetailSheet`、`AppDetailDisclosure` | `lib/widgets/app_components.dart` |
| P0 | `WDAppBar` 默认显示标题；二级页顶部改为固定毛玻璃栏（内容不再与状态栏重叠）；`AdaptiveStatusBadge` 改为 tone 优先且不再被拉伸 | `lib/widgets/common_widgets.dart`、`lib/widgets/adaptive_widgets.dart` |
| P1 | 同步首页：大标题、注意力卡（正常/需关注/断开三态）、配置行（标题不截断、状态药丸语义化、失败原因中文、仅保留 ⋯ 菜单） | `lib/features/sync_profiles/ui/sync_profile_workspace.dart` |
| P1 | 连接：大标题、协议 + 地址副标题、状态药丸（已连接=绿/未连接=灰/连接失败=红） | `lib/features/connection/ui/connections.dart` |
| P1 | 活动：大标题、指标着色、显示配置名与相对时间、行可点开详情弹层、错误码移入技术详情 | `lib/features/activity/ui/sync_activity.dart` |
| P1 | 设置：大标题、状态行语义色、`50 MB` 单位、删除保护改为标签/值行 + 完整脚注、暂存空间 tonal 按钮、隐私行完整换行 | `lib/features/sync_profiles/ui/sync_profile_workspace.dart` |
| P2 | 新建连接：删除单选勾选、脚注级说明、静态来源行；协议页：独立图标与统一副标题 | `lib/features/connection/ui/new_connection.dart`、`protocols.dart` |
| P2 | WebDAV：标题、说明降级、保存加粗；OAuth：去嵌套卡片、字段标签外置、异常类名移入技术详情、当前状态卡；百度：保存同上 | `new_webdav.dart`、`new_oauth.dart`、`new_baidu_token.dart` |
| P2 | 连接详情：标题带连接名、错误态新增「编辑连接」次操作 | `lib/features/connection/ui/connection.dart` |
| P2 | 帮助页：标题分段、正文降到 15pt、去掉重复大标题 | `lib/features/connection/ui/connection_guidance.dart` |
| P3 | 同步配置详情：自定义分段标签页、概览改为「身份 + 状态 + 键值卡」、删除重复的立即同步按钮、失败提示卡；待处理/冲突空状态区分图标并给动作；历史行只显示状态与相对时间，详情走底部弹层 | `lib/features/sync_profiles/ui/sync_profile_workspace.dart` |
| P3 | 向导：已有配置时展示现有配置并可跳转，不再是死胡同 | `lib/features/sync_profiles/ui/sync_profile_workspace.dart` |
| P4 | 深色模式：分段控件选中态改用高亮叠色；Debug 构建隐藏 DEBUG 角标 | `lib/widgets/app_components.dart`、`lib/main.dart` |
| P4 | 中文本地化：接入 `flutter_localizations` + `zh_CN`，许可页/返回按钮/系统控件文案不再回落英文 | `pubspec.yaml`、`lib/main.dart` |
| P4 | Material 页面状态栏样式修正（透明 AppBar 会误判为深色底，导致浅色页面上状态栏图标不可见） | `lib/appearance/theme.dart` |
| P4（修正） | 错误页/空状态按钮比例失调：改为 `AppActionStack` 统一动作区——主按钮与次按钮同宽（对齐正文列宽）、高 50、圆角 12，次按钮改为 tonal 药丸，不再是「小方块 + 裸文字链接」并排 | `lib/widgets/app_components.dart`、`adaptive_widgets.dart`、`connection.dart`、`connections.dart`、`sync_profile_workspace.dart` |

### 验证结果

- `flutter analyze`：无问题。
- `flutter test`：311 项全部通过（同步更新了 2 个断言旧文案的测试）。
- iOS 模拟器（iPhone 17 Pro Max，iOS 26.5）：构建 → 安装 → 冷启动 → Computer Use 逐页复检。
- 截图：改版前 `ui_audit/redesign/01-…20-…`，改版后 `ui_audit/redesign/v3-…`／`v4-…`／`v5-…`，对比图 `sheet-before.png` / `sheet-after.png`。

### 复检补充（第二轮）

- 许可页：标题「许可」、计数「N 份许可」、状态栏图标可见（`ui_audit/redesign/v7-01-licenses.png`）。
- 空状态：待处理=托盘图标、冲突=盾牌图标，二者已可区分（`v7-02-pending.png`、`v4-05-conflicts-empty.png`）。
- 配置设置 Tab、说明页（15pt 正文、无重复大标题）、深色模式下的表单与详情页均复检通过（`v7-03`…`v7-06`）。
- OAuth 页「技术详情」默认折叠，原始异常类名不再出现在页面正文（`v8-02-oauth.png`）。
- 最终态汇总图：`ui_audit/redesign/sheet-final.png`（改版前基线 `sheet-before.png`、第一轮 `sheet-after.png`）。

### 仍待完成

1. 连接详情的**文件网格正常态**未在本次复检覆盖（本机 WebDAV 未连通，页面停留在错误态，已补「编辑连接」入口）——需要一次可用的远端连接后按本文档 7.8 复检。
2. 深色模式与动态字体的逐页巡检只覆盖了首页/详情页，剩余页面待补。
3. iPad 与 Material 分支未做逐页截图回归（组件已提供等价实现，`flutter analyze` 与 widget test 覆盖）。
