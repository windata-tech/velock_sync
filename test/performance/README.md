# Sync engine microbenchmark（非 E2E）

仅测试 `SyncProfileRunner` / `SyncUploadEngine` / `SyncDownloadEngine`，使用真实的内存 SQLite 状态库与 `InMemoryObjectStore`。复用现有 `test/sync_core` runner/upload/download 测试中的轻量 dataset、故障注入、重复列表与合法传输哈希 fixture 模式；没有导入其他测试文件的私有 fixture。

**不覆盖**：真实 Velock exchange adapter、App Group、真实签名/加密、文件扫描、磁盘持久化/进程崩溃、UI、WebDAV/NAS、HTTP 或网络性能。合成字节虽然带正确 SHA-256，但并非实际加密业务数据。下载 adapter 故意不自行去重，避免掩盖引擎重复投递。这里的幂等只指当前引擎状态机和持久状态接口，不代表完整 App 的 exactly-once 保证。

## 运行

单次（无需 pub、设备或服务）：

```sh
flutter test --no-pub test/performance/sync_engine_microbenchmark_test.dart --reporter expanded
```

两次独立测试进程并留证据：

```sh
bash test/performance/run_engine_microbenchmark.sh \
  /Users/parcool/AndroidStudioProjects/velock_sync_test_results/agent-performance-20260919
```

脚本统一使用 `ROOT_DIR` / `ARTIFACTS_DIR`，默认产物在项目外的 `../velock_sync_test_results/engine-microbenchmark`，不在源码树内生成不断增长的结果目录。读取也使用同一个 `ARTIFACTS_DIR`；无须迁移或改动现有目录/软链接。`run-1` / `run-2` 分别含 `suite.log`、`exit-code.txt` 与 `engine-microbenchmark.json`。重跑会覆盖相同输出目录；保留多份证据时传不同目录。

单次也可设置 `ENGINE_MICROBENCHMARK_OUTPUT_DIR` 输出 JSON；不设置则只输出以 `ENGINE_MICROBENCHMARK ` 开头的 JSON 行。JSON 在 teardown 时写出，失败时可能只含部分场景，**必须同时检查测试退出码/日志**。

## 度量与硬门槛

- 请求数是 `RemoteObjectStore` 边界的 `stat/list/read/put/delete` 调用数（含尝试），不是 HTTP 请求数；不重复计数 delegate 内部操作。
- 上传字节按 `put` **实际消费的 stream chunk** 累加，不用声明 `contentLength`、SQLite `completedBytes` 或文件总大小代替。
- 业务 objects 指 blobs、batch operations/envelope/commit；protocol、ACK 不计业务上传，但其请求和总上传字节独立保留。
- `elapsedMicros` 使用 Stopwatch，包含引擎调用、内存 DB、fixture 与测量闭包中的结果断言；不含 fixture 构造/DB 初始化、Flutter 启动和编译。`suite.log` 的 `real` 才是整个命令耗时。
- `cold` 只表示空远端首次初始化；`warm` 表示同一 fixture 后续运行，不代表磁盘/网络冷热缓存。样本少，不计算吞吐、p95 或跨机器性能优劣。
- 硬门槛：精确每方法请求次数、精确业务上传字节、历史 blob PUT 为零、同批次传输任务数不增长、重复下载导入数不增长。每操作 15 秒/每测试 30 秒只是宽松卡死保护，避免 CI 毫秒级抖动误报。

| 场景 | stat/list/read/put/delete | 业务 PUT | 业务上传字节 |
|---|---|---:|---:|
| 首次空 profile | 1/1/0/1/0 | 0 | 0（仅创建 protocol） |
| 空/已有数据后无变化，分别重复 3 次 | 1/1/1/0/0 | 0 | 0 |
| 首批 8 × 16 KiB blob | 12/1/1/11/0 | 11 | 131072 + 批次正文/commit |
| 新增 1 KiB，仍引用全部 8 个历史 blob | 13/1/1/4/0 | 4 | 1024 + 新批次正文/commit |
| 远端已提交、本地确认故障 | 4/0/0/4/0 | 4 | 4096 + 批次正文/commit |
| 故障重试/显式重放原批次，共 3 次 | 4/0/0/0/0 | 0 | 0 |
| 下载列表重复条目，首次导入 | 1/1/4/1/0 | 0 | 0（另上传 1 字节合成 ACK） |
| 重建下载 engine 再运行，共 3 次 | 0/1/0/0/0 | 0 | 0 |

profile 中指定一个空的可信对端，确保空同步实际经过 commit discovery，而不是用空 allow-list 跳过下载。小增量 fixture 特意重引用历史 blob，验证去重是引擎完成的。批次正文大小通过固定 fixture 计算；明细 JSON 包含按 key 的实际字节和读写 key。

轻量规模只覆盖一个列表页，不声称验证大规模目录/批次线性复杂度。请求预算是有意设置的回归基线；若协议演进导致合法变化，应评审原因并同步修改说明，不能只为让测试通过而放宽。
