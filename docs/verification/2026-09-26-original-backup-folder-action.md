# 找回原备份目录：操作闭环（2026-09-26）

## 用户问题与改动

- 全局 AppBackButton 的图标从20改为32，触控区仍至少44。单chevron、统一颜色、辅助标签及返回语义不变。
- BackupHistoryHelp 首屏改为“找回备份位置”：简短原因、当前连接/完整目录、主操作。长篇限制和数据保留提醒在“原来的备份找不到了？”按需查看。
- WebDAV 主操作改为真正的只读目录选择器，默认进入当前profile子目录，可返回父目录查找旧备份；不提供创建目录。
- “使用这个文件夹”之后还有完整路径确认；只有“确认并继续备份”才保存此profile的remoteRootSegments，然后调用既有runNow和结果展示。取消、纯浏览、查看说明不修改profile、不触发备份。
- OAuth当前只提供明确标注的只读查看入口，未假称支持目录切换。

## 安全与并发

- 不改共享connection、不重建配对、不清失败记录、不重置cursor/ACK/可信producer。旧历史完整性和验签门禁保持；选中目录不是完成回执。
- repository重新读取并核对完整旧profile，拒绝过期页面、非active/已删除profile、运行中任务与非法路径。
- 独立持久location lease覆盖VelockSyncService从首次读取profile、adapter预检、远端准备到run完成，和目录修改互斥；不占用upload/download自身的锁。失败finally释放，30秒heartbeat、5分钟过期恢复。
- 保持原runner能力边界：不是自动全量迁移；旧目录本身不完整时仍应失败。执行备份会按既有runner传输，而不是只读验证。

## 验证

最终命令：

```sh
flutter test test/features/cloud_backup test/widgets/app_back_button_test.dart test/dataset_adapters/velock_exchange test/sync_profiles test/sync_core/sync_profile_runner_test.dart test/sync_core/sync_upload_engine_test.dart
```

357项通过。覆盖：取消确认不变更、明确确认后仅改profile并调用一次runner、保留失败记录/cursor、拒绝运行中与陈旧页面、真实service的adapter预检期间拒绝换位置、失效后释放lease、中英文1.8倍字体、iOS/Android按钮大小及语义。

九个改动Dart文件静态分析No issues found。最初worker测试选择了Tooltip祖先语义节点，已改为按Back辅助标签获取真实按钮节点，最终回归通过；早期测试日志不是最终验收结果。

现有iPhone 17 Pro Max模拟器（26CC5821-DEF4-47D3-978D-A11D7293AD61）Debug完整构建、安装、启动成功，未新建或擦除模拟器。首屏使用真实字体widget渲染人工查看，没有溢出或方框字；此图是widget+内存fixture，不是设备截图。

证据在项目外 `../velock_sync-artifacts/work/history-actions/`：`final-regression.log`、`analyze.log`、`build-run.log`、`visual.log`、`screenshots/history-help.png`。

没有替用户在NAS上选择/确认任何目录，没有执行真实NAS备份或恢复；本轮不能宣称真实NAS全流程已通过。
