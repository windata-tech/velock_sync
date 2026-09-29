# 更换保存位置恢复新建文件夹

用户只要求把「新建文件夹」移到右侧；后续共用 `changeVelockBackupLocation` 错误地固定 `restoring: true`，让管理页也显示「找到原备份文件夹」并隐藏创建按钮。

修正为按入口意图区分：普通管理换位置的 `requireExistingBackup=false` 使用备份选择模式，并接入现有 `backupFolderCreatorProvider`；需要寻找原历史的入口保持只读。右侧创建布局不变。创建只建一个空目录并进入，随后仍需明确选择和保存；不自动迁移、同步或清除历史。

新增管理入口组件测试覆盖标题、按钮在上一级右侧、创建回调携带当前父目录、新建后 profile 仍是原目录且 runner 未调用。31 项 picker/history help 回归通过，两文件静态分析无问题。

Debug 包已覆盖安装到现有 iPhone 17 Pro Max。原生 XCTest 从「详情 → 管理 → 更换保存位置」检查右侧按钮，打开创建表单后取消；不在用户 NAS 上创建测试目录。日志与实际截图保存在 `ui_test_results/manage-new-folder-20260927/`。

18:19 原生用例 1/1 通过。前两次失败为测试定位器在转场前选择了不含精确标签的查询、取消后未等待转场；修正后验证标题、右侧按钮、打开表单与取消返回均通过。实际截图 `manager-folder-picker.png` 经人工查看确认。
