# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync is an open-source, cross-platform, incremental bidirectional sync companion for Velock. It transports data already encrypted and authenticated by Velock to the remote storage you choose, without handling plaintext or Velock keys.

## Key Features

- Incremental bidirectional sync: only new or changed content is transferred, with checkpoint recovery, resumable uploads, and garbage collection; existing data is never re-uploaded.
- Ciphertext sync: Velock Sync only moves opaque encrypted deltas produced by Velock. It never holds Velock's master key or sync keys and never reads Velock's database.
- Multiple cloud targets: WebDAV, Google Drive, and OneDrive are supported; more clouds such as Baidu Netdisk and Aliyun Drive are being added through provider adapters.
- Multi-device collaboration: version vectors and tombstones ensure concurrent edits are never silently lost; conflicts keep both versions and let you choose.
- Background sync: manual, foreground, and network-recovery triggers, plus Android WorkManager / iOS BGTask scheduling.
- Cross-platform: mobile-first (iOS/iPadOS, Android), with desktop support being gradually improved.

## Platforms

- Velock managed data V1: iOS/iPadOS, exchanging data with Velock through a dedicated App Group.
- iOS/iPadOS.
- Desktop: planned.

## Open Source & Commercial Statement

**Open source**

Velock Sync is fully open source under the Apache-2.0 license. Anyone can audit the sync core, build it from source, or contribute new data sources and cloud providers.

**Commercial note**

The project is maintained by Chongqing Win Data Technology Co., Ltd. Open source and the commercial operations of Velock are independent of each other: you may always build from source, self-host, or use versions from official channels. Using Velock Sync requires no Velock account and does not lock you into any specific cloud service.

## Velock is available on the App Store

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">or</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
