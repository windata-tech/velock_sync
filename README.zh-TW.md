# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync 是一款開源、跨平台的增量雙向同步工具。對格間（Velock）使用者而言，它是格間的獨立同步伴侶 App，可以在你自己的裝置之間同步經過端到端加密的格間資料；對一般使用者而言，它也可以端到端加密地同步你主動授權的本機資料夾，無需註冊 Velock 帳號。

## 核心功能

- 增量雙向同步：只傳輸新增或變更的內容；支援 checkpoint 復原、斷點續傳與垃圾回收，已存在的資料不重複上傳。
- 端到端加密：格間模式下只搬運格間產生的不透明加密增量包，Velock Sync 不持有格間主金鑰或同步金鑰，也不讀取格間資料庫。
- 通用資料夾同步：非格間使用者可選擇本機資料夾，預設端到端加密，也支援一般鏡像模式。
- 多雲端目標：已支援 WebDAV、Google Drive、OneDrive；百度網盤、阿里雲盤等更多雲端透過 Provider 介面卡持續擴充。
- 多裝置協同：版本向量與 tombstone 機制確保並行修改不會被靜默遺失；發生衝突時保留雙方版本並交由使用者選擇。
- 背景同步：支援手動、前景、網路恢復觸發，以及 Android WorkManager / iOS BGTask 排程。
- 跨平台：行動端優先（iOS/iPadOS、Android），桌面端逐步完善。

## 平台支援

- 格間託管資料（Velock managed data）V1：iOS/iPadOS，透過專用 App Group 與格間交換資料。
- 本機資料夾與雲端 Provider：Android、iOS/iPadOS。
- 桌面端：規劃中。

## 開源與商業說明

**開源**

本專案基於 Apache-2.0 授權條款完全開源。任何人都可以審計同步核心、自行建置，也可以透過新增資料來源和雲端 Provider 參與貢獻。

**商業說明**

本專案由重慶文數科技有限公司維護。開源與格間 App 的商業營運相互獨立：你始終可以自行建置、自架，也可以使用官方管道提供的版本。使用 Velock Sync 無需註冊 Velock 帳號，也不會被綁定到任何特定雲端服務。

## 格間已在 App Store 上架

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">或</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
