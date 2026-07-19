# PRD / Technical Spec 实现与验收状态

本清单把首个可发布版本与技术规格的要求映射到当前仓库中的实现和可重复执行的验证。它不把尚未交付的外部系统视为已完成。

## 已确认的平台边界

- **Velock managed data 的 V1 主链路是 iOS/iPadOS**：独立 Velock 与独立
  Velock Sync 只通过专用 Exchange App Group 交换不透明密文包和配对控制文件。
- Velock 本体尚无 Android 版本，因此 Android ContentProvider/签名权限桥只作为
  未来兼容实现保留，不是 V1 首发入口，也不是 V1 发布完成的阻塞项或验收矩阵。
- **非 Velock 数据集保持跨平台**：Selected Folder、WebDAV 和云盘 Provider
  继续支持 Android 与 iOS；Android 的目录授权、后台调度和发布签名仍属于这些功能的验收范围。

## 已在本仓库实现并有验证

| 规格范围 | 当前实现 | 验证证据 |
| --- | --- | --- |
| 增量双向协议、不可变 batch/blob/commit、重放防护、版本向量、tombstone 与冲突副本 | `lib/sync_core/`、`lib/dataset_adapters/selected_folder/` | `test/sync_core/`、`test/dataset_adapters/selected_folder/`、`test_vectors/protocol_v1/` |
| 普通文件夹 Generic Vault | 每个新配置生成独立 Root Key、Ed25519 身份和不透明安全存储引用；默认端到端加密 | `selected_folder_profile_provisioner_test.dart`、恢复/加密/下载集成测试 |
| 首次同步、checkpoint、恢复与垃圾回收 | 初始风险确认、checkpoint 发布/恢复、设备确认后回收 | `initial_sync_assessment_test.dart`、`sync_checkpoint_*_test.dart`、`sync_garbage_collector_test.dart` |
| 状态、崩溃恢复、临时空间与可观测性 | SQLite 状态、transfer job、错误分类、暂存预检与安全清理 | `sync_state_database_test.dart`、`staging_*_test.dart`、`sync_failure_test.dart` |
| WebDAV | HTTPS 默认、HTTP 明确确认、路径校验、凭证安全存储、编辑/替换及连接测试 | `webdav_object_store_test.dart`、`connection_reauthorization_test.dart` |
| Google Drive 与 OneDrive | 系统浏览器 OAuth + PKCE、最小 scope、刷新、撤销、远端目录选择、流式/可恢复上传 | `test/providers/google_drive/`、`test/providers/one_drive/`、`test/providers/oauth/` |
| 后台与前台触发 | 手动、前台、网络恢复、Android WorkManager/iOS BGTask；Wi-Fi、充电与蜂窝限额 | `test/background/`、`foreground_sync_coordinator_test.dart` |
| 供应链与凭证防护 | CI 中的格式、Flutter 分析、独立 custom lint、测试、Android 构建、许可存在性与源树密钥扫描 | `.github/workflows/quality.yml`、`tool/check_dependency_licenses.dart`、`tool/verify_no_secrets.dart` |
| iOS Velock 信任边界 | 固定专用 App Group；严格 descriptor/request/response/decision/consumed 文件；不读取 Velock 数据库或密钥 | `apple_pairing_control_channel.dart`、两仓 entitlements 与 iOS 原生桥 |
| Android Velock 未来兼容边界 | 默认禁用；authority、包名和签名摘要必须显式提供，并在每次 IPC 前验证；不作为 V1 首发链路 | `MainActivity.kt`、`docs/ANDROID_VELOCK_EXCHANGE.md` |
| Android 发布签名 | 仅在完整 keystore 配置存在时生成 Release 包；不会回退到 Debug key | `android/app/build.gradle.kts` |

## 可重复执行的本地检查

```bash
flutter test
flutter analyze
dart run custom_lint
dart run tool/check_dependency_licenses.dart
dart run tool/verify_no_secrets.dart
cd android && ./gradlew :app:assembleDebug --console=plain
```

iOS 使用 XcodeBuildMCP 的 `build_sim`，并先读取会话默认 workspace、scheme 和 simulator。

Android Release 构建还必须通过受保护的 CI secret 或本机受保护属性提供
`RELEASE_STORE_FILE`、`RELEASE_STORE_PASSWORD`、`RELEASE_KEY_ALIAS` 与
`RELEASE_KEY_PASSWORD`；缺少任一项时 Release 签名校验会失败。

`custom_lint` 以独立命令运行，而不是注册为分析服务插件；当前 Dart 3.12.2 下，后者会使分析服务崩溃。这样 Flutter 分析和 Riverpod lint 均可独立、稳定地作为 CI 门禁运行。

## 已实现但尚未接入真实业务的格间链路

`/Users/parcool/AndroidStudioProjects/velock_codex` 已包含 iOS 专用 Exchange
App Group、加密 outbox/inbox、协议 codec，以及未来 Android 兼容用的签名权限 ContentProvider，
变更日志 schema 及 importer/exporter，并且 `flutter test test/sync` 已通过。
Password 的**新建、编辑和删除**路径现在会在本地 Vault 被显式启用时调用同步事务：同一
SQLite 事务写入或更新 `t_password`、`t_sync_entity` 和只含 AEAD 密文的 change log；
创建或编辑事务失败会删除刚写入的加密文件，删除则会先提交受保护 tombstone，再清理本地
密文文件。对端 Password 的新建、编辑和删除也已有内层 AEAD 验证、业务表应用、同步映射
更新、版本向量比较、并发冲突记录与 replay 幂等的专用适配器；密码编辑成功后会回收旧的
加密文件。Apple 平台的 Password 持久化入口会在本地新建、编辑或删除前，通过原生提供的
专用 Exchange 根目录扫描 Ready inbox；它先按已配对设备的公钥选择可信生产者，再由
importer 验签、解密、应用业务事务并写回执。入站会持久化每个远端设备的 sequence cursor：
首批不得带前序，后续批必须精确引用已提交的 `previousSequence/previousBatchId`，缺批则等待、
分叉则拒绝。未启用 Vault 时不会访问 Exchange。Android 桥保留为未来兼容代码，
当前 V1 不宣称存在 Android Velock 主 App，也不把该桥作为首发运行路径。
出站端也会在同一 SQLite 事务中保留待发布批次及其 sequence/前序引用；Exchange 写入成功
后才标记 Ready，重启会复用已保留 batch 而不会跳号或改写已存在密文包。
Password、Card 与 Note 的本地新建、编辑和删除现在都能在启用 Vault 的宿主中生成受保护
Outbox 变更；对端入站也会进行内层 AEAD 验证、版本向量比较、冲突记录、回放幂等和业务表
应用。Card/Note 的加密内容文件在成功替换后会回收旧文件。文件及目录层级已有独立的受保护
元数据 + opaque blob 协议、入站 upsert/tombstone 适配器和 Exchange 导出/导入分派；原生导入
现先写 staging，再由同一 SQLite 事务提交业务行、版本和 change log，之后原子发布密文。替换、
重命名/移动、删除、递归目录导入和启动恢复均已接入该事务节点；大文件 Exchange blob 也使用
可重放流，不再整体载入内存。Document 现已具备受保护 Delta payload、入站
upsert/tombstone、回放与冲突保护；本地新建会把空业务行、版本向量和首个加密 change log
一起提交，编辑在原生加密回调成功后提交新版本，删除先提交 tombstone 再清理本机密文文件。
Document 控制器默认装配真实 Exchange runtime；本地提交成功后的发布失败只保留 pending 并
在下次启动重试，不会删除刚写成的密文或把已提交操作误报为业务失败。Document、标签和标签
关系均作为独立数据集导入/导出 Exchange；release sandbox 配置和完整双设备互操作仍未接入。

Password 已把业务事务、受保护 payload、设备密钥、`SyncStateRepository` 与
exporter/importer 生命周期接通；Card、Note、File/Media、Document 及其标签关系也已有本地
生产路径和跨仓 Exchange 契约证据。剩余缺口是发布签名条件下的发现/配对 UI 实机闭环、
真实平台授权撤销/恢复、各业务类型的 Velock 冲突选择页面和双设备互操作，因此 FR-001 和首版验收项
4、6、7、8、9 仍不具备完整端到端完成证据。这些条件不能用本地 fixture 或模拟器替代。

`test_vectors/protocol_v1/` 现由 Dart、iOS XCTest 与 Android JVM 测试共同执行，覆盖
规范协议文档、非法版本、路径穿越、重复 operation ID、RFC 8032 Ed25519 正向验证与
篡改签名拒绝，以及 VLSB1 的 HKDF/AES-GCM 伪造/截断拒绝。真实双设备格间互操作测试仍未交付，
不能以这些向量覆盖替代端到端验收。

## 需要外部交付才能启用的范围

| 范围 | 还需交付的外部条件 | 本仓库当前行为 |
| --- | --- | --- |
| Android Velock Dataset（未来范围） | Velock Android 主 App、正式 package/authority/证书摘要、两 APK 的同签名发布构建及设备级互操作测试 | 当前不作为 V1 首发或完成阻塞项；无完整配置时拒绝所有 Exchange IPC |
| iOS Velock Dataset 发布启用 | 正式签名的共享 Exchange App Group entitlement、发布构建与设备级互操作测试 | V1 主链路；仅访问专用 App Group，不可访问格间旧容器、数据库或密钥 |
| 百度网盘、阿里云盘 | 独立、最小权限的官方 Token Broker 及 Provider 契约测试 | 连接 UI 保持暂缓，不编译 client secret |
| GitHub 高风险代码审查 | 组织提供有写权限的真实 GitHub 用户/团队，以配置 `CODEOWNERS`（Provider、密码学、App Group、OAuth 和导入路径） | 不猜测或提交无效 owner 占位符 |
| 正式商店签名 | Android/iOS 发布 CI 使用受保护的官方签名资产；iOS 还需正式 provisioning profile | Android Release 已拒绝未配置 keystore；实际签名资产不保存在仓库 |

## 已自主确定的产品决策

1. 普通文件夹同步默认使用 Generic Vault 端到端加密。
2. 普通可读镜像模式不进入首个可发布版本。
3. WebDAV 默认 HTTPS；HTTP 必须由用户在风险提示中明确确认。

## V1 completion execution tracking

### Phase 1 — Common Profile / Dispatcher (verified locally on July 17, 2026)

Completed requirements: `V1C-ARCH-001`, `V1C-ARCH-003`, `V1C-ARCH-005`,
`V1C-PROFILE-001`, `V1C-PROFILE-002`, `V1C-PROFILE-003`, and
`V1C-PROFILE-004`.

- A typed common profile envelope, privacy-safe summaries, and a repository now
  use the existing `sync_profiles` state table while isolating malformed or
  unsupported payloads rather than deleting them.
- Selected Folder reads its legacy payload shape and writes the V1 typed nested
  `dataset` payload, preserving existing profiles.
- The common executor registry/dispatcher is used for foreground Selected Folder
  runs and eligible background profile runs. It deduplicates concurrent runs,
  rejects profile removal while an active run holds the lock, and continues a
  batch dispatch after an individual failure.
- The dispatcher cleanup was verified not to self-await an in-flight Future;
  sequential redispatch completes after a prior run finishes.
- Profile JSON is guarded to retain only opaque secure-storage references for
  sensitive material; activity summaries do not expose the raw payload.

Local evidence:

```text
flutter analyze     => PASS (July 17, 2026)
flutter test        => PASS, 214 tests (July 17, 2026)
dart run custom_lint => PASS (July 17, 2026)
```

Focused Phase 1 coverage is in `test/sync_profiles/`,
`test/dataset_adapters/selected_folder/selected_folder_sync_profile_test.dart`,
and `test/background/background_sync_test.dart`. The subsequent Velock
Profile/Discovery/Pairing service and adapter-factory work is now locally
implemented and tested; production Apple entitlement/signing and the physical
iOS-device pairing loop remain external release evidence blockers. Android
Velock trust values belong to a future compatibility release.

### Phase 4 — Conflict resolution integration (verified locally on July 17, 2026)

Substantially addressed requirements: `V1C-CONFLICT-001`,
`V1C-CONFLICT-002`, `V1C-CONFLICT-003`, and `V1C-CONFLICT-004`.

- Activity no longer calls `SyncStateDatabase.markConflictResolved` directly.
  It delegates resolution only through `ConflictResolutionService` and refreshes
  after a completed durable result.
- Conflict actions are profile-specific: Selected Folder exposes keep-local,
  keep-remote, and keep-both; Velock exposes only "open in Velock". Unknown,
  missing, or malformed profiles expose no resolution action.
- `DurableConflictResolutionService` persists a leased resolution intent and
  completes the durable conflict record only after a dataset-specific durable
  artifact or a trusted opaque Velock receipt is verified. Malformed metadata,
  retries, and incomplete operations fail closed and leave the conflict
  unresolved.
- Incoming Selected Folder conflict metadata is persisted only after the
  conflict copy succeeds. It contains local-only safe relative paths,
  revisions, vectors, and type flags; it never stores content bytes.
- Activity summaries and conflict actions intentionally never render
  `protectedDetails`, including Velock plaintext paths, names, or field data.

Local evidence:

```text
flutter test test/features/activity/ui/sync_activity_test.dart => PASS, 2 tests
flutter test test/infrastructure/database/sync_state_database_test.dart \
  test/dataset_adapters/selected_folder/selected_folder_incoming_applier_test.dart \
  test/sync_core/conflicts test/features/activity => PASS, 31 tests
flutter analyze lib/core/state/common.dart lib/features/activity/ui/sync_activity.dart \
  test/features/activity/ui/sync_activity_test.dart => PASS
```

July 18 continuation:

- Selected Folder now has a production `DurableSelectedFolderConflictResolver`
  for keep-local, keep-remote, and keep-both across concurrent file edits and
  incoming-delete/local-edit conflicts. It applies the storage action through
  the authorized `SelectedFolderStorage`, merges both conflict vectors, durably
  queues the affected entity in the existing scanner/batch pipeline, invokes
  the normal `SelectedFolderSyncService`/Sync Core path, and returns a
  completion artifact only after the published entity vector dominates both
  conflicting versions.
- Concurrent incoming deletes now persist protected, content-free resolution
  metadata without inventing an incoming file copy. Keep-local publishes the
  retained file, keep-remote publishes an explicit tombstone, and keep-both
  publishes that tombstone plus one stable conflict-copy identity containing
  the preserved local bytes. The explicit per-entity tombstone bypasses the
  scanner's mass-deletion guard only after the user selects a resolution.
- A failed publication leaves the conflict unresolved and the merged outgoing
  state recoverably queued. Retrying does not require the temporary incoming
  conflict copy and does not duplicate the resolution operation. Local-only
  conflict-copy scanner rows are removed before publication for keep-local and
  keep-remote; keep-both preserves and publishes both identities. A retry after
  the resolution tombstone was published but before `resolved_at` was committed
  accepts the already-dominating published state without replaying file actions.
- Focused coverage in
  `test/dataset_adapters/selected_folder/selected_folder_conflict_resolver_test.dart`
  exercises all three strategies for both conflict shapes, failed publication
  recovery, durable intent retry, stable keep-both preservation, and the rule
  that `resolved_at` advances only after publication.

Velock conflict control is now locally implemented as an iOS-first fail-closed
flow. Sync writes a content-free, 24-hour request into the dedicated App Group
and opens `velock://sync-conflict`; opening the app returns a pending result and
does not complete the conflict. Velock can sign a receipt only after its local
business resolution, a `resolve-conflict` outgoing operation and
`t_sync_conflict.resolved_at` commit together. The resolved row retains that
operation in `resolution_operation_id`, and receipt issuance independently
checks the referenced change-log row's entity and operation type. Sync verifies the exact request,
challenge, vault, producer, producer key ID, Exchange binding, Sync app
instance, expiry and signature under the public key retained at pairing before
committing `resolved_at`, then writes a consumed marker. Missing, expired,
replayed, mismatched or tampered artifacts leave the conflict retryable.

Velock now also retains each incoming conflict version vector (database v18)
for Password/Card/Note/File/Document and tag records. When a current,
non-deleted local revision is still available, the settings surface offers an
entity-labelled “keep local” choice. Velock authenticates and opens that local
protected payload under its old revision, joins both vectors, advances the
local device counter, and seals the same business state under a new
`resolve-conflict` revision. Receivers route this dominating resolution through
the corresponding authenticated upsert applicator. Old ciphertext is never
copied into a new AEAD context.

The remaining product integration is the entity-specific Velock conflict UI
that can inspect and accept the incoming version, merge fields, or preserve a
deleted winner for Password/Card/Note/File/Document. Sync cannot implement
those business choices. Until each entity surface calls the repository, those
choices remain unavailable and the companion refuses to issue a receipt.

July 18 UI/settings continuation:

- `V1C-UI-005` is now substantially complete locally. Settings persists a
  global background gate and default cellular/charging/transfer-limit policy.
  The background entry point reads the same gate before constructing a
  dispatcher, so disabling it is operational rather than decorative. New
  Selected Folder profiles inherit the saved default policy.
- Settings reports platform background capability and aggregate staging usage.
  Safe cleanup acquires each profile lock, removes only abandoned batches and
  temporary files, preserves recoverable manifests, and skips a live sync.
- Diagnostics export contains only version/platform data, aggregate profile,
  run, transfer and conflict counts, allowlisted stable error codes and staging
  usage. Tests inject secret-shaped profile IDs, paths, key references, run IDs
  and error strings and verify that none are exported.
- The iOS-first Velock branch of `V1C-UI-003` now probes the independently
  installed application's App-Group-protected data plane and Pairing Control Plane V1.
  It discovers the Velock-owned producer identity and Ed25519 public key,
  creates a five-minute one-time challenge, asks the protected provider to
  launch Velock, and can resume a pending request after the user returns.
- Sync accepts an approval only when request ID, challenge, producer ID, public
  key ID, public key, exchange binding and expiry all match and the response
  verifies under Velock's existing device key. Rejection, expiry, revocation,
  replay and malformed/tampered responses fail closed. No guessed identity,
  Sync-created producer key or partial profile is saved.
- The companion now has an iOS filesystem-backed control-plane service that
  publishes only public opaque identity, lists pending requests and writes a
  signed approval only after an explicit `userConfirmed` call. The retained
  Android provider exposes the same frozen contract only for future compatibility.
- Velock's authenticated iOS settings now includes a dedicated Velock Sync
  page. The user must explicitly activate the Velock-owned vault before its
  public descriptor is published, can inspect five-minute requests by Sync app
  instance ID, and must separately confirm approval or denial. Approval reuses
  the existing secure signing key; deactivation withdraws the descriptor
  without deleting the identity, keys, data or decision audit trail.
- Sync's steps 4–7 now select an active connection, confirm the exact remote
  target, choose background policy, render a final review, re-verify the signed
  approval, atomically save the Profile and only then ACK the one-time response.
  ACK failure preserves the saved Profile and exposes an explicit retry.
- `velock://sync-pairing` now has cold/warm-start retention on iOS and opens the
  authenticated Velock Sync approval page after the user unlocks Velock.

`V1C-UI-003` is locally implemented; its remaining evidence is a formally
signed two-app physical-iOS-device run, not Android Velock implementation.
`V1C-UI-005` no longer shares that blocker. The Velock conflict deep-link and
trusted receipt contract are locally complete; full product completion still
requires entity-specific Velock resolution screens plus a formally signed
two-app physical-iOS-device run.

Current local evidence:

```text
flutter test => PASS, 405 tests (July 18, 2026)
flutter analyze => PASS (July 18, 2026)
dart run custom_lint => PASS (July 18, 2026)
cd ../velock_codex && flutter test => PASS, 527 tests (July 18, 2026)
cd ../velock_codex && flutter analyze => PASS (July 18, 2026)
xcodebuildmcp simulator build (both Runner schemes) => PASS
dart run tool/verify_cross_repo_exchange_contract.dart ../velock_codex => PASS
```

### Phase 5 — Provider Contracts (verified locally on July 17, 2026)

Completed requirements: `V1C-PROVIDER-001`, `V1C-PROVIDER-002`,
`V1C-PROVIDER-003`, and `V1C-PROVIDER-004`.

- `RemoteObjectStore` now has one reusable V1 contract harness. It is exercised
  through the real WebDAV, Google Drive, and OneDrive adapters using scripted
  HTTP transports, not a mocked `RemoteObjectStore`.
- The machine-readable matrix at
  `test/providers/contracts/provider_contract_matrix.json` records verified
  evidence for every enabled provider and all 16 required contracts: zero-byte
  and small-object round trips, 10 MiB-plus streaming upload, immutable retry
  and collision, deterministic listing/cursors, missing reads, one-refresh OAuth
  recovery, rate-limit cancellation, transfer integrity, Unicode keys,
  idempotent delete, in-flight cancellation, quota mapping, traversal rejection,
  and error redaction.
- Provider behavior is normalized where the cloud APIs differ: missing OneDrive
  lookup results raise `RemoteObjectNotFoundException`, and all three adapters
  retain deterministic listing, cancellation, idempotent deletion, sanitized
  errors, and HTTP 507 quota classification.

Local evidence:

```text
dart format --output=none --set-exit-if-changed lib/providers test/providers tool => PASS
flutter analyze lib/providers test/providers => PASS
flutter test test/providers => PASS, 111 tests
flutter test test/providers/contracts/provider_contract_matrix_test.dart => PASS
```

This evidence is a local, scripted real-adapter contract suite. It does **not**
claim live cloud-account interoperability, actual credentials, or dual-device
E2E verification; those remain Phase 7/8 evidence requirements.

### Phase 5 — Dataset Adapter Contract Suite (locally verified on July 18, 2026)

Partially addressed requirement: `V1C-DATASET-001`. The shared Exchange V1
interface is now frozen and locally compatible across `velock_sync` and
`velock_codex`; trusted external receipts, release platform authorization and
physical-device interoperability remain outside the local evidence. This does
**not** mark Phase 5 or V1 complete.

- `test/dataset_adapters/contracts/dataset_adapter_contract.dart` defines the
  required `DCA-001` through `DCA-016` suite and fails when either adapter
  omits a contract.
- `dataset_adapter_contract_test.dart` runs the same suite for a real temporary
  filesystem Selected Folder fixture and a filesystem-backed Velock Exchange
  fixture. Velock operations remain arbitrary opaque bytes: the test never
  decrypts or parses `operations.enc`, imports only outer artifact metadata,
  and does not fabricate a trusted companion ACK.
- `dataset_contract_evidence.json` is a machine-readable ledger per adapter and
  contract. `dataset_contract_evidence_test.dart` requires all 16 contract IDs,
  rejects unsupported evidence scopes and duplicate entries, requires explicit
  limitations for indirect evidence, and preserves the remaining platform and
  physical dual-device blockers.
- `test_vectors/velock_exchange_v1/interface_contract.json` freezes the shared
  version marker, exact outer schemas, producer identity references, state
  machine, receipt vocabulary, stable error names, sequence linkage, artifact
  limits, Android trust constants, Pairing Control Plane V1 descriptor/request/
  response schemas, canonical Ed25519 signature payload, expiry/replay rules,
  Apple App Group constants and Conflict Control Plane V1 request/receipt/
  consumed schemas. The
  companion repository contains an equivalent contract file, and
  `tool/verify_cross_repo_exchange_contract.dart` rejects semantic drift.
- Both repositories now emit `exchangeVersion: 1` in READY markers. Sync's
  Apple and Android adapters validate the full companion envelope instead of a
  permissive subset; the companion codec enforces the same envelope,
  operations, blob-count and size limits before publication and during parse.
  Zero-sized blob chunks remain valid for replayable large-file artifacts.
- Cross-repository executable evidence compiles a real companion package and
  compares its envelope and READY schemas to the frozen contract, then validates
  both repositories' native authority, package, permission, App Group and
  app-local channel constants.
- Incoming Velock blobs now use an optional streaming Dataset capability.
  `SyncDownloadEngine` reopens the remote object on demand and verifies declared
  length and SHA-256 incrementally while the adapter consumes it. Streaming
  adapters have no protocol blob-size ceiling by default; non-streaming
  adapters retain the 512 MiB memory-safety cap.
- Apple writes each replayable artifact directly into Exchange staging.
  Android writes the Dart stream to app-private staging, passes only metadata
  and that private path over MethodChannel, then copies it through a writable
  signature-protected ContentProvider staging file descriptor. Blob bytes no
  longer enter Binder arguments; partial staging is reset safely on retry.
- The Android Exchange executor maps every native exception into the frozen
  uppercase error vocabulary and returns a privacy-safe generic message.
  Discovery understands the stable `NOT_FOUND`, `UNSUPPORTED_VERSION`,
  `ACCESS_DENIED` and `TEMPORARY_UNAVAILABLE` codes while retaining legacy-code
  compatibility.
- Evidence boundaries are explicit: Selected Folder's vector-conflict and
  durable-cursor assertions rely on focused real-adapter integration tests;
  Velock's access-loss/regrant proof is local pairing/discovery preflight only;
  its deferred receipt path writes a local fixture receipt and is not external
  companion evidence. The selected-folder malformed/unsupported coverage is
  outgoing staged-artifact recovery, not a claim of incoming protocol
  negotiation.

Local evidence:

```text
dart format --output=none --set-exit-if-changed test/dataset_adapters/contracts => PASS (3 files, 0 changed)
dart run tool/verify_cross_repo_exchange_contract.dart ../velock_codex => PASS
flutter test test/dataset_adapters/contracts \
  test/dataset_adapters/velock_exchange/velock_exchange_dataset_adapter_test.dart => PASS, 42 tests
flutter test test/dataset_adapters/contracts/dataset_contract_evidence_test.dart => PASS, 1 test
flutter test test/dataset_adapters/selected_folder/selected_folder_incoming_applier_test.dart \
  test/dataset_adapters/selected_folder/selected_folder_download_integration_test.dart \
  test/dataset_adapters/velock_exchange/velock_dataset_adapter_factory_test.dart => PASS, 9 tests
flutter test test/dataset_adapters/velock_exchange => PASS, 42 tests
flutter analyze test/dataset_adapters/contracts => PASS (No issues found)
flutter analyze => PASS (No issues found)
flutter test => PASS, 402 tests
cd ../velock_codex && flutter analyze => PASS (No issues found)
cd ../velock_codex && flutter test => PASS, 495 tests
```

Remaining `V1C-DATASET-001` blockers for Velock V1: real iOS authorization
revoke/regrant, trusted external companion receipt reconciliation, Apple release
trust/entitlement values and physical iOS dual-device
interoperability/fault-injection evidence remain unverified.

### Phase 6 — Companion Document tag / sandbox synchronization (locally verified on July 17, 2026)

Partially addressed requirement: `V1C-DATASET-003`. This entry is limited to
what is implemented and tested in `/Users/parcool/AndroidStudioProjects/velock_codex`;
it does not mark Phase 6, the unified Dataset contract, or V1 complete.

- The companion SQLite migration from v15 to v16 adds document-tag and
  document-tag-link business tables together with their Sync mappings. Local
  tag and tag-link mutations atomically update the business rows and append the
  protected pending Sync change.
- Tag records use a protected, schema-versioned `document-tag` payload. A
  `document-tag-association` payload contains only the stable document and tag
  entity UUIDs; it contains no document name, path, encrypted filename,
  preview, summary, or content metadata.
- Inbound tag and association upsert/tombstone applicators decrypt and validate
  their protected payload before business apply, use the existing version-vector
  state transition, preserve replay idempotence and causal domination, record
  concurrent conflicts, and fail closed when an association endpoint is absent.
- The Exchange importer dispatcher routes both entity kinds for upsert/delete;
  configuration omissions are covered by exact fail-closed error assertions.
- Real local runtime routing now covers both directions when document callbacks
  are configured: export emits `document`, `document-tag`, and
  `document-tag-association` operations; a trusted local inbound batch applies
  those same ordered operations. The inbound test observes the business rows,
  local applied-operation markers, a local inbox receipt artifact, and a local
  inbound-cursor commit only after the import succeeds.
- The production Document controller now wires that runtime by default.
  Creating an empty document inserts its business row and first protected
  revision in one SQLite transaction; edit publication starts only after the
  native encrypted-file callback; delete commits its tombstone before local
  ciphertext cleanup. Exchange publication is a retryable post-commit step:
  an injected outage preserves the new ciphertext and pending change, does not
  turn the successful local mutation into a false failure, and is retried by
  the next Document bootstrap.

Local evidence from the companion repository:

```text
dart format --output=none --set-exit-if-changed \
  lib/sync/bridge/sync_password_exchange_runtime.dart \
  test/sync/sync_document_exchange_runtime_test.dart => PASS (0 changed)
flutter test test/sync/sync_document_exchange_runtime_test.dart \
  test/sync/sync_password_importer_integration_test.dart \
  test/sync/sync_password_exchange_import_binding_test.dart \
  test/sync/sync_document_tag_record_test.dart \
  test/sync/sync_document_tag_local_mutation_test.dart \
  test/sync/sync_document_tag_upsert_applier_test.dart \
  test/sync/sync_document_tag_association_applier_test.dart => PASS, 25 tests
flutter analyze lib test => PASS (No issues found)
flutter test test/sync => PASS, 96 tests
git diff --check => PASS
```

The repository-wide companion format check remains blocked by unrelated,
pre-existing formatting drift (43 files reported by
`dart format --output=none --set-exit-if-changed lib test`); the check was
non-mutating and those unrelated files were not reformatted.

### Phase 6 — Companion File / Media transaction publication (locally verified on July 18, 2026)

Partially addressed requirement: `V1C-DATASET-002`. This continuation covers
the existing native File/Media import publication path in
`/Users/parcool/AndroidStudioProjects/velock_codex`; it does not claim complete
content-edit, recursive-import, delete-recovery, or external interoperability
coverage.

- Sync-enabled native imports continue to publish through the private
  `.sync-native-stage` area and defer the visible `t_file` business row until
  the native artifact callback can commit the staged artifact, Sync mapping,
  and protected pending change through the existing transaction coordinator.
- Native completion now tracks which source wrappers actually acquired a
  durable staged commit. A successfully committed File/Media import is no
  longer misclassified as failed merely because its pre-commit wrapper has no
  legacy `dbRowId` or because a Media flow removed the original source.
- Partial failures remove only uncommitted wrappers. Legacy cleanup filters
  nullable row IDs safely and mutates the real pending list, preventing the
  former invalid cast and temporary-set cleanup bugs.
- Apple copy callbacks now return an explicit source/output mapping, matching
  encryption callbacks. A failure earlier in the batch can therefore no longer
  shift the progress index and attach a later artifact to the wrong source
  identity. Staged commit exceptions fail closed with a fixed non-sensitive
  error code.
- File and directory rename/move operations now route their `t_file` update,
  parent stable entity UUID, version-vector revision, and protected pending
  change through `SyncFileMutationService` in one SQLite transaction when Sync
  is enabled. File metadata revisions use a new opaque blob ID for the current
  encrypted artifact; directory hierarchy revisions remain metadata-only.
  Sync-disabled sandboxes retain the existing legacy database path.
- New directories now use the same transaction service for the business row,
  stable mapping, parent entity UUID, and protected metadata-only revision.
  Missing or unsynchronized parents fail before any row/change is committed;
  the File UI removes the newly created empty filesystem directory if the
  database/Sync transaction fails. Pre-existing physical directories are not
  reused or removed by this rollback path.
- Rename/move now flush a device-local atomic intent before touching the
  filesystem and remove it only after the SQLite + Sync transaction succeeds.
  The intent contains local IDs and validated relative components, never
  absolute paths, provider locations, or content bytes. Interrupted temporary
  writes are discarded safely, and complete intents survive a new journal
  instance.
- The File/Media runtime now replays pending rename/move intents before its
  first directory load. The current `t_file` row is the commit authority:
  source metadata rolls a physical move/rename or encrypted file-header rename
  back, while target metadata completes it forward. Already-reconciled state is
  accepted idempotently. Both paths existing, neither path existing, a missing
  row, a type mismatch, or any other ambiguous state fails closed and preserves
  the durable intent. The recovery also runs for an old intent if Sync has
  since been disabled.
- Native callbacks carrying both a private stage token and an existing
  `localId` now take an explicit content-replacement path instead of being
  misrouted as a second create. The replacement preserves the local identity,
  display name and hierarchy; derives the new size and Media metadata from the
  edited source; and commits the new opaque stored name, blob revision,
  business row, mapping and protected change together before publishing the
  ciphertext and deleting the replaced artifact.
- File and Media refresh now replay committed artifact publish/delete journals
  before metadata-intent recovery. Fault injection covers process death after
  the SQLite replacement transaction but before ciphertext publication:
  restart publishes the staged replacement, then deletes the old ciphertext.
  A failed replay remains pending, and a second successful replay is
  idempotent.
- Desktop image rotation no longer decodes or overwrites the protected
  ciphertext path. It rotates the current page's decrypted temporary copy in
  an isolate, waits for an in-flight rotation before closing, returns a typed
  `localId`/temporary-path edit result, and re-enters the existing native
  staging replacement path. The callback therefore preserves the file
  identity while publishing a new encrypted blob and protected Sync revision.
  This also corrects the legacy page-selection bug that could rotate the
  initially opened image after the user paged elsewhere.
- Failed staged replacements now preserve the pre-existing `t_file` row.
  Staged imports have no row before commit, and staged replacements reference
  an authoritative existing row, so failure cleanup never treats either as a
  legacy partially inserted row. Tests verify that the protected artifact is
  untouched while its decrypted edit copy rotates and that an uncommitted
  replacement cannot schedule its existing row for deletion.
- Directory picker and desktop drop imports no longer pass an opaque external
  directory to native code as one pseudo-file. A deterministic planner expands
  regular files, nested directories and empty directories without following
  symbolic links. The importer commits every directory parent before its
  children and sends each direct file group through the existing staged native
  import under the committed parent ID. An interrupted batch therefore leaves
  only individually valid committed nodes, rather than encrypted descendants
  with no `t_file`, entity UUID or protected change.
- Sync-enabled recursive-import directories are themselves created as durable
  prepared artifacts: an empty directory stays in `.sync-stage` until its
  business row, hierarchy UUID and protected revision commit, then the artifact
  journal publishes it. Tests cover hierarchy preservation, empty directories,
  deterministic parent-first ordering, first-failure stop behavior and staged
  directory publication.
- The remaining current File/Media UI content-mutator audit found one real
  bypass: full-screen viewer deletion owned its own legacy DB/filesystem
  deletion mixins. The viewer is now mutation-free and requires a delete action
  from the owning Image/File runtime, so the operation uses the Sync tombstone
  and artifact journal. A failed transaction no longer animates away, removes
  the item, reports success, closes the viewer or asks the outer list to
  refresh. Crop/compress outputs and rotation inputs were also verified to be
  pre-import or decrypted temporary files, not writes to protected artifact
  paths.
- Native File/Media staging now calculates SHA-256 incrementally from the file
  stream instead of materializing the ciphertext with `readAsBytes`. A
  10 MiB-plus fixture proves staged adoption, bounded-memory hashing, atomic
  publication and idempotent recovery against the published hash.
- File/Media Exchange blobs now use one length-delimited, replayable
  `openRead` artifact from the local encrypted file through protocol hashing,
  Outbox atomic publication and retry comparison, Inbox signed-hash
  verification, decoded-batch dispatch and inbound staging. No production
  File/Media blob step converts the artifact back to a whole `Uint8List`.
  A 10 MiB-plus round trip verifies identical source/inbound hashes, while
  injected stream interruption removes the partial Outbox directory and
  succeeds from a fresh stream on retry. Short or oversized streams fail
  before publication/application.
- Delete recovery now has the complementary crash-window evidence to
  replacement publication: when the SQLite tombstone and delete journal commit
  but physical deletion is interrupted, startup recovery deletes the artifact,
  completes the journal and remains idempotent. Publication failure,
  replacement recovery, metadata-intent recovery and recursive first-failure
  stop remain covered separately.

Local evidence from the companion repository:

```text
flutter test => PASS, 488 tests
flutter test test/document test/sync \
  test/file/native_storage_commit_ledger_test.dart => PASS, 186 tests
flutter analyze lib/sync/bridge/sync_file_native_artifact_coordinator.dart \
  lib/sync/bridge/sync_exchange_store.dart \
  lib/sync/bridge/sync_file_artifact_gateway.dart \
  lib/sync/bridge/sync_password_exchange_import_binding.dart \
  lib/sync/bridge/sync_password_exchange_runtime.dart \
  lib/sync/protocol/sync_stream_artifact.dart \
  lib/sync/protocol/velock_sync_v1.dart \
  lib/sync/repository/sync_file_upsert_applier.dart \
  lib/sync/repository/sync_file_metadata_intent_journal.dart \
  lib/mixins/file/mixin_file_op.dart \
  lib/mixins/file/mixin_base_storage_handler.dart \
  lib/features/files/presentation/file/file_controller.dart \
  lib/features/files/presentation/file/file_runtime_collaborators.dart \
  lib/features/files/presentation/file/mixins/mixin_catalogue_operation.dart \
  lib/features/images/presentation/image/detail/image_detail_controller.dart \
  lib/features/images/presentation/image/detail/temporary_image_rotation.dart \
  lib/features/images/presentation/image/image_controller.dart \
  lib/features/images/presentation/image/image_viewer_actions.dart \
  lib/features/images/presentation/image/platformed/image_page_mobile_body.dart \
  lib/features/images/presentation/image/platformed/image_page_desktop_body.dart \
  lib/features/documents/presentation/document/document_controller.dart \
  lib/features/documents/presentation/document/document_feature_dependencies.dart \
  lib/features/documents/presentation/document/document_sync_exchange_runtime.dart \
  lib/sync/repository/sync_document_mutation_service.dart \
  lib/mixins/media/mixin_image_view.dart \
  lib/widgets/venyore_viewer/venyore_viewer.dart \
  lib/widgets/venyore_viewer/provider/venyore_viewer_model.dart \
  test/sync/sync_file_artifact_gateway_test.dart \
  test/sync/sync_file_artifact_startup_recovery_test.dart \
  test/sync/sync_file_exchange_streaming_test.dart \
  test/sync/sync_file_native_artifact_coordinator_test.dart \
  test/sync/sync_file_metadata_intent_journal_test.dart \
  test/sync/sync_exchange_store_test.dart \
  test/sync/sync_document_mutation_service_test.dart \
  test/sync/velock_sync_v1_test.dart \
  test/document/document_feature_dependencies_test.dart \
  test/file/file_runtime_collaborators_test.dart \
  test/file/native_storage_commit_ledger_test.dart \
  test/image/image_detail_page_result_test.dart \
  test/image/image_view_mixin_test.dart \
  test/image/temporary_image_rotation_test.dart \
  test/widgets/venyore_viewer/venyore_viewer_data_source_controller_test.dart \
  => PASS (No issues found)
xcodebuildmcp simulator build --workspace-path ios/Runner.xcworkspace \
  --scheme Runner --simulator-id 26CC5821-DEF4-47D3-978D-A11D7293AD61 \
  --configuration Debug => PASS
git diff --check => PASS
```

The companion repository-wide `flutter analyze lib test` now passes with no
issues.

Remaining Phase 6 and release blockers are explicit: the local receipt/cursor
mechanics above do not prove trusted external-app receipt/cursor semantics; no
paired physical-device or device-to-device interoperability evidence exists;
release sandbox/Exchange-entitlement configuration is unavailable; and
`V1C-DATASET-001` remains incomplete at the platform/release evidence boundary.
The unified cross-repository Exchange V1 interface itself is now frozen and
locally compatibility-tested. Production Document create/edit/delete
Exchange export and its deferred-publication retry path are now locally
connected and tested.
File/Media transaction publication (`V1C-DATASET-002`) still needs an audit of
future end-user content-edit producers as they are added,
recovery/fault-injection coverage across every multi-operation ordering, and
physical dual-device verification. The current viewer deletion bypass is
closed; large-media Exchange is replayably streamed; and rename/move, image
rotation, recursive directory import, deletion, and the shared native
replacement callback publish through individually durable nodes with
startup-wired local recovery. Full File/Media crash consistency still requires
broader multi-operation interruption coverage.

### Phase 7 — Deterministic fault injection (partially verified locally on July 18, 2026)

Partially addressed requirement: `V1C-E2E-002`. This is deterministic local
state-machine evidence, not physical-device, process-kill, live-provider or
cross-platform E2E evidence.

- Upload now has explicit tests for a network failure after 30% of a replayable
  blob stream, blob-success/body-failure, body-success/commit-failure, and
  remote-commit-success/local-dataset-cursor-failure. Retries reopen the
  immutable source, reuse already-created immutable objects, publish visibility
  only through the final commit, and acknowledge the dataset exactly once.
- Download verifies that duplicated Provider list entries collapse to one
  sequence import and that out-of-order commits wait at the first gap.
- Existing deferred Velock tests prove that delivery without a trusted receipt
  neither advances the incoming cursor nor redelivers the package; receipt
  reconciliation later advances it once.
- Existing coverage also includes staged disk exhaustion before remote work,
  429 cancellation during backoff, OAuth refresh replacement, safe staging
  cleanup under profile locks, stale conflict-resolution lease recovery,
  pairing challenge replay rejection, malformed artifacts, and transfer-job
  failed/completed transitions.

Local evidence:

```text
flutter test test/sync_core/sync_upload_engine_test.dart \
  test/sync_core/sync_download_engine_test.dart => PASS, 13 tests
flutter test => PASS, 387 tests
flutter analyze => PASS
dart run custom_lint => PASS
git diff --check => PASS
```

Remaining `V1C-E2E-002` evidence includes real process kills at every
transfer/job/pairing transition, a live 401 refresh interruption, physical
storage exhaustion while an OS/provider stream is writing, companion receipt
loss under a separately signed process, and the complete physical-device
Provider × Dataset matrix. `V1C-E2E-001` and `V1C-E2E-003` remain external and
unverified.

### 本轮本地验证汇总（July 17, 2026）

本轮只补齐可在当前工作站复现的 V1 验证证据；不改变前述 Phase 5/6 的范围结论，也**不**把本地 fixture、模拟器或构建成功表述为外部授权、发布信任、物理双设备互操作或 V1 整体完成。

```text
flutter pub get => PASS
flutter analyze => PASS (No issues found)
dart format --output=none --set-exit-if-changed lib test tool => PASS (224 files, 0 changed)
flutter test => PASS (357 tests)
dart run custom_lint => PASS (No issues found)
dart run tool/check_dependency_licenses.dart => PASS
dart run tool/verify_no_secrets.dart => PASS
cd android && ./gradlew test :app:assembleDebug --console=plain => PASS
flutter build ios --simulator => PASS
xcodebuildmcp simulator test --workspace-path ios/Runner.xcworkspace \
  --scheme Runner --simulator-id 26CC5821-DEF4-47D3-978D-A11D7293AD61 \
  --configuration Debug => PASS (7 XCTest tests, iPhone 17 Pro Max iOS Simulator 26.5)
```

iOS validation is simulator-only. The build/test tooling emitted non-fatal
third-party and toolchain warnings (for example, `workmanager_apple`,
`open_filex`, and Swift debug-information environment keys); no unrelated
package, NDK, Xcode, or release-configuration change was made solely to silence
them.

The remaining blockers are: actual iOS Velock authorization and release
signing/entitlements, Android/iOS authorization for non-Velock data sources,
verified companion-origin trusted receipts,
fault-injection and physical dual-device E2E evidence, and the provider/release
decisions that require external credentials or organizational approval. The
cross-repository Exchange V1 contract freeze and local companion compatibility
evidence are complete.
