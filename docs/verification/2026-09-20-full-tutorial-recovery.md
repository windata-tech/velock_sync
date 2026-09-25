# 全内容教程恢复：2026-09-20

范围：首次配置同步、另一设备从同一完整备份恢复。不是旧空间迁移到空远端的全状态快照协议验收。

## 修复与证据

- 中文首次录制的源设备确有文件、相册、普通账号、信用卡、备注、文档，首次上传远端3个完整批次。
- 最初恢复段下载成功，但 companion dashboard 首个凭证的本机加密回读校验收到原生空输出，事务回滚，其余批次未消费。冷启动后同一完整备份可导入全部六类。
- 凭证事务明文此前与生命周期/解锁扫描管理的 `decrypt_dir` 共用父目录，并且写入共用 `temp_file.txt`。这存在并发清理及同类型并发写覆盖窗口；原生加密调用本身等待完成才返回。
- 修复：凭证 IO 改用独立 `credential_io_temp`；每次写入独占目录；成功/失败都清理操作明文；启动清理崩溃残留；仍保留加密文件回读验证与失败回滚。不把瞬时目录消失假设冒称有失败瞬间目录实证。
- 新增回归将凭证 crypto guard 从1项扩展为8项；主动删除 preview cache 后验证仍能完成，并覆盖重叠写入、空 native output、异常和残留清理。凭证及 temp store 共72项通过。
- 修复版在全新恢复设备实测全部六类可导入。中文 `zh-recovery-fixed-04` 完整录制 exit0，五类真实 UI 打开通过；host核对六类记录/版本，文件和相册加密字节一致。

## 录制可靠性

- 修复新空文件页误匹配“添加”说明、首次系统文件选择器在 Recents 的假设。
- 配对 deep link 可叠加同步设置页；返回脚本依据真实页面逐层退回，导航按钮限制在顶部区域。
- 多次失败实验的 join request 会引发真实产品审批弹窗，不应在教程中误批准。保留原远端，重录使用完整源备份隔离副本；中文历史副本只排除了失败试验生成的临时 join request，全部业务与协议文件逐字节一致，原件不变。
- 新版 recorder 在首次源上传通过完整性校验后、任何恢复设备参与前冻结完整 `pristine-remote` 和对应恢复卡。以后从冻结副本克隆重录，避免手工整理申请。
- 所有失败片私有保留，不进入交付；原生录制，不裁剪、拼接或加速。

运行、QA及最终交付清单见项目外 `ui_test_results/tutorial-20260919/fresh-full`。英文与最终文件清单待实际通过后补充，本文不提前宣称其完成。

## 英文实测更新

`en-production-nav-02` 五类正文/原图通过；`en-recording-01` 首次配置源段通过并自动冻结完整 pristine 远端。英文系统 QuickLook 关闭按钮使用小写 label，脚本改为其原生稳定 identifier 后，`en-recovery-fixed-02` exit0/no recorder errors，五类 UI 与六类 host/revisions、文件及相册加密字节一致性全部通过。英文系统与仅切换 App 英文不是同一测试条件，已固化差异。

## 重要纠正：最后一轮压力复验发现真正的间歇损坏根因

`zh-recovery-fast-05`（已确认 kernel 含新的 credential_io_temp/credential_write_）仍在 Note 的原生回读得到空 output，Password/Card已写入而其余内容未导入。故目录隔离是并发加固，**不能据早先若干成功 take 宣称它已解决此次间歇失败**。该失败片不交付。

独立 native C API 串行300次合成数据加密→解密（无Dart、无清理并发）：298成功、2失败，对应随机padding9与2。原生源码 `/Users/parcool/CLionProjects/crypto_new/src/file_processor.cpp` 的 `updateHeaderInfo` 计算hash位置多加了文件头中不存在的12字节IV；当padding<12，会覆盖密文前12-padding字节。原项目shipped库反汇编也确认了偏移差，且与外部源码工程的iOS.framework hash一致。正在修复/重建底层库并重新验收，不能仅选择成功录像掩盖这个缺陷。


## Native 修复交付与回归（2026-09-20 后续更新）

本节更新上一节“正在修复/重建”的状态，不把目录隔离当作本次随机损坏的完整根因。

- 已修正 `crypto_new/src/file_processor.cpp` 的 hash 偏移，多出的12字节不再写入密文；保持旧文件布局及 C API ABI。GCM 认证失败不再吞掉继续处理，关闭并删除已写出的部分明文，通过既有 error JSON 契约失败关闭（fail closed），不返回成功 output。另加短 GCM 块长度保护。
- `aes_algorithm.cpp` 的缓存标识绑定 password digest + salt digest，不缓存明文密码作为 key；验证同 salt 的错误密码被拒绝，并移除派生密钥片段日志。
- 合成数据完整回归通过：**432 次新文件 round-trip = 400 次串行 + 32 次并发**，回读原文逐字节一致；另有 **17 个 padding 边界：0–11、12、13、32、255、1023**，验证实际 header updater 不改变密文且解密一致。另验1份旧库生成的合法旧文件、同 salt 不同密码、后续块 GCM 失败、截断及短块错误；失败不遗留部分明文。边界及负向用例不计入432次。
- 源工程 `/Users/parcool/CLionProjects/crypto_new`，基线 commit `a3a642cb4fa1f26cf0bbd66dc5461675dadc9fb2`；既有 `.DS_Store` 改动保留。交付目录 `/Users/parcool/CLionProjects/crypto_new-artifacts/fix-20260920/` 中的 `native-crypto-fix.patch`、`results.json`、`provenance.json` 分别记录源补丁、结果、完整构建命令/源码/SDK/OpenSSL及二进制 SHA。后续 README 文档补充不改写该历史构建 provenance。
- 已交付独立 `VenyoreCrypto.xcframework`，device/simulator 均 arm64，SDK27，最低 device13 / simulator14。主任务已报告集成双 slice 并发起 MCP 构建；此处不据此宣称新 App 真机/录像验收完成。本 sidecar 没有设备或模拟器操作，**未做 Android 库重建或验证**。

二进制 SHA-256：

```text
device:    69848b0038d0b683d4dc5d25d277f3874da28c04e783506cd7e3edac91c7b8b4
simulator: dd33341588c2a4357c324431f6159d19eac37489f2baf5bedb0511d1c6440304
```

测试与重建（选一个新的输出目录，构建器拒绝覆盖已有 XCFramework）：

```bash
cd /Users/parcool/CLionProjects/crypto_new
export ARTIFACTS_DIR=/Users/parcool/CLionProjects/crypto_new-artifacts/native-recheck-$(date +%Y%m%d-%H%M%S)
bash tests/run_native_regression.sh
python3 tests/build_ios_artifacts.py "$ARTIFACTS_DIR"
```

复现旧偏移缺陷及更多依赖/命令见 `/Users/parcool/CLionProjects/crypto_new/tests/README.md`。所有回归只用合成数据。**已被旧库覆盖的密文字节无法由本修复恢复**；需从可信原文或完整未损坏备份重新生成，不能把旧坏密文重新解密成功作为承诺，也不能放松凭证回读校验或失败回滚。

## 修复版跨设备最终验收

iOS device/simulator双slice已集成companion，MCP Debug模拟器构建成功；实际App内Mach-O UUID与新simulator产物相同。原始旧framework备份留在私有产物。

- 中文 `zh-native-fixed-01`：exit0/errors[]；运行199秒，原始恢复视频115.475秒；cross-app-20260919T170040Z-68064。自动0.2秒扫描578点无错误/停留告警，人工21帧核实五类正文/原图。
- 英文 `en-native-fixed-01`：exit0/errors[]；运行218秒，原始恢复视频116.245秒；cross-app-20260919T170422Z-69872。最终视频QA另记。
- 两次均使用原完整源备份的隔离副本、全新擦除的专用替换模拟器，未擦除源或旧用户设备。六类业务记录/版本一致，文件和照片加密字节一致；凭证明文不由host导出，正文及详情由真实UI断言。
- 首次配置原片保留 `zh-recording-01`（95.118秒）和 `en-recording-01`（94.113秒），各自五类UI及源/远端完整性早已通过。它们不需要靠重录/删历史绕过恢复问题。
- 四片均1320×2868、1视频轨、0音轨，交付复制与原生录屏SHA256逐一相同，未剪辑/变速/重新编码。

交付目录：项目外 `tutorial-20260919/fresh-full/delivery-full-20260920-debug-withdrawn`，包含四原片、中英手册与范围说明；失败录像和私有诊断均不进入该目录。

最终英文原片QA：582个0.2秒采样无错误命中、无近静止告警；两段同标签区间经31帧人工复核为正常解锁、导航与内容切换，接受。五类内容可见、QuickLook返回正常，无阻断弹窗或结尾桌面；“最近删除”漏译如实记录。四段原片均通过对应业务门禁及视频QA，8个交付文件的SHA256SUMS全部校验通过。最终目录不含失败take或私有凭据/日志。


## 教程交付撤回（2026-09-20）

四段早期视频虽然通过业务门禁，但为 Flutter iOS Simulator Debug 构建且节奏不适合用户观看。目录已改名为 `delivery-full-20260920-debug-withdrawn` 并加 `WITHDRAWN.md`，不得对外发布。Release 版本需要两台物理 iOS 设备；模拟器无法构建 Flutter Release/Profile，不能以 Debug 冒充。


## 节奏校正交付（2026-09-20）

新目录 `tutorial-20260919/fresh-full/delivery-pace-20260920` 包含四段未剪辑原始录屏：中文首次配置138.98秒、中文恢复160.07秒、英文首次配置139.05秒、英文恢复157.46秒。关键内容页停留约2.3秒、点击过渡0.45秒、表单输入0.6秒、同步结果2.4秒。

四段均通过六类 host 持久化/收敛、文件和相册加密字节一致性及五类 UI 打开门禁；录像进程 exit0。`run_qc.sh` 0.2秒采样未发现错误弹窗，自动产生的同标签停留区间已通过人工抽帧确认是表单输入、页面切换和内容查看，不是冻结。

本版仍是 Flutter iOS Simulator Debug 应用（用户已明确接受）；它不是 Release 真机版本，也不再使用早期 `delivery-full-20260920-debug-withdrawn`。新增的 debug-only `SYNC_DIAG upload_failed=<runtimeType>` 仅用于后续诊断，不改变生产行为。
