# velock_sync

[English] An open-source, cross-platform, incremental bidirectional sync engine for Velock and user-selected files. The project is designed to support WebDAV, Google Drive, OneDrive, Baidu Netdisk, Aliyun Drive, and additional providers through adapters. Mobile platforms are prioritized first, followed by desktop platforms.

---

[中文] 一个开源、跨平台的增量双向同步工具。格间是内置的深度集成数据源，同时也支持非格间用户同步其主动选择的文件夹。云端目标通过 Provider 适配器扩展，计划支持 WebDAV、Google Drive、OneDrive、百度网盘和阿里云盘。项目优先支持移动端，再逐步完善桌面端。

## 产品与技术文档

- [产品需求文档（PRD）](./docs/PRD.md)
- [技术规格（Technical Specification）](./docs/TECHNICAL_SPEC.md)
- [Velock Sync Protocol V1](./docs/SYNC_PROTOCOL_V1.md)
- [Generic Vault 恢复流程](./docs/GENERIC_VAULT_RECOVERY.md)
- [PRD / Technical Spec 实现与验收状态](./docs/IMPLEMENTATION_STATUS.md)

核心安全原则：Velock Sync 在格间模式下只搬运经过端到端加密和认证的增量包，不持有格间主密钥或同步密钥。

## 格间已在iOS Store上架：

<div style="text-align: left;">
  <a href="https://apps.apple.com/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">或</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>

## Getting Started

Keep going!

## 启动build_runner
```shell
dart run build_runner watch --delete-conflicting-outputs
```
