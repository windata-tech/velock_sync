# Selected Folder 模拟器端到端验证

- 日期：2026-09-12
- 范围：iOS Simulator + 本机 WsgiDAV
- 真机：未使用

## 覆盖链路

1. 源模拟器从「备份与同步」进入「新建同步」；
2. 新建本机 WebDAV 连接；
3. 进入「文件夹同步」并创建 Generic Vault Profile；
4. 通过 iOS Document Picker 选择 Fixture Host 的 `VelockSync-E2E-Source`；
5. 重启 App 验证 Profile 和授权引用持久化；
6. 执行首次同步，验证远端存在一个 Generic Vault 和 `operations.enc`；
7. 从统一详情页的「恢复与安全」导出带口令的恢复包；
8. 第二台模拟器导入恢复包，选择 `VelockSync-E2E-Replica`；
9. 执行首次下载，验证 Profile 已完成运行；
10. 通过 Fixture Host 比较源文件与副本文件的 SHA-256 和字节数。

## 执行命令

```bash
E2E_SIMULATOR_UDID=<booted-simulator-udid> \
  tool/ios_ui_test/run_selected_folder_ui_test.sh
```

脚本默认卸载并重装 Sync App 以清除旧连接/Profile，保留 Fixture Host；只有显式设置
`E2E_KEEP_APP_DATA=1` 时才保留 App 数据。

## 结果

- XCUITest：`testSelectedFolderSourceSync`、`testExportSelectedFolderRecoveryPackage`、`testRecoverSelectedFolderReplica` 全部通过；
- 远端上传对象：至少一个 `operations.enc`；
- 副本文件：SHA-256 与源文件一致；
- `flutter analyze`：0 问题；
- `flutter test`：411 项全部通过；
- iOS Simulator Debug 构建通过；
- Android Debug APK 构建通过。

## 尚未覆盖

- 真实 NAS / Google Drive / OneDrive 账号；
- iOS 后台任务由系统实际调度的精确时机；
- Android SAF 的真机级长流程（本轮仅完成 Android Debug 构建）。
