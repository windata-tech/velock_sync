# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync ist ein quelloffenes, plattformübergreifendes Werkzeug für inkrementelle bidirektionale Synchronisierung. Für Velock-Nutzer ist es die eigenständige Begleit-App, die verschlüsselte Tresordaten zwischen Ihren eigenen Geräten synchronisiert. Es unterstützt auch die Synchronisierung benutzergewählter Ordner mit Ende-zu-Ende-Verschlüsselung, ohne ein Velock-Konto zu benötigen.

## Hauptfunktionen

- Inkrementelle bidirektionale Synchronisierung: Es werden nur neue oder geänderte Inhalte übertragen; mit Checkpoint-Wiederherstellung, fortsetzbaren Uploads und Garbage Collection; vorhandene Daten werden nicht erneut hochgeladen.
- Ende-zu-Ende-Verschlüsselung: Im Velock-Modus werden nur undurchsichtige verschlüsselte Deltas von Velock übertragen. Velock Sync besitzt weder den Hauptschlüssel noch die Synchronisierungsschlüssel von Velock und liest nie dessen Datenbank.
- Allgemeine Ordnersynchronisierung: Nicht-Velock-Nutzer können einen lokalen Ordner wählen, standardmäßig Ende-zu-Ende-verschlüsselt, mit einem einfachen Spiegelmodus.
- Mehrere Cloud-Ziele: WebDAV, Google Drive und OneDrive werden unterstützt; weitere Clouds wie Baidu Netdisk und Aliyun Drive folgen über Provider-Adapter.
- Multi-Geräte-Zusammenarbeit: Versionsvektoren und Tombstones verhindern, dass parallele Änderungen stillschweigend verloren gehen; bei Konflikten bleiben beide Versionen erhalten und Sie wählen.
- Hintergrundsynchronisierung: manuelle, Vordergrund- und Netzwerkwiederherstellungs-Auslöser sowie Android WorkManager / iOS BGTask.
- Plattformübergreifend: Mobile zuerst (iOS/iPadOS, Android), Desktop wird schrittweise ausgebaut.

## Plattformen

- Von Velock verwaltete Daten V1: iOS/iPadOS, Austausch mit Velock über eine dedizierte App Group.
- Benutzergewählte Ordner und Cloud-Provider: Android und iOS/iPadOS.
- Desktop: geplant.

## Open Source & Kommerzieller Hinweis

**Open Source**

Velock Sync ist unter der Apache-2.0-Lizenz vollständig Open Source. Jeder kann den Synchronisierungskern prüfen, aus dem Quellcode bauen oder neue Datenquellen und Cloud-Provider beisteuern.

**Kommerzieller Hinweis**

Das Projekt wird von der Chongqing Win Data Technology Co., Ltd. gepflegt. Open Source und der kommerzielle Betrieb von Velock sind voneinander unabhängig: Sie können jederzeit selbst bauen, selbst hosten oder Versionen über offizielle Kanäle verwenden. Die Nutzung von Velock Sync erfordert kein Velock-Konto und bindet Sie an keinen bestimmten Cloud-Dienst.

## Velock ist im App Store erhältlich

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">oder</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
