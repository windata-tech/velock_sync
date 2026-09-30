# Sync 单模拟器 E2E（增量复用）

目标：一次配好之后，后续每轮只跑受影响的那一步，不重新探索界面、不把整棵无障碍树读进上下文。

## 一键全流程：`e2e.sh`（用户说“测试”就跑这个）

```bash
tool/ios_ui_test/sim/e2e.sh                 # 全新：构建 → 重装两 App → 格间造六类 → 校验 → Sync 配对备份 → 远端校验
tool/ios_ui_test/sim/e2e.sh --from backup   # 从某一步续跑（沿用本轮目录与 WebDAV 根）
tool/ios_ui_test/sim/e2e.sh --only verify   # 只跑一步
tool/ios_ui_test/sim/e2e.sh --list
tool/ios_ui_test/sim/e2e.sh --record       # 同时录屏到本轮目录 e2e-<时间>.mp4（build 之后开始，成功或失败退出都会收尾）
```

| 阶段 | 做什么 | 判定 |
| --- | --- | --- |
| build | `flutter build ios --simulator --debug`（格间加 `--dart-define=VELOCK_E2E_FIXTURES=true`），拷到 `ui_test_results/sim/apps/`，ad-hoc 签两个 App Group | 源码（lib/ios/assets/pubspec）哈希不变则跳过 |
| reset | 卸载两 App、确认 App Group 容器已清空、安装、`simctl privacy grant photos` | 仅当 UDID == `local.env` 的 `E2E_RESET_ALLOWED_UDID` |
| init | `testSeedVelockBusinessData`：建沙盒 + 账号密码 / 信用卡 / 备注 | 列表里出现各条 |
| document | `testSeedVelockDocumentOnly`：文档夹具，同时打开格间同步、生成恢复卡 | `E2E document persisted` |
| file | `testTutorialImportText`：经系统文件选择器导入 HostApp 的 proof.txt | `file-item-*` 出现 |
| photo | `simctl addmedia` HostApp 的 proof.png → `testProbeVelockMediaImport` | 相册出现图片 |
| verify | 只读格间 SQLite + App Group：六类（REQUIRED_KINDS）各有加密正文 | `source-evidence.json` |
| backup | `backup_smoke.sh`：本机 WsgiDAV → `testBackupSmoke`（首次配对/建连接/选目录/备份）→ 远端有签名 commit、7 个明文标记都不在 | `PASS remote` |

- 每次全新运行建 `ui_test_results/sim/runs/<时间>/`（日志、`webdav-root`、证据），`runs/current` 指向它；
  失败时打印 `FAILED at stage: X — … e2e.sh --from X`，修好后续跑即可，不用从头。
- 失败的 UI 步骤会打印精简树（`SMOKE_TREE_BEGIN…END`），完整 xcresult 路径在该步日志开头。
- 2026-09-30 基线（iOS 27 / iPhone 18 Pro Max）：全新一轮 6 分 39 秒（构建 78s，其余每步约 50s，含 xcodebuild 启动开销）；
  构建复用时约 5 分钟。首轮 init 偶发“账号密码未保存”的根因是新装模拟器的自动填充 helper 不回应导致保存挂起，已在格间修复（超时 + 后补重建，见格间 `docs/verification/2026-09-30-autofill-save-hang.md`）；helper 不可用时这次保存多等约 3 秒属正常。
- 默认只在单台模拟器上备份。换第二台设备恢复见下面「真实 NAS 模式」里的恢复流程（目前手动按 identifier 驱动，尚未脚本化）。

## 真实 NAS 模式（`E2E_NAS=1`）

```bash
E2E_NAS=1 tool/ios_ui_test/sim/e2e.sh --record
```

- **只能在用户明确要求联调 NAS 时使用。** 凭据和转发地址只从 gitignore 的 `tool/local_webdav/nas_webdav.local.env` 读取（包括 `WEBDAV_RELAY_URL`）。
- backup 阶段不再启动 WsgiDAV，改为 `tool/local_webdav/nas_relay_proxy.py serve`：
  - 模拟器仍然添加匿名的 `http://127.0.0.1:18991/` 连接，界面流程和本机模式完全相同。
  - 代理把请求原样按并发转发到 NAS 上每轮新建的 `e2e-<时间>/` 文件夹。它只重写路径和 Destination、注入 Basic 认证、映射 href。
  - 状态码原样透传，FN Connect 的伪 401 仍由 App 自己处理。
- 本轮 NAS 文件夹名记在 `<run_dir>/nas-run`，`--from backup` 续跑时会复用它。
- 测试结束后，代理先停止（写出 `SUMMARY peak_concurrency=… [...]`），再用 `mirror` 顺序拷回 `webdav-root`，远端检查照常在副本上做。
- 转发日志在 `<run_dir>/nas-relay.log`，每行是「方法、状态、耗时、并发数、路径」，不含主机名和凭据。
- 验收完成后用 `nas_relay_proxy.py remove --run <nas-run>` 删除 NAS 上的本轮文件夹；删除前可以再 `mirror` 一次留证据。
- `E2E_RECOVERY_CARD_IMAGE` 默认是 `<run_dir>/recovery-card.png`，恢复段从这里取恢复卡。
- 调用时传入的 `E2E_SIMULATOR_UDID` 优先于 `local.env`，可以用同一套 `ui.sh` / `tap.sh` 驱动第二台模拟器。
- 停止运行中的 e2e 时，不要直接杀整个脚本，应该杀掉 `xcodebuild`，让脚本的 trap 收尾：
  - 直接杀掉会留下孤儿录屏进程，之后模拟器报 `Host recording is already in progress`；
  - 出现这个报错时，对该模拟器 `simctl shutdown` 再 `boot` 即可。

### 恢复到第二台模拟器（replica，手动按 identifier）

准备：新建一台专用 `Velock ...` 模拟器，安装同一对 App，把 `recovery-card.png` 用 `simctl addmedia` 加入相册。再起一次代理，指向同一个 `nas-run`。

1. Sync：`velock-cloud-restore` → `restore-download-recovery` → 添加或选择 `127.0.0.1:18991` 连接 → `use-backup-folder`（下载密文恢复文件）。
2. 格间：`restore-open-velock` → 恢复一个账号 → 从二维码恢复 → 允许相机 → 从相册选恢复卡 → 恢复账号。
3. Sync：打开「我已在格间恢复原来的账号」开关 → `restore-continue` → `inspect-velock-readiness` → 解锁格间 → `approve-sync-request` → `return-to-sync`。
4. Sync：`use-backup-folder` → `finalize-velock-profile`，页面显示「已下载，等待格间恢复」。
5. 打开格间并解锁，格间应用快照。
6. **回 Sync 详情，点 `backup-check-restore`（检查恢复进度）**。恢复配置在回执确认之前不会在后台运行，「刷新状态」不会推进这一步。状态变为「上次备份已完成」后，NAS 上会出现签名 ACK。

验收要求：

- 格间数据库里六类数据都在；文件和照片的 blob 与源设备字节一致。账号、卡、备注、文档会重新加密，hash 不同属正常。
- 界面逐一打开账号、卡、备注正文、文件正文、照片原图。
- 结束后删除 replica 模拟器和 NAS 上的本轮文件夹。

## 前提

- 模拟器上已装好格间与 Sync（Debug）。只改了 Sync：`flutter build ios --simulator --debug` 后
  `xcrun simctl install <UDID> build/ios/iphonesimulator/Runner.app`，不用重建格间、不用擦模拟器。
- `cp tool/ios_ui_test/sim/local.env.example tool/ios_ui_test/sim/local.env`（已 gitignore，权限 600），
  填模拟器 UDID、格间测试沙盒的解锁密码与沙盒名。只开着一台模拟器时 UDID 可以留空。
- 本机 WsgiDAV：`ui_test_results/webdav_venv/bin/wsgidav`（`backup_smoke.sh` 自己启停，匿名、只听 127.0.0.1）。
  默认模式**不连用户 NAS**；只有显式 `E2E_NAS=1` 才会连（见上节）。

## 脚本（`tool/ios_ui_test/sim/`）

| 脚本 | 用途 |
| --- | --- |
| `ui.sh [正则]` | 当前屏幕的精简树：`类型 \| 标签 \| identifier \| 中心坐标`，可按正则过滤 |
| `tap.sh <identifier> [秒]` / `tap.sh <x> <y> [秒]` | 按 identifier（或坐标）物理点击，然后打印 `ui.sh` |
| `run_test.sh <测试名> [KEY=VALUE…]` | 只跑 CrossAppUITests 的一个方法；完整日志在 `ui_test_results/sim/<测试名>.log`，终端只打 PASS/FAIL 和过滤后的树 |
| `e2e.sh [--from X \| --only X]` | 上面的一键全流程 |
| `backup_smoke.sh [KEY=VALUE…]` | 起本机 WebDAV → `testBackupSmoke` → 校验远端有签名 commit、没有明文标记 → 停服务 |

`xcodebuildmcp` 测试失败时也可能返回 0，脚本以日志里的 `✅ N test passed, 0 failed` 为准。

## testBackupSmoke 走的路径

只按 Flutter widget key 发布的 accessibility identifier 定位（`withAutomationId`），改文案、切语言都不影响：

- 已有备份：`backup-primary-action` → 等 `backup-status-title` 变成「上次备份已完成 / Last backup completed」。
- 首次：`velock-backup-enable` → `inspect-velock-readiness`（授权问题时是 `renew-velock-authorization`）
  → 系统「打开」弹窗 → 解锁格间 → `approve-sync-request` → 回到 Sync
  → `go-create-connection` → `protocol-webDav` → `webdav_https` → `webdav-allow-http`
  → `webdav_address` / `webdav_port` → `webdav-save`
  → （有多个连接时选 `velock-connection-*` 中端口匹配的那个）→ `use-backup-folder` → `finalize-velock-profile`
  → 等状态卡完成。

失败时 XCTFail 附带只含 identifier/label 的前 120 行树（`SMOKE_TREE_BEGIN…END`），`run_test.sh` 直接打印它。

`E2E_WEBDAV_ROOT` 要与已有备份配置指向的目录一致（默认 `ui_test_results/sim/webdav-root`，跨轮保留）。
`E2E_PLAINTEXT_MARKERS=a,b` 可检查上传对象里不含格间里造的明文。`E2E_HOLD_SECONDS` 让测试结束前停留，便于手动接着操作。

## 与此相关的产品行为

- 没有任何云端连接时，向导在格间批准后直接把「添加云端位置」作为主按钮，不再只弹提示。
- 已发给格间的配对请求（只有公开标识与随机 challenge，没有密钥/批准内容）持久化 ≤5 分钟：
  Sync 在用户去格间批准期间被系统杀掉，回来后会重新向格间取回批准并完整验签后继续；过期、换了格间身份、
  或意图（备份/恢复、替换哪个配置）不同的记录会被丢弃，从头配对。

## 验证记录

- 2026-09-30：iOS 27 / iPhone 18 Pro Max 模拟器，已有备份配置路径 `backup_smoke.sh` 通过（测试 21s）。
- 2026-09-30：`e2e.sh` 全新安装一轮全部通过：六类各 1 条入库，首次配对路径 `testBackupSmoke` 47s，远端 4 个 commit、7 个明文标记均不存在。
- 2026-09-30：`E2E_NAS=1` 真实 NAS（经 FN Connect）全新一轮备份通过：commit 0→4、无明文，转发日志 401 = 0、峰值并发 2。随后在 replica 模拟器上从 NAS 恢复：六类入库，5 类界面正文 / 原图核对，ACK 1–4 发布，401 = 0。详见 `docs/verification/2026-09-30-fnconnect-concurrent-401.md`。
