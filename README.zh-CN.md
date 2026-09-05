# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync 是一款开源、跨平台的增量双向同步工具。它是格间（Velock）的独立同步伴侣 App，在不接触明文和密钥的前提下，把 Velock 已经加密并认证的数据同步到你选择的远端存储。

## 核心功能

- 增量双向同步：只传输新增或变化的内容；支持 checkpoint 恢复、断点续传与垃圾回收，已存在的数据不重复上传。
- 密文同步：只搬运格间生成的不透明加密增量包；Velock Sync 不持有格间主密钥或同步密钥，也不读取格间数据库。
- 多云端目标：已支持 WebDAV、Google Drive、OneDrive；百度网盘、阿里云盘等更多云端通过 Provider 适配器持续扩展。
- 多设备协同：版本向量与 tombstone 机制保证并发修改不会静默丢失；发生冲突时保留双方版本并交由用户选择。
- 后台同步：支持手动、前台、网络恢复触发，以及 Android WorkManager / iOS BGTask 调度。
- 跨平台：移动端优先（iOS/iPadOS、Android），桌面端逐步完善。

## 平台支持

- 格间托管数据（Velock managed data）V1：iOS/iPadOS，通过专用 App Group 与格间交换数据。
- iOS/iPadOS。
- 桌面端：规划中。

## 开源与商业说明

**开源**

本项目基于 Apache-2.0 许可证完全开源。任何人都可以审计同步核心、自行构建，也可以通过新增数据源和云端 Provider 参与贡献。

**商业说明**

本项目由重庆文数科技有限公司维护。开源与格间 App 的商业运营相互独立：你始终可以自行构建、自托管，也可以使用官方渠道提供的版本。使用 Velock Sync 无需注册 Velock 账号，也不会被绑定到任何特定云端服务。

## 格间已在 App Store 上架

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">或</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
