# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync is een open-source, platformonafhankelijk hulpmiddel voor incrementele bidirectionele synchronisatie. Voor Velock-gebruikers is het de zelfstandige begeleidende app die versleutelde kluisgegevens tussen uw eigen apparaten synchroniseert. Het ondersteunt ook het synchroniseren van door de gebruiker gekozen mappen met end-to-end-versleuteling, zonder een Velock-account.

## Belangrijkste functies

- Incrementele bidirectionele synchronisatie: alleen nieuwe of gewijzigde inhoud wordt overgedragen; met checkpoint-herstel, hervatbare uploads en garbage collection; bestaande gegevens worden niet opnieuw geüpload.
- End-to-end-versleuteling: in de Velock-modus worden alleen ondoorzichtige versleutelde delta's van Velock verplaatst. Velock Sync bezit nooit de hoofdsleutel of synchronisatiesleutels van Velock en leest nooit de database.
- Algemene mapsynchronisatie: niet-Velock-gebruikers kunnen een lokale map kiezen, standaard end-to-end versleuteld, met een eenvoudige spiegelfunctie.
- Meerdere clouddoelen: WebDAV, Google Drive en OneDrive worden ondersteund; meer clouds zoals Baidu Netdisk en Aliyun Drive volgen via Provider-adapters.
- Samenwerking op meerdere apparaten: versievectoren en tombstones zorgen ervoor dat gelijktijdige wijzigingen nooit stil verloren gaan; bij een conflict worden beide versies behouden en kiest u.
- Achtergrondsynchronisatie: handmatige, voorgrond- en netwerkhersteltriggers, plus Android WorkManager / iOS BGTask.
- Platformonafhankelijk: mobiel eerst (iOS/iPadOS, Android); desktop wordt geleidelijk verbeterd.

## Platforms

- Door Velock beheerde gegevens V1: iOS/iPadOS, met gegevensuitwisseling via een specifieke App Group.
- Gekozen mappen en cloudproviders: Android en iOS/iPadOS.
- Desktop: gepland.

## Open source en commerciële opmerking

**Open source**

Velock Sync is volledig open source onder de Apache-2.0-licentie. Iedereen kan de synchronisatiekern controleren, uit de broncode bouwen of bijdragen met nieuwe gegevensbronnen en cloudproviders.

**Commerciële opmerking**

Het project wordt onderhouden door Chongqing Win Data Technology Co., Ltd. Open source en de commerciële activiteiten van Velock zijn onafhankelijk van elkaar: u kunt altijd zelf bouwen, zelf hosten of versies uit officiële kanalen gebruiken. Voor Velock Sync is geen Velock-account nodig en u wordt niet aan een specifieke clouddienst gebonden.

## Velock is beschikbaar in de App Store

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">of</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
