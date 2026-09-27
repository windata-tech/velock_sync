# 确认目录与同步分开（2026-09-26）

## 用户纠正

选择旧备份目录是在确认保存位置，不应自动运行同步，更不应弹出“没有需要传输的新内容”。之前“确认并继续备份”的实现把两个不同意图绑定，现已替换。

## 新行为

- 确认弹窗为“确认旧备份目录？”、“确认目录”，明确只保存位置，不启动同步、上传、下载或删除。
- selectFolder仅调用repository保存profile，不调用runSyncWithProgress/presentSyncResult，也不写运行历史、cursor或清理旧失败。
- 保存成功切换为“备份位置已更新 / 本次只保存目录，尚未开始备份”，原错误说明与“找不到旧备份”入口不再停留。
- 主按钮“完成”只返回。可选的“开始备份”是另一个独立点击，只有该回调才能运行既有runner并展示传输结果；保留原验签和历史门禁。
- 未把保存位置称为完整性验证成功，不伪造备份完成回执；原有独立后台调度配置不被本操作修改。

## 验证

- `flutter test test/features/cloud_backup test/widgets test/features/connection test/sync_profiles`：253项通过。
- 新增/更新断言：确认目录后runner调用数严格为0；没有sync-progress/传输结果；保存后的标题切换；旧失败记录保留；只有另点开始备份后调用数为1；完成返回不启动同步；陈旧profile保存失败不显示成功。
- 两个改动Dart文件analyze无问题。
- 真实字体widget渲染已人工查看成功状态，证据 `../velock_sync-artifacts/work/folder-confirm-only/folder-confirmed.png`（内存fixture，不是设备截图）。
- 现有iPhone17ProMax模拟器Debug构建安装启动成功。没有为本次验证触发用户NAS同步或更改用户备份目录。
- 日志同目录：regression.log、visual.log、analyze.log、build-run.log。
