# Velock Sync

[English] Velock Sync is an open-source, cross-platform, incremental bidirectional sync tool. For Velock (格间) users, it is the standalone companion app that syncs encrypted vault data between your own devices. It also supports syncing user-selected folders with end-to-end encryption, without requiring a Velock account.

[中文] Velock Sync 是一款开源、跨平台的增量双向同步工具。对格间（Velock）用户而言，它是格间的独立同步伴侣 App，可以在你自己的设备之间同步经过端到端加密的格间数据；对普通用户而言，它也可以端到端加密地同步你主动授权的本地文件夹，无需注册 Velock 账号。

## 核心功能 / Key Features

- **增量双向同步**：只传输新增或变化的内容；支持 checkpoint 恢复、断点续传与垃圾回收，已存在的数据不重复上传。
- **端到端加密**：格间模式下只搬运格间生成的不透明加密增量包，Velock Sync 不持有格间主密钥或同步密钥，也不读取格间数据库。
- **通用文件夹同步**：非格间用户可选择本地文件夹，默认端到端加密，也支持普通镜像模式。
- **多云端目标**：已支持 WebDAV、Google Drive、OneDrive；百度网盘、阿里云盘等更多云端通过 Provider 适配器持续扩展。
- **多设备协同**：版本向量与 tombstone 机制保证并发修改不会静默丢失；发生冲突时保留双方版本并交由用户选择。
- **后台同步**：支持手动、前台、网络恢复触发，以及 Android WorkManager / iOS BGTask 调度。
- **跨平台**：移动端优先（iOS/iPadOS、Android），桌面端逐步完善。

## 平台支持 / Platforms

- 格间托管数据（Velock managed data）V1：iOS/iPadOS，通过专用 App Group 与格间交换数据。
- 本地文件夹与云端 Provider：Android、iOS/iPadOS。
- 桌面端：规划中。

## 开源与商业说明 / Open Source & Commercial Statement

**Open source / 开源**

Velock Sync is fully open source under the Apache-2.0 license. Anyone can audit the sync core, build it from source, or contribute new data sources and cloud providers.

本项目基于 Apache-2.0 许可证完全开源。任何人都可以审计同步核心、自行构建，也可以通过新增数据源和云端 Provider 参与贡献。

**Commercial note / 商业说明**

The project is maintained by Chongqing Win Data Technology Co., Ltd. Open source and the commercial operations of Velock are independent of each other: you may always build from source, self-host, or use versions from official channels. Using Velock Sync requires no Velock account and does not lock you into any specific cloud service.

本项目由重庆文数科技有限公司维护。开源与格间 App 的商业运营相互独立：你始终可以自行构建、自托管，也可以使用官方渠道提供的版本。使用 Velock Sync 无需注册 Velock 账号，也不会被绑定到任何特定云端服务。

## 格间已在 App Store 上架

<div style="text-align: left;">
  <a href="https://apps.apple.com/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">或</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
