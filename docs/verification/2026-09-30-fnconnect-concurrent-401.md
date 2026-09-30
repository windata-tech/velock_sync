# FN Connect 并发 401 与真实 NAS 备份 / 恢复端到端验收（2026-09-30）

承接 `cloud-backup-follow-up.md` 的遗留：真实 NAS 经 FN Connect 转发时，四并发阶段报 `provider.http.401`，整组 live test 未通过；
完整备份与恢复只在本机 WsgiDAV 上跑过。本文件不含真实域名、IP、NAS 路径或共享名；凭据与转发地址只在 gitignore 的
`tool/local_webdav/nas_webdav.local.env`（`WEBDAV_RELAY_URL` 等）。

## 1. 根因

- 顺序请求总能通过；两个及以上请求在约 50 ms 内先后到达、且前一个还没应答时，FN Connect 转发层返回
  `401 Basic realm="Restricted"`，与密码错误完全相同。起始间隔 ≥100 ms 时未再出现。
- 这个 401 是转发层在转给 NAS 之前就拒绝的：被拒请求没有在服务器上产生任何效果，重放是安全的。
- 局域网直连同一台 NAS、同一账号，四并发全部通过，所以不是账号、密码或 NAS 本身的问题。

## 2. 修复：`WebDavAuthRaceGuard`

实现在 `lib/providers/webdav/webdav_auth_race_guard.dart`。同一进程内，每个「endpoint origin + sha256(账号)」共用一个实例，注册表里不保存密码。

- **错开起始**：如果上一个请求还没应答，下一个请求要等到距它开始 200 ms 后才发出；上一个一旦应答就立即放行。
  所以顺序流程和局域网上的快服务器基本不受影响（加守卫后局域网 1 MiB 上传 531 ms）。
- **有界重试 401**：只重试可以重放的请求，带抖动（250 ms × 第几次 + 0–250 ms）。
  - 这个账号在本进程里还没成功过时，最多重试 1 次，避免对真的错密码或锁定策略反复试。
  - 成功过一次后最多重试 3 次。
  - 其他 HTTP 状态也算「服务器接受了凭据」。
  - 403 不重试。
  - 调用方传入的上传流（`_putBody`）不重放，401 原样上抛。
- **接入范围**：`WebDavObjectStore._request` 用于生产同步读写；另外接入了备份目录浏览器、连接测试和远端文件列表（`webdav_backup_folder_browser.dart`、`protocol_provider.dart`、`files_provider.dart`）。
- **不放宽的门禁**：`Overwrite: F`、碰撞 412、字节回读校验、不回退到普通 PUT，这些都保持原样。

### 与旧规则的关系

`2026-09-26 备份目录选择` 写过「不自动重试 401/403」。现在对 401 改为上面这种有界重试：未证实的账号最多 1 次，所以真的错密码仍然很快失败，不会反复打认证。403 仍然不重试。

## 3. 测试

- `test/providers/webdav/webdav_auth_race_test.dart` 新增 11 项，用内存 WebDAV fake 模拟「近同时请求返回 401」的转发层：
  - 四个请求抢同一个 key：一个成功，其余走冲突，没有 401；
  - 八个并发上传到不同 key：全部发布；
  - 并行列目录能从伪 401 中恢复；
  - 错开起始的时序；
  - 未证实的账号只重试 1 次；
  - 上传流不重放；
  - 取消能打断退避等待；
  - 注册表的隔离。
- 变异检查：
  - 起始间隔改成 0、保留重试：4 项失败；
  - 关闭重试、保留间隔：对应用例失败。
  - 两个变异都已还原。
- 全量 1400 项通过（1 项跳过），`flutter analyze` 无问题。

## 4. 真实 NAS live test（生产适配器，`tool/local_webdav/live_webdav_smoke_test.dart`）

每轮新建一个随机子目录，结束后删除，不碰已有数据。测试包含四并发阶段：同 key 原子 MOVE 竞争、并发上传和并发列举。

| 路径 | 结果 |
| --- | --- |
| FN Connect，加守卫，第 1–3 轮 | 3/3 全部通过，401 = 0，重试 = 0，每轮 47 个请求；1 MiB 上传 4–5.3 s |
| FN Connect，**对照：去掉守卫** | 失败，401 × 3（两次 MKCOL、一次 DELETE，都带 `challenge=Basic`），问题可稳定复现 |
| 局域网直连，加守卫 | 通过，401 = 0，重试 = 0；1 MiB 上传 531 ms |

加守卫后三轮的重试次数都是 0：错开起始本身就消除了近同时到达，重试只是兜底。结束时测试目录为空，无残留。

## 5. 真实 NAS 上的备份 → 恢复端到端

### 5.1 转发代理 `tool/local_webdav/nas_relay_proxy.py`

- 模拟器只看到匿名的 `http://127.0.0.1:18991/`，和本机 WsgiDAV 模式一样。NAS 地址和凭据不会进入模拟器、UI 测试或 xcodebuild 日志。
- 代理把请求按原有并发转发到 NAS 上每轮新建的文件夹 `<WEBDAV_RELAY_URL>/e2e-<时间>/`。它只做三件事：
  - 重写请求路径和 `Destination`；
  - 注入 Basic 认证；
  - 把 207 响应里的 href 和 `Location` 映射回来。
- 状态码、其余响应头和响应体原样透传，所以 FN Connect 的伪 401 仍然会到达 App，由 App 自己的守卫处理。代理不重试。
- 调试时修掉的两个代理自身 bug（均不是产品问题）：
  - 客户端发来的小写 `destination` 头没有被删掉，与重写后的头重复，MOVE 因此 403；
  - 204/304 响应写了分块结束符，污染了 keep-alive 连接，下一条 MKCOL 报 `502(BrokenPipeError)`。
- 子命令：`serve`（服务）、`mirror`（把本轮文件夹顺序拷回本机）、`remove`（删除本轮文件夹）。

### 5.2 备份（源设备，`E2E_NAS=1 tool/ios_ui_test/sim/e2e.sh --record`）

- 全新重装两个 App，格间里六类数据各造 1 条：文件、照片、账号密码、信用卡、备注、文档。
- 首次配对，添加 WebDAV 连接，完成备份。
- 远端 commit 从 0 增加到 4；把 NAS 上的文件拷回本机检查，7 个明文标记都不存在。
- 转发日志：401 = 0，5xx = 0，峰值并发 2。按类型计数：
  - PUT 201 × 22，MOVE 201 × 19，MOVE 412 × 2（防覆盖探针，预期）；
  - MKCOL 201 × 38，DELETE 204 × 20。

### 5.3 恢复（另建专用 replica 模拟器，两 App 全新安装，按 identifier 手动驱动）

步骤：

1. Sync：`velock-cloud-restore` → `restore-download-recovery` → 选 WebDAV 连接 → `use-backup-folder`，下载 `velock-recovery-*.json` 密文恢复文件。
2. 格间：`restore-open-velock` → 恢复一个账号 → 从二维码恢复 → 从相册选源设备导出的恢复卡 → 恢复账号。
3. Sync：打开「我已在格间恢复原来的账号」开关 → `restore-continue` → `inspect-velock-readiness` → 解锁格间 → `approve-sync-request` → `return-to-sync`。
4. Sync：`use-backup-folder` → `finalize-velock-profile`。页面显示「已下载，等待格间恢复」。
5. 打开格间并解锁，格间应用快照。
6. **回到 Sync 详情，点 `backup-check-restore`（检查恢复进度）**，状态变成「上次备份已完成」，已签名的 ACK 发布到 NAS。

第 6 步是必须的：恢复出来的配置在确认回执之前不会在后台运行，停在「等待格间恢复」时点「刷新状态」不会推进，这是设计如此，不是卡死。

结果：

- 格间数据库里六类数据都已落库。文件和照片的 blob 与源设备字节一致；账号、卡、备注、文档在应用时重新加密，所以 hash 与源设备不同，属预期。
- 界面逐一打开核对了 5 类的正文或原图：账号详情、信用卡详情、备注正文、文件正文、照片原图。文档只在宿主数据库层面核对（手机界面上没有文档展示）。
- NAS 上出现 ACK 1–4。恢复后拷回的副本有 23 个文件、57 688 字节，无明文。
- 恢复段的转发日志：401 = 0，5xx = 0，峰值并发 2。

### 5.4 清理

- 恢复验证结束后，已用 `remove` 删除本轮 NAS 文件夹（HTTP 204）；更早一轮失败 take 的文件夹也已删除。
- replica 模拟器已删除。源模拟器保留：它是 `local.env` 指定的 E2E 设备，供增量复用。
- 代理和录屏进程均已停止。
- 证据保存在仓库外：`ui_test_results/sim/runs/20260930-170507/`，这是符号链接，指向 `../velock_sync_test_results`。包括：
  - 备份录像 `e2e-170511.mp4`、恢复录像 `replica-restore.mp4`；
  - `source-evidence.json`；
  - 转发日志 `nas-relay.log` / `nas-relay-restore.log`；
  - 恢复卡图片（含秘密）。
- 这些证据只存本机，不得公开。

## 6. 边界（如实说明）

- 端到端这两段的峰值并发只有 2。四并发下没有 401 的证据来自第 4 节的 live test，不是来自这两段。
- 端到端流量经过本机代理，代理替换了 TLS、Host 和认证方式，其余透传。App 直连 FN Connect 的四并发由第 4 节覆盖；App 直连 NAS 的完整 UI 流程没有跑。
- 构建是 Debug 模拟器版，不是真机或 Release。
- 恢复段是按 identifier 手动驱动的，还没有固化成一条可以重复运行的 XCTest 或脚本阶段。
- 文档只在数据库层面验证过，没有在界面上展示过。
- 如果以后换成其他转发服务，出现不同时序的伪 401，未证实账号只重试 1 次的限制仍可能不够。遇到这种情况应先抓请求时序，而不是加大重试次数。
