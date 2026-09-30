# 历史集合 404 的错误分类与处理入口

## 现场事实与边界

- 用户 17:16 的失败提示为「远端目录不存在，请检查路径配置」，详情仍提供「立即备份」。
- 只读检查当前 iPhone 17 Pro Max 模拟器的 Sync 数据库：17:16 新建的格间配置选择 `/USB_HDD_8T/6`，最近两次运行均为 `remote.object_not_found`；同账号此前的配置选择 `/USB_HDD_8T/111`。
- 本地 Exchange 存在该账号的签名 checkpoint，当前 Outbox/Ready 为空。
- 现场数据库不记录具体失败 object key；本轮没有操作 NAS 或重新运行现场备份，因此不能仅凭数据库断言 `/6` 本身存在，也不能宣称已完成远端迁移。下面修复的是通过代码与测试确认的内部集合 404 误分类。

## 原因与修改

`verifyVelockRemoteHistory` 对正数本地进度要求远端 commit 序列连续。空列表会产生 `remote.velock_history_incomplete`，但 WebDAV 对未创建的 commits 集合返回 `RemoteObjectNotFoundException`，此前直接冒泡为泛化路径错误，无法进入已有 `reviewHistory` 说明入口。

现在仅在该历史列表调用处将 `RemoteObjectNotFoundException` 归为历史不完整；仍失败关闭，不能把缺历史作为空列表成功放行。分页中途集合消失同样失败。认证、权限、服务错误与取消仍传播；明文同步的目录消失保护不变。

这不是自动全量迁移。新位置不会因为本地保留 checkpoint 而获得旧业务历史；恢复完整目录或实现完整快照迁移仍是必要条件。旧运行记录不被改写，修复后的分类在下一次实际运行时生效。

## 验证

- 修复前新增的两个 404 分类用例失败；修复后通过。
- 历史守卫覆盖首次列表 404、后续分页 404、401/403/500 不改类。
- 真实签名 checkpoint + adapter + runner 集成回归分别使用空列表和缺集合 404：运行均记失败、不发布进度 checkpoint；补齐测试 commit 序列后才能通过既有连续性检查。
- 共 99 项通过：history guard、exchange checkpoint、runner、history help、backup navigation、plain folder service。
- 三个改动 Dart 文件静态分析通过。日志：`ui_test_results/history-404-20260927/`。
- 本轮未构建安装新版模拟器 App，未修改用户的保存目录或历史记录。

## 17:34 选中 /222 后的复查

- 用户确认记不清以前成功的目录，本次是在文件夹列表里选择了已有目录。
- 只读数据库核对：当前配置已保存为 `/USB_HDD_8T/222`；17:34 失败码为 `remote.velock_history_incomplete`。本地签名 checkpoint 的 coveredSequences 为 7。
- outgoing_batches 中第 1 批属于旧配置 A，第 2～7 批属于旧配置 B，均为 published；A、B 的保存位置均是 `/USB_HDD_8T/111`。这比仅查看旧路径提供了更强的定位依据，但仍不是对当前 NAS 内容的重新验签。
- 本机 GC 的 deleted_object_count 总和为 0，没有本机同步清理删除旧历史的证据。
- 私有测试 WebDAV 账号只能读共享目录 `<共享名>` 下的测试空间，不能代替 App 内账号检查 `/111`、`/222`。XcodeBuildMCP 的 AX 工具缺少 SimulatorKit.framework，备用桌面工具超时，本轮没有取得 App 账号的实际目录列表。GUI 租约已释放。

### 防止任意已有目录被当成原备份位置

- 仅“找回备份位置”流程启用 `requireExistingBackup`，使用现有 BackupDestinationService 的恢复候选发现，保存前按当前 vault/可信 producer 做只读列表检查。普通管理页更换目录的既有语义不变。
- 没找到记录：显示“这里没有找到原备份”，明确已有文件夹不一定是原备份，禁止进入保存确认、保留原 profile、不运行同步。读取失败也不保存，且不冒称没有备份。
- WebDAV 某个可信 producer 的集合 404 时继续检查其他可信 producer；全部未发现才返回 backup_not_found。401/403 等异常仍传播。
- 候选发现只证明找到对应命名空间内的备份记录，不保证完整历史、签名或 blob；原 runner 门禁不变。它不能替代完整快照迁移。
- 67 项相关服务/界面/真实路由测试通过，5 个改动文件 analyze 无问题。日志 `/Users/parcool/work/velock-history-audit-20260927/tests.log`。新增检查尚未在模拟器安装验收。
