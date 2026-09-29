# 原备份丢失后建立新备份：分阶段设备验收

用户要求：原来的云备份找不到时，不能永久禁止继续备份。允许用户明确选择新的空目录，由格间读取当前完整本机内容生成签名加密快照，Sync 上传并回读校验后切换本配置。此功能不找回本机已丢失的内容，也不恢复缺失的历史版本。

## 已实现的边界

- 不清空身份、旧 cursor、可信 producer 或历史错误来伪造成功；旧目录找回入口保持。
- 生成由格间明确确认、解锁会话和应用写入排他保护；读取真实六类内容，缺密文/读回失败拒绝。
- 原始密文持久暂存，同一 snapshot ID 重用原字节。Sync 只传输加密文件；提交最后发布、完整回读后 CAS 切换该 profile。
- 恢复需原账号、可信生产者签名、格间实际落库和全量读回，签名完成回执之前不推进恢复完成状态。

## 本轮已通过的实际设备步骤

2026-09-27，专用 iOS 26.5 Debug 模拟器，仅 localhost WebDAV、合成数据。不是用户 NAS 或物理设备验收。

1. 本机独立生成：真实 SQLite、Native 加解密、六条内容（文件/照片/账号/卡/备注/文档）、两个附件，Total 1 / Passed 1。
2. 正常跨 App 配对和首次旧目录备份：Total 1 / Passed 1。完整测试远端保存在服务目录之外后，模拟旧目录丢失。
3. 从历史缺失说明进入建立新备份、选择空目录、格间授权生成、Sync 上传和切换：Total 1 / Passed 1。实际 `sync_runs` 为 completed → remote.velock_history_incomplete → completed；profile 目录 old → new，挂载新 snapshot ID。独立 SHA-256 检查新远端 part/blob 全部匹配 manifest，6 records、有已发布历史 heads。
4. 新空白恢复端下载新目录加密恢复文件、通过纸卡四项信息恢复原账号：Total 1 / Passed 1。账号刚恢复时业务表为空，随后才授权下载完整快照。
5. 格间确认恢复：实际 Native 写入和全内容读回完成，`t_sync_snapshot_restore` 为 completed、6 records，签名完成回执落盘。第一次跨 App 测试在回到 Sync 时失败，原因是没有续接；不能将该次整条测试计为通过。
6. 完成回执续接后遇到仅快照目录没有 V1 commits 集合的 404。修复之后的实际续接及内容检查 Total 1 / Passed 1：Sync 完成；UI 打开 TXT 正文、PNG 原图、账号详情、信用卡完整测试卡号、备注第二行正文。文档由 Native 恢复全量读回验证及真实数据库比对确认，没有冒称手机文档 UI。
7. 独立 `verify_replica_convergence.py` 确认同 vault、不同 device、六类业务记录与原 revision 完全对应，file/media 密文字节一致。该脚本不比较凭证明文；凭证明文的依据是 Native 恢复读回及上述 UI 检查。

## 本次定位并修复

- 新装库 onCreate 漏建 `t_sync_conflict_resolution_intent`，同版本 onOpen 不修复，实际生成查询失败。补创建及幂等 onOpen 修复，保留业务数据和未完成 intent。实际磁盘同版本 reopen 回归覆盖。
- 未使用过的 File/Media 原生目录不存在，journal 检查误调用 resolveSymbolicLinks。不存在只表示没有 journal；存在但非法路径继续拒绝，有 live 文件仍要求真实密文。
- 24 项 schema/native binding/conflict migration 回归通过，4 文件 analyze 无问题。
- 首页启动/回到前台时仅针对已有本地完成回执的待恢复配置续接，单飞防重入。回执存在只触发普通 runner，签名、consumer、manifest hash、覆盖位置验证仍由既有 reconcile 执行。44 项回归通过（含未完成不启动、前台重入一次、伪造回执拒绝），6 文件 analyze 无问题。
- 下载器仅在本次已完整验签和回读的快照证明绑定同一个 remote 实例/同 vault/同 producer、覆盖位置等于已应用位置时，将首次列举 commits 集合的 404 视作没有新增量。未覆盖、进度超过快照、其他远端、后续分页 404 或普通适配器继续失败。39 项回归通过，4 文件 analyze 无问题。
- 已下载等待格间确认时，提示标题改为「请到格间完成恢复」，正文明确下一步；13 项提示回归通过。

## 后续增量与验证边界

源端在重建之后通过正常 UI 新建账号、发布 seq7（快照 heads=6），Total 1 / Passed 1。恢复端正常下载并打开新增账号，正文 `after-snapshot-user` 可见，Total 1 / Passed 1。独立比对同 vault、不同 device、7 条全部 revision 对应；没有复制数据库到恢复端、清游标或重置身份。

本轮是分阶段的真实模拟器验证：中途修复续接和空增量目录后复用同一对设备和已有数据继续验收，没有将失败 take 计为通过，也没有声称所有步骤在最终版本上从零单次重跑。最终包另含提示标题/正文修正与等价 braces lint 清理，13 项提示回归通过。未验证物理 iPhone、Android 新快照流程、真实 NAS/OAuth、并发写入压力或长时间系统后台场景。此前 NAS 401 限制不被本轮 localhost 结果覆盖。

只有当前本机仍完整可读的数据可用于重建；本机也已丢失的内容和旧版本历史不能由新快照恢复。新位置必须为空；上传并回读成功才切换，旧数据不主动删除。

私有测试证据：项目外 `velock_sync-artifacts/work/rebuild-backup-20260927/`。恢复卡与环境文件不提交。完整工作区存在其他并行用户改动，本轮不提交或重置。

## 收尾

最终包：`sync-delivery.app`、`companion-production-v3.app`（Debug，生产流程，E2E 调试入口关闭）。完整编译成功；为避免本机无签名外部 framework 的加载问题，测试安装使用已验证原生宿主并替换/重新签名本轮编译 App.framework；本轮没有修改原生桥接源码。设备数据与完整所属 AppGroup 在删除专用模拟器前已保存到项目外私有证据目录。

收尾已确认：两份最终 Debug App 已覆盖安装到用户原有 `iPhone 17 Pro Max`（26CC5821-DEF4-47D3-978D-A11D7293AD61），没有启动App或NAS备份、没有擦除其数据。专用 source/replica 已删除，xcodebuildmcp 列表仅保留原有 iPhone 模拟器；localhost18998已停止，GUI租约已释放。
