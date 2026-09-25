# 云备份交互与 NAS 预检跟进

本记录接续 `2026-09-25-simple-cloud-backup.md`，仅覆盖本次页面交互修正和 NAS 预检定位。两个仓库继续使用 `codex/simple-cloud-backup`；不改原版 main 或备份标签，不把本次修正宣称为完整备份架构/跨 App 恢复完成。

## 1. 格间：去掉原地展开

- 主页面的“管理授权”“详细记录与诊断”合并为一组标准右箭头入口，分别进入独立二级页面；不再使用 CloudBackupDisclosure 或展开箭头。
- 状态卡、恢复卡、待批准连接/设备、冲突仍在首页，不隐藏必须处理的事项。
- 二级页面复用原页面的授权状态和操作，不创建另一套 baseline/refresh lifecycle。原状态变更和认证状态通知驱动详情重建；锁屏后不显示旧成员、旧诊断或旧操作。
- 管理页面加载时不误显示禁用状态；忙碌时禁用操作，失败时保留重试和诊断入口；返回不会展开首页。管理页进入诊断时保留正确返回标题。
- 保留所有原授权确认、成员撤销、修复、传输分页和清理动作，不更改同步协议或加密格式。

## 2. NAS 实测定位：两个不同问题

Computer Use 在用户已登录的 Chrome 中只读核对了 NAS WebDAV 设置：服务、HTTP/HTTPS 和 DavDepthInfinity 已开启，文件共享范围允许本人文件及他人共享。未更改 NAS 设置、权限或密码。

随后只读查看 Sync 当前确认页面，发现连接指向 FN Connect 的入口地址，没有进入实际备份文件夹。没有点击“开始备份”，没有改动用户保存的连接。

| 实验位置与请求 | 实际结果 | 可得出的结论 |
| --- | --- | --- |
| FN Connect 入口，OPTIONS / PROPFIND | 200 / 207，可以列出共享目录 | 地址可访问，入口是目录列表 |
| FN Connect 入口，MKCOL 随机探针目录 | 405；不取得目录归属，不 PUT、不 DELETE | 入口不能直接新建备份目录，不等于 NAS 缺少防覆盖能力 |
| NAS 直连的实际备份目录，原绝对 URI Destination | 碰撞 412 且双方字节不变；新目标 201、原路径 404 | 该实际目录支持本次防覆盖/发布探测 |
| FN Connect 的实际备份目录，绝对 URI Destination | MKCOL/PUT 201，MOVE 502，源/目标字节未变 | 经 FN Connect 转发时存在目标地址写法兼容问题 |
| 同一 FN Connect 实际目录，path-absolute Destination | 碰撞 412 且字节不变；新目标 201、原路径 404 | 路径形式通过本次独立行为探测，无需放松防覆盖规则 |

所有协议实验使用独占随机目录和无敏感内容的小文件；仅清理本次成功创建的目录。未改动真实备份。具体域名、账号和密码不纳入仓库。

### 对应修复

1. MKCOL 405/409 独立分类为 `provider.webdav.collection_not_writable`，保留原状态码供诊断。普通提示要求选择有写入权限的实际共享文件夹，而不是误称 NAS 不能安全保存备份。
2. 同服务内 MOVE 使用编码后的 path-absolute Destination；保留 base 子路径、Unicode、空格、百分号与 query，不带外部主机名。RFC 4918 的 8.3 / 10.3 定义 Simple-ref，允许绝对 URI 或绝对路径。
3. 不增加普通覆盖 PUT 回退；仍要求 `Overwrite: F`、碰撞 412、原有字节不变、新建 201 与源消失。不接受 204 作为新对象发布成功。

## 3. 最终回归

- Sync **432 项**相关回归通过：云备份状态/路由/错误提示、WebDAV、防覆盖与并发 fixture、OAuth、原同步核心等。最终日志：`../velock_sync-artifacts/work/nas-preflight-20260925/sync-regression-final.txt`。
- 格间 **32 项**相关回归通过：状态卡、右箭头单一点击语义、真实 Navigator 进入/返回、详情 live changes、操作启用/禁用与清空、技术记录隔离、320px 中英大字，以及原有授权/页面生命周期回归。日志：`../velock_sync-artifacts/work/cloud-backup-details-20260925/companion-regression-final.txt`。
- 两仓库本次改动范围 analyze 无问题。不是全仓库静态分析结论；不是原生冷/热启动或真实跨 App 恢复验收。
- 修复了测试自身的 Semantics finder/句柄清理及缺失 Scaffold 的布局问题；早先失败日志不能作为最终通过证据。

## 4. 真实生产适配器仍有未通过项

通过显式 opt-in 的 `tool/local_webdav/live_webdav_smoke_test.dart`，对 FN Connect 的实际备份目录运行生产适配器；全部在随机测试命名空间中：

- 1 MiB 合成文件上传后，重复不可变创建被拒绝；前后完整 SHA-256 一致，`RemoteObjectAlreadyExistsException` 符合预期。
- 后续四并发发布阶段出现 `ProviderRequestException(provider.http.401)`，并出现一次私有上传目录清理告警。整组测试 **失败**，不能把已通过的单项写成整套 NAS 验收通过。
- 外层 finally 对本轮随机测试命名空间执行清理；未见外层清理断言失败。原有备份不在该命名空间内。
- 没有猜测/改写凭据，也没有在 401 后反复发认证请求。后续 Computer Use 因 Mac 锁屏无法继续；已请用户解锁并确认记录的 WebDAV 账号是否与 Sync 一致。401 的具体原因尚未定位，不能断言为密码错误、限流或 NAS 故障。
- 生产适配器日志：`../velock_sync-artifacts/work/nas-preflight-20260925/live-fnconnect-production.txt`。小文件协议实验结果为同目录的 `*-isolated-move-results.json` / `*-read-only-results.json`。

本次没有替用户修改当前连接的文件夹路径、安装/重启 App 或触发真实业务备份。当前运行的 App 仍需更新到本次代码后再验收；完整云备份/恢复、快照和自动迁移仍保持原先未完成边界。

## 5. 分工

DeepSeek / high 经统一 worker 调度器实际完成：展示组件与测试、真实页面状态/导航整合、只读错误调用链追踪、保存位置错误分类与测试、FN Connect Destination 兼容与回归。主模型负责 Computer Use、真实 NAS 隔离实验、代码审查、测试修正和最终回归。worker 不持有 NAS 凭据、不操作真实云端；调度元数据与报告保存在项目外 work 目录。
