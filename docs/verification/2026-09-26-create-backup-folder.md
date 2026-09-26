# 备份文件夹中新建目录（2026-09-26）

## 用户需求与行为

旧测试目录不应阻碍用户选择一个新空目录。备份文件夹选择器新增“新建文件夹”：展示当前创建位置，输入名称，明确点击“创建并进入”后才请求远端创建。成功后进入新目录，但仍需用户点击“使用这个文件夹”，不会自动开始备份。恢复选择器保持只读。

若要与 `/USB_HDD_8T/velock-sync` 内的旧测试完全分开，用户可以上一级至 `/USB_HDD_8T`，创建一个不同名称的同级目录。不得替用户命名或删除旧目录。

## 安全与失败语义

- 名称、父路径先校验，凭据与网络访问在校验之后；路径段只编码一次。
- 单次无正文 MKCOL，不跟随重定向、不递归创建、不自动重试；仅201成功。
- 401/403/405/409提供对应提示；405不能解释为创建成功。
- 超时、运输失败、5xx及异常2xx保守视为结果不确定，保留父目录，提示刷新核实。刷新仅列目录、不再次创建。
- 创建期间禁用重复提交、导航与使用目录；取消表单没有远端写入。
- 不修改原连接范围，不覆盖普通同步与其他备份的目录配置。

## 验证

执行：

```sh
flutter test --no-pub --reporter expanded \
  test/features/cloud_backup \
  test/features/connection/remote_object_store_factory_test.dart \
  test/providers/webdav \
  test/sync_profiles \
  test/dataset_adapters/velock_exchange \
  test/sync_core/join_approval_applier_test.dart
```

结果：**350项通过**。五个改动Dart文件分析：**No issues found**。
覆盖取消/非法名称/重名、实际创建路径、单次请求、错误与不确定结果、忙碌状态、恢复只读，以及320px/2倍文字中英文目录页和创建表单。

日志与截图目录：`/Users/parcool/AndroidStudioProjects/velock_sync-artifacts/work/create-backup-folder-20260926/`，最终测试日志 `regression-final.txt`，分析日志 `analyze-final.txt`。

## 部署和现场边界

- 热更新尝试未在当时已打开的目录页显示新入口，不能算部署完成。
- 随后完整构建 Debug 模拟器包，构建成功；明确安装模拟器产物并启动成功。
- 设备：iPhone 17 Pro Max / iOS26.5，`26CC5821-DEF4-47D3-978D-A11D7293AD61`；bundle `tech.windata.velock.sync`。
- DeepSeek Computer Use复核安装后停在“格间备份”首页，可见“开始备份”“从云端恢复”。该页本来没有新建文件夹按钮；未重新进入授权与目录选择流程。截图 `installed-ui.png` 是首页，不冒充新建表单截图。
- 未在用户NAS实际创建、删除或清理目录，未开始备份或批准授权。真实NAS创建仍待用户命名确认，不能宣称端到端创建成功。
- 本功能不解决已有published本地链迁移到空远端所需的历史补传/完整快照问题；历史连续性与完成状态门禁不放宽。之前NAS并发401也不在此轮声明解决。
