# Sync 单模拟器 E2E（增量复用）

目标：一次配好之后，后续每轮只跑受影响的那一步，不重新探索界面、不把整棵无障碍树读进上下文。

## 一键全流程：`e2e.sh`（用户说“测试”就跑这个）

```bash
tool/ios_ui_test/sim/e2e.sh                 # 全新：构建 → 重装两 App → 格间造六类 → 校验 → Sync 配对备份 → 远端校验
tool/ios_ui_test/sim/e2e.sh --from backup   # 从某一步续跑（沿用本轮目录与 WebDAV 根）
tool/ios_ui_test/sim/e2e.sh --only verify   # 只跑一步
tool/ios_ui_test/sim/e2e.sh --list
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
  构建复用时约 5 分钟。首轮 init 出现过一次偶发“账号密码未保存”，重跑即过，已加树输出，再出现时直接看输出定位。
- 未覆盖：换第二台模拟器的恢复（需要 replica 设备，走 `docs/testing/tutorial-recording.md` 的双机流程）。

## 前提

- 模拟器上已装好格间与 Sync（Debug）。只改了 Sync：`flutter build ios --simulator --debug` 后
  `xcrun simctl install <UDID> build/ios/iphonesimulator/Runner.app`，不用重建格间、不用擦模拟器。
- `cp tool/ios_ui_test/sim/local.env.example tool/ios_ui_test/sim/local.env`（已 gitignore，权限 600），
  填模拟器 UDID、格间测试沙盒的解锁密码与沙盒名。只开着一台模拟器时 UDID 可以留空。
- 本机 WsgiDAV：`ui_test_results/webdav_venv/bin/wsgidav`（`backup_smoke.sh` 自己启停，匿名、只听 127.0.0.1）。
  **不连用户 NAS。**

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
