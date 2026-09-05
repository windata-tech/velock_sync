# 实现状态

当前项目已完成同步核心、Provider 契约、Profile Dispatcher，以及 Velock Exchange 的 opaque artifact 读写、完整性校验、游标和 receipt 基础流程。

Velock 数据的加密由 `/Users/parcool/AndroidStudioProjects/velock_codex` 负责；本项目不持有 Velock 密钥、不读取明文，也不进行二次加密。

## 当前剩余工作

- 正式 iOS App Group entitlement、签名构建和物理设备互操作；
- Velock 双设备授权撤销/恢复与真实 receipt 验证；
- Provider 真实账号端到端验证、故障注入和发布证据；
- 修复当前工作树中的编译/测试回归后再提交整合改动。

非 Velock 数据集已从本项目移除，不再作为产品能力或 V1 验收项。
