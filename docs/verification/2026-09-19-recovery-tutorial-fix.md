# 恢复教程配对故障排查

## 已确认的根因

干净设备使用当前源设备的换机恢复卡恢复后，身份检查确认原 vault 相同、device identity 不同。共享 Exchange 中公开 descriptor 已存在，但 Sync 的 `ApplePairingControlChannel.pairingDescriptor()` 抛出 `FormatException: Invalid Velock pairing exchangeBindingId`。

该 binding 是合法的 43 位无填充 SHA-256 base64url 摘要，首字符为 `-`。原解析器错误复用“首位必须为字母数字”的路径 ID 校验，因此被 readiness 的通用异常分支显示为“配对通道尚未配置”。不是缺失恢复卡，也不是 NAS 凭据问题。

## 修复

- Sync 与格间的配对/冲突控制面，对 `exchangeBindingId` 接受既有 opaque ID 或 43 位 base64url 摘要。
- 不改变 vault/device 身份生成，不放宽文件路径、request ID 等其他字段的校验。
- 保留签名、挑战、有效期、身份绑定验证。
- 格间设置页监听认证变化：锁定时清除旧快照；解锁后重新加载；拒绝跨锁定会话的旧确认和过期异步刷新结果。
- 教程恢复步骤等待真实下载结果，不把“已创建配置”作为下载完成。

## 已执行的回归

- 新增 `-` / `_` 前缀 descriptor、request、签名 response 回归，修复前失败、修复后通过。
- 实际失败设备的 descriptor 探针修复后通过。
- 冲突 request / receipt 往返及非法输入拒绝测试通过。
- Sync 相关控制面 / wizard 测试：132 项通过。
- Sync 全量 `flutter test --no-pub`：498 项通过。
- 格间 protocol 相关测试：24 项通过；设置生命周期与相关测试：15 项通过（含 7 个新增定点测试）。
- 两端 iOS 模拟器构建成功；公开演示 companion 构建不启用 E2E fixture 界面。

## 录像验收

第二段在独立的干净演示模拟器中连续录制成功：222.052 秒，1320×2868，原生 H.264，无剪辑/拼接/转码。

`cross-app-20260919T102801Z-15025`：XCTest 通过；恢复原 vault、生成不同 device identity；1 条密码的源版本一致；冷启动后打开详情并验证解密账号 `e2e-user`。抽帧视觉验收确认尾帧为该凭证详情，没有测试结束桌面。完整流水线 299 秒，UI 阶段 260 秒。文件摘要见教程目录 `delivery.json`；失败尝试不作为交付视频。

## 追加锁屏边界修复

只读排查还发现：恢复完成认证但首页尚未启用截屏保护时，`secured=false` 会导致后台锁住 session 却未锁 Flutter gate。已在 coordinator 中补齐：有会话时同步锁 gate；前台遇到 locked session 优先恢复 gate，文件交接标志不能打开它；撤掉 native overlay 前先锁 gate。未添加认证旁路或自动 session unlock。

新增测试先有 4 项失败，修复后 9/9 通过（含原有 4 项），静态分析通过。此追加补丁在录像完成后落盘；其证据是定点单测，不将之前的录像冒充该边界的 UI 验收。

追加补丁后的 companion iOS 模拟器构建成功。所有修改未提交。
