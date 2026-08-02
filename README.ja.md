# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync は、オープンソース・クロスプラットフォームの増分双方向同期ツールです。Velock（格間）ユーザーにとっては、暗号化された保管庫データを自分のデバイス間で同期する独立した連携アプリです。Velock アカウントを必要とせず、ユーザーが選択したフォルダーをエンドツーエンド暗号化で同期することもできます。

## 主な機能

- 増分双方向同期：新規または変更されたコンテンツのみを転送します。チェックポイント復元、再開可能なアップロード、ガベージコレクションに対応し、既存データは再アップロードされません。
- エンドツーエンド暗号化：Velock モードでは、Velock が生成した不透明な暗号化デルタのみを移動します。Velock Sync は Velock のマスターキーや同期キーを保持せず、データベースも読み取りません。
- 汎用フォルダー同期：Velock 以外のユーザーもローカルフォルダーを選択可能。デフォルトでエンドツーエンド暗号化され、通常のミラーモードにも対応します。
- 複数のクラウド先：WebDAV、Google Drive、OneDrive に対応。Baidu Netdisk や Aliyun Drive などは Provider アダプターで順次追加されます。
- マルチデバイス連携：バージョンベクターと tombstone により、同時編集が黙って失われることはありません。競合時は両バージョンが保持され、選択はユーザーに委ねられます。
- バックグラウンド同期：手動・フォアグラウンド・ネットワーク復旧トリガーに加え、Android WorkManager / iOS BGTask に対応。
- クロスプラットフォーム：モバイル優先（iOS/iPadOS、Android）。デスクトップは段階的に改善予定。

## 対応プラットフォーム

- Velock 管理データ V1：iOS/iPadOS。専用 App Group を通じて Velock とデータを交換します。
- 選択したフォルダーとクラウド Provider：Android、iOS/iPadOS。
- デスクトップ：計画中。

## オープンソースと商業上の説明

**オープンソース**

Velock Sync は Apache-2.0 ライセンスの下で完全にオープンソースです。誰でも同期コアを監査し、ソースからビルドし、新しいデータソースやクラウド Provider を提供できます。

**商業上の説明**

本プロジェクトは重慶文数科技有限公司（Chongqing Win Data Technology Co., Ltd.）が維持しています。オープンソースと Velock の商業運営は互いに独立しています。ソースからビルドする、自己ホストする、公式チャネルのバージョンを使う、いつでも選択できます。Velock Sync の利用に Velock アカウントは不要で、特定のクラウドサービスに縛られることもありません。

## Velock は App Store で公開されています

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">または</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
