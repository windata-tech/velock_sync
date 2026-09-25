# 格间同步自动测试与性能验证（2026-09-19）

## 范围与口径

本轮优先验证格间 Exchange、不可变 WebDAV 对象、跨 App 恢复和重试。
用户在首轮运行中要求暂停，随后明确恢复；人为取消不计产品失败。
不抹除用户已有模拟器，不修改真实保险库；NAS 测试只操作本轮随机创建的目录并清理。
用户初始未提交的 Swift/selected-folder 测试修改保留，本轮没有提交 Git。

## 可重复入口

```bash
python3 tool/run_sync_regression.py
```

默认三个并行 worker，同时验证 Sync 全量 Flutter、格间 test/sync、Python 校验脚本、静态分析、跨仓契约、diff 与 runner 语法。整轮 180 秒预算；每个命令有超时，超时结束自己创建的进程组。任何失败均非零退出；不默认触碰 NAS 或启动模拟器。

证据通过 `ui_test_results/` 访问，真实目录在源码树外。真实 NAS 验证另行显式 opt-in：

```bash
set -a; source tool/local_webdav/nas_webdav.local.env; set +a
VELOCK_RUN_LIVE_WEBDAV=1 flutter test --no-pub tool/local_webdav/live_webdav_smoke_test.dart
VELOCK_RUN_LIVE_WEBDAV=1 flutter test --no-pub tool/local_webdav/live_webdav_performance_test.dart
```

不要把 env、密码、恢复卡或测试账号恢复文件加入版本控制。

## 已确认问题及修复

1. **NAS 忽略 PUT If-None-Match**：在独立测试对象上确认 1 MiB 原内容被 1 byte 覆盖。修复为独占临时目录流式上传后 `MOVE Overwrite:F` 原子发布；先在独立探测目录验证冲突不改字节、成功移动确实移动。没有 HEAD+PUT 或不安全 PUT 回退。
   - 同一 store 共享探测；暂时失败允许重新探测，不支持则安全拒绝。
   - 探测 20s、清理 5s 独立取消；调用者取消不取消其他调用者共享探测。
   - 单订阅上传流在 429 时不重放；清理只操作本次取得所有权的临时目录。
2. **Exchange 半发布**：READY 在 staging 内完成后再原子重命名，摘要来自实际落盘 envelope；内容匹配的旧缺 READY 包可修复。
3. **假幂等**：同 batch ID、不同 artifact 内容原来静默成功，现拒绝且保留原包。
4. **收据边界**：补充 vault/整数/ACK 路径与非空检查，逐层拒绝越界符号链接；兼容不带 vaultId 的旧收据。没有声称新增了 ACK 密码学验签。
5. **校验器假绿**：缺业务映射、附件、批次内容、revision 等可能遗漏；改为只读数据库与实际内容校验，并验证 Python 优化模式仍执行检查。
6. **测试执行与验收**：复用分离的 DerivedData（仍执行构建）；检查构建成功与预构建包标识；业务子集也必须通过持久化/convergence，不能仅数行；笔记分支补选定 sandbox；新增配置同步/冷启动解密检查，不靠短暂 toast 作为最终证据。

## 已完成实测

### 本地回归

- 原始基线：Sync 435 项 / 20.12s，格间同步 188 项 / 23.34s。
- 恢复后组合回归：Sync **492 项**、格间 **188 项**通过；Python 校验、analyze、契约、runner 自测等全部通过，**45.85s / 180s 预算**（最终组合复跑）。
- 证据：`ui_test_results/sync-regression-20260919T091559Z-88179/summary.json`。
- 最终 Python 工具90项（含11个runner预检和3个子集验收门禁），加独立组合runner自测6项；源码secret scan通过。
- WebDAV 40 项回归覆盖真实不可覆盖语义、响应丢失后重试、429 流、取消、探测暂时失败、并发与目录所有权。
- Exchange 新增 40 项故障回归，修复前失败证据保留，修复后目录 111 项通过。

### 真实 NAS

小对象协议 smoke：中文/空格路径、range、list、hash、delete、拒绝覆盖、四个竞争者仅一个成功。
原 1 MiB 文件拒绝覆盖前后 SHA-256 一致；首次上传含安全探测 **709ms**，下载 **60ms**。

100 MiB 流式附件（64KiB chunks，同环境、单次、顺序执行）：

| 指标 | 普通 PUT 基准 | 安全创建 |
|---|---:|---:|
| 上传 | 1.603s / 62.40 MiB/s | 2.301s / 43.46 MiB/s |
| 下载 | 1.346s | 1.257s |

安全上传吞吐比 **69.64%**，高于预设 **60%** 门槛。两组上传/下载 SHA-256 一致，目录 DELETE 204 后复查 404。总 6.68s。
**仅单次 provider 级样本，不是 P95、真实加解密或跨 App 端到端速度。**

### 引擎工作量

内存 store 微基准：无变化 0 业务 PUT / 0 上传字节；新增 1KiB blob 不重传历史 128KiB；批次重放不重新上传；重复下载只导入一次。计数为 store API，不等同 HTTP 请求数。报告在 `ui_test_results/agent-performance-20260919/REPORT.md`。

### 跨 App

独立 Source/Replica iOS 26.5 模拟器，不使用用户手机上的现有数据。
- 源端创建密码/卡片/笔记各1、真实配对并上传，3批次远端内容校验通过。
- 第二端从本轮恢复卡恢复同一 vault、不同设备身份。
- 暂停后继续真实配对/下载/格间导入：三类各1，密文持久化与所有源revision一致性通过。
- source首次 recorded sync_run **342ms**；不是整个注册/配对/UI流程耗时，也不是P95。
- 恢复后配对阶段 232s（含 UI 等待/操作），runner 259s；源端原初次完整 UI 流程284s。
- 证据：`ui_test_results/cross-app-20260919T085829Z-79178/`。

## 尚需后续验收／限制

配置重复同步、回执处理和冷启动解密读取已经通过：source、replica 各一次配置同步必须有新鲜 completed 数据库记录；重启后真实打开密码详情并断言合成账号 e2e-user 可读；三类持久化和revision再次通过。该组合包含安装，115秒完成，冷启动UI用例22秒。证据 `ui_test_results/cross-app-20260919T091124Z-84947/`。重复运行前后3个业务密文对象哈希与数量不变。

六类扩展此前为控制等待时间主动中止；用户再次继续后复用已有六类夹具，仅运行配置同步与重启验收，**112秒通过**。密码、卡片、笔记、文档、文件、媒体各1条均落盘，源端全部6条存活revision在副本匹配（媒体在同步模型中记为file，因此file计2）。远端6个批次的长度/hash/引用覆盖校验通过；重启后密码详情解密读取通过。证据：`ui_test_results/cross-app-20260919T092809Z-92596/`，远端核验`ui_test_results/auto-sync-20260919/six-kinds-resumed-remote-coverage.json`。本次是已有恢复空间的增量收敛，不是重新注册/全新六类恢复；尚未逐类打开解密内容或覆盖凭证附属附件。源端/副本最新sync_run单样本为82ms/53ms，不是完整端到端耗时或P95。

补充字节验收：按entity_uuid匹配两端实际文件，文件553字节、媒体5420字节的SHA-256分别完全一致，且两端六类实体集合和revision均一致。证据`ui_test_results/auto-sync-20260919/six-kinds-scoped-byte-comparison.json`。首次对六类统一要求密文相等的探索检查失败，原始结果保留在`six-kinds-entity-byte-comparison.json`；经代码核对，password/card/note导入通过`velock_codex/lib/features/credentials/presentation/browser/pages/password/core/mixins.dart:127–148`重新编码并加密，document由`velock_codex/lib/sync/bridge/sync_document_inbound_writer.dart:85–96`以本地密钥重新保存，因此不能直接比较这四类密文作为内容一致性判据。本次没有证明这四类完整明文相等；密码仅验证已知测试账号的重启解密读取。

跨端删除与冲突、完整端到端 P95、千条真实业务基准、iOS 真机 Release、Android 真机及云 Provider 账号矩阵不能视为已通过。

原子 MOVE 会增加请求与临时对象开销；不支持安全移动的 WebDAV 服务拒绝写入，需处理服务器兼容性而非跳过防覆盖。进程在远端创建临时目录后遭断电/响应丢失，可能留下不确定所有权的目录；不会擅自扫删。多进程 Exchange 同包竞争、断电持久化和符号链接检查后的竞态未专测。

## 测试框架自身问题（不计作产品同步失败）

新配置同步用例首次定位只匹配精确文本且没滚动，误报操作不可达；随后把结果弹窗造成的底层按钮 disabled 误判为仍在同步。已改为可见滚动定位，外层必须校验新鲜 completed run。保留两次失败证据，不通过重跑掩盖失败。Xcode 失败后自动 sysdiagnose 曾额外耗时数分钟；runner现禁用全机verbose诊断，保留XCTest结果/截图，并为快速用例120秒、其他用例420秒设置上限。

## 产物与构建路径验收

`ui_test_results` 是指向源码外的软链接，写入与读取均通过稳定路径完成；对该路径执行 `xattr -r -d com.apple.provenance` 实测74ms完成。构建缓存独立存放且按工程路径/Xcode/架构隔离，上锁不抢其他运行；Sync修复后增量构建28.08s。没有以跳过构建来掩盖旧包。
