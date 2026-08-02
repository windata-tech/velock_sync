# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync est un outil de synchronisation bidirectionnelle incrémentale, multiplateforme et open source. Pour les utilisateurs de Velock, c’est l’app compagnon autonome qui synchronise les données chiffrées de votre coffre entre vos propres appareils. Il permet aussi de synchroniser des dossiers de votre choix avec chiffrement de bout en bout, sans compte Velock.

## Fonctionnalités principales

- Synchronisation bidirectionnelle incrémentale : seuls les contenus nouveaux ou modifiés sont transférés, avec restauration par checkpoint, reprise des téléversements et nettoyage ; les données existantes ne sont jamais retéléversées.
- Chiffrement de bout en bout : en mode Velock, seuls des deltas chiffrés opaques générés par Velock sont déplacés. Velock Sync ne détient ni la clé maîtresse ni les clés de synchronisation de Velock et ne lit jamais sa base de données.
- Synchronisation de dossiers génériques : les utilisateurs non Velock peuvent choisir un dossier local, chiffré de bout en bout par défaut, avec un mode miroir simple.
- Plusieurs cibles cloud : WebDAV, Google Drive et OneDrive sont pris en charge ; d’autres services comme Baidu Netdisk et Aliyun Drive arrivent via des adaptateurs de Provider.
- Collaboration multi-appareils : les vecteurs de version et les tombstones garantissent que les modifications simultanées ne sont jamais perdues silencieusement ; en cas de conflit, les deux versions sont conservées et vous choisissez.
- Synchronisation en arrière-plan : déclenchement manuel, au premier plan et à la reprise du réseau, plus Android WorkManager / iOS BGTask.
- Multiplateforme : mobile d’abord (iOS/iPadOS, Android) ; le bureau sera amélioré progressivement.

## Plateformes

- Données gérées par Velock V1 : iOS/iPadOS, avec échange via un App Group dédié.
- Dossiers choisis et providers cloud : Android et iOS/iPadOS.
- Bureau : prévu.

## Open source et note commerciale

**Open source**

Velock Sync est entièrement open source sous licence Apache-2.0. N’importe qui peut auditer le noyau de synchronisation, le compiler depuis les sources ou contribuer de nouvelles sources de données et providers cloud.

**Note commerciale**

Le projet est maintenu par Chongqing Win Data Technology Co., Ltd. L’open source et l’exploitation commerciale de Velock sont indépendants : vous pouvez toujours compiler depuis les sources, auto-héberger ou utiliser des versions des canaux officiels. L’utilisation de Velock Sync ne nécessite aucun compte Velock et ne vous lie à aucun service cloud en particulier.

## Velock est disponible sur l’App Store

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">ou</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
