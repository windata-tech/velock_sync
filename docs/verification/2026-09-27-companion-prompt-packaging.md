# 格间本地改动「立即打包」修复与设备验证（2026-09-27）

## 现场问题（用户报告）

用户在格间「文件」页加入一个文件（09:18:05，`使用手册-中文.md`，10587 B），随后在 Sync 连点 4 次「立即备份」（09:18:44 / 09:19:41 / 09:20:19 / 09:20:24），结果全是「无需传输」，用户质疑「我明明先加了文件」。

从设备上读到的实际时间线证明两边都没说谎，但格间交付得太晚：

| 时刻 | 事实 | 证据 |
| --- | --- | --- |
| 09:18:05 | 文件落库，change_log 记为第 10 条 `file/pending` | 格间 `t_file` id=6、`t_sync_change_log` seq10 |
| 09:18:44–09:20:24 | Sync 4 次运行，交换区确实为空 | `SyncExchange/Outbox/Ready` 空；`sync_runs` 4 条 completed |
| 09:21:16 | 用户**重新打开格间**，首页基线才打包 seq3（batch `3ce076df`，1 upsert + 11333 B blob） | 格间日志 `dashboard baseline begin … pending all=1 types={file} … export ok source=dashboard exported=1` |
| 09:34:42 | 用户点「立即备份」，这一批真正上传 | 11333 B blob + operations + envelope + seq3 commit 全部 `completed`；published 回执写出 |

即：**「无需传输」在当时是真的，但根因是格间没有及时把文件改动交给 Sync**。

## 根因（格间侧，与 Sync 无关）

格间把本地改动交给 Sync 只有一个出口 `exportPendingExchangeChanges`，而调用它的地方是：

- 相册导入 `_exportPendingMediaChanges`；
- 凭证/卡/备注 `credentials_persistence`；
- 文档 `document_sync_exchange_runtime`；
- 设置页 `velock_sync_setting_view`；
- **应用启动时的 dashboard 基线**。

**文件域（导入/改名/移动/粘贴/删除/新建目录）完全没有这个出口**，所以文件类改动只能等下一次格间启动的首页基线才被打包；相册导入是即时的，文件不是——这正是用户撞上的空档。

## 修复（格间仓库，分支改动未提交）

1. 新增 `lib/sync/bridge/sync_pending_change_packager.dart`：
   - 进程内 debounce（默认 400 ms）+ 单飞 + 尾随补跑；`install / uninstall / notifyLocalChange`；
   - `flush()`（退后台兜底）与 `exportNow()`（启动那次导出，保证不会与通知并发成两次争抢）；
   - 导出失败只回报 `onError`，后台 pass 永不抛出（导出器自己已经写诊断日志）。
2. `SyncStateRepository.recordNextLocalChangeInTransaction` 写入 `t_sync_change_log` 后调用 `SyncPendingChangePackager.notifyLocalChange()`；**所有本地域共用这一个通知点**（file / file-tag / document / password / card / note）。事务内只打一次 timer，不阻塞写入，回滚时导出自然找不到待打包项。
3. `sync_conflict_resolution_repository.dart` 三处直接插入 change_log 的冲突决议同样补通知。
4. `DashboardController` 启动时构建完整 runtime 后 `install` 打包器（进程级、随 provider 存活），启动那次导出改走 `packager.exportNow()`，`AppLifecycleListener.onPause` 兜底 `flush()`，`ref.onDispose` 释放。

## 回归测试

- 新增 `test/sync/sync_pending_change_packager_test.dart`（9 项）：突发合并成一次、无通知不打包、打包中产生新改动会尾随补跑、`flush` 立即执行、`flush` 等待在飞 pass、`exportNow` 必然执行、失败不抛出且后续仍可用、只有被 install 的实例收到通知、dispose 后停止。
- `test/sync/sync_file_mutation_service_test.dart` 增 1 项：`upsert` 提交后写入路径无打包，debounce 内触发一次。
- `test/sync/sync_file_exchange_runtime_test.dart` 增 1 项端到端：真实 runtime + 真实 DB + 真实 `SyncFileMutationService` → debounce 后 `Outbox/Ready` 出现**可解码**批次（entityKind=file）。**这条在没有本修复时必然为空**。
- 格间 `flutter test` 全套通过；改动文件 `flutter analyze` 无新增问题（只剩仓库既有 info）。

## 设备验证（iPhone 17 Pro Max 模拟器，Debug 重建安装，数据保留）

| 时刻 | 动作 | 结果 |
| --- | --- | --- |
| 09:37:37 | 新版格间启动 | 日志出现新指纹 `export ok source=local-change exported=0` |
| 09:38:05 | 文件页「…」→ 新建文件夹（**全程不重启格间**） | **0.96 s** 后 `Outbox/Ready/fa3f4bd3…` 出现；日志 `pending all=1 types={file} → publishing 1 changes → export ok source=local-change exported=1` |
| 09:38:37 | 长按 → 删除 → 移到最近删除 | **0.96 s** 后 `Outbox/Ready/177691e6…`（墓碑） |
| 09:38:43–09:38:52 | Sync「立即备份」 | seq4/seq5 的 operations.enc / envelope.json / commit（+retention）全部 `upload completed`，两封 published 回执写出，`Outbox/Ready`、`Outbox/Claimed` 均为 0 |

原始证据与截图：`ui_test_results/companion-packaging-20260927/`（`evidence.txt` + 4 张模拟器截图）。
验证用的文件夹是新建后立即删除的空目录（无文件内容），云端只多一条 create + 一条 tombstone 历史，用户文件列表无残留。

## 边界（不要过度解读）

- 本轮**只改格间的打包时机**，未改 Sync 传输协议、签名/验签、历史连续性门禁、恢复流程，也未改任何远端写入规则。
- 打包仍要求格间进程在运行（改动提交后约 0.4–1 s 内打包）；如果改动发生在格间被系统冻结/未启动时，仍然靠下一次启动基线兜底。
- 设备验证是模拟器 **Debug** 构建 + 空目录创建/删除；未做真机 Release 验证，也未用大文件重跑「文件导入 → 上传」完整链路（用户 09:34 那次是真实文件、由用户自己点的备份）。
- Sync 首页仍写「有新内容时，先打开格间，再回来备份。」——修复后这句依然成立（打开格间就是触发打包），本轮未改 Sync 文案。
