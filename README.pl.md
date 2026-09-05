# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync to wieloplatformowe, otwartoźródłowe narzędzie do przyrostowej dwukierunkowej synchronizacji. Dla użytkowników Velock to samodzielna aplikacja towarzysząca, która synchronizuje zaszyfrowane dane sejfu między Twoimi urządzeniami. Obsługuje również synchronizację wybranych folderów z szyfrowaniem end-to-end, bez konieczności posiadania konta Velock.

## Kluczowe funkcje

- Przyrostowa dwukierunkowa synchronizacja: przesyłana jest tylko nowa lub zmieniona zawartość; z odzyskiwaniem z checkpointów, wznawianiem wysyłania i odśmiecaniem; istniejące dane nie są przesyłane ponownie.
- Szyfrowanie end-to-end: w trybie Velock przenoszone są tylko nieprzezroczyste zaszyfrowane delty utworzone przez Velock. Velock Sync nigdy nie przechowuje klucza głównego ani kluczy synchronizacji Velock i nie czyta jego bazy danych.
ym.
- Wiele celów w chmurze: obsługiwane są WebDAV, Google Drive i OneDrive; kolejne chmury, takie jak Baidu Netdisk i Aliyun Drive, są dodawane przez adaptery Provider.
- Współpraca na wielu urządzeniach: wektory wersji i tombstone zapewniają, że równoczesne zmiany nigdy nie są po cichu tracone; w razie konfliktu obie wersje są zachowywane i to Ty wybierasz.
- Synchronizacja w tle: wyzwalacze ręczne, na pierwszym planie i po przywróceniu sieci, a także Android WorkManager / iOS BGTask.
- Wieloplatformowość: priorytet mobile (iOS/iPadOS, Android); wersja desktopowa jest stopniowo rozwijana.

## Platformy

- Dane zarządzane przez Velock V1: iOS/iPadOS, wymiana z Velock przez dedykowaną grupę App Group.
- Wybrane foldery i providery chmury: Android i iOS/iPadOS.
- Desktop: planowany.

## Open source i nota handlowa

**Open source**

Velock Sync jest w pełni otwartoźródłowy na licencji Apache-2.0. Każdy może przejrzeć rdzeń synchronizacji, zbudować go ze źródeł lub dodać nowe źródła danych i providery chmury.

**Nota handlowa**

Projekt jest utrzymywany przez Chongqing Win Data Technology Co., Ltd. Otwarte oprogramowanie i komercyjna działalność Velock są od siebie niezależne: zawsze możesz zbudować ze źródeł, samodzielnie hostować lub korzystać z wersji z oficjalnych kanałów. Korzystanie z Velock Sync nie wymaga konta Velock i nie wiąże Cię z żadną konkretną usługą chmurową.

## Velock jest dostępny w App Store

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">lub</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
