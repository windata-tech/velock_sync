# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync는 오픈소스, 크로스 플랫폼, 증분 양방향 동기화 도구입니다. Velock(格間) 사용자에게는 암호화된 보관함 데이터를 자신의 기기 간에 동기화하는 독립형 동반 앱입니다. 또한 Velock 계정 없이 사용자가 선택한 폴더를 종단 간 암호화로 동기화할 수 있습니다.

## 주요 기능

- 증분 양방향 동기화: 새 콘텐츠 또는 변경된 콘텐츠만 전송하며, 체크포인트 복구, 이어 올리기, 가비지 컬렉션을 지원합니다. 기존 데이터는 다시 업로드되지 않습니다.
- 종단 간 암호화: Velock 모드에서는 Velock이 생성한 불투명한 암호화 델타만 이동합니다. Velock Sync는 Velock의 마스터 키나 동기화 키를 보유하지 않으며 데이터베이스를 읽지 않습니다.
- 일반 폴더 동기화: Velock 비사용자도 로컬 폴더를 선택할 수 있으며 기본적으로 종단 간 암호화되고 일반 미러 모드도 지원합니다.
- 여러 클라우드 대상: WebDAV, Google Drive, OneDrive를 지원하며 Baidu Netdisk, Aliyun Drive 등 더 많은 클라우드는 Provider 어댑터를 통해 계속 추가됩니다.
- 다중 기기 협업: 버전 벡터와 tombstone 메커니즘으로 동시 편집이 조용히 유실되지 않습니다. 충돌 시 양쪽 버전을 모두 보존하고 선택은 사용자에게 맡깁니다.
- 백그라운드 동기화: 수동, 포그라운드, 네트워크 복구 트리거와 Android WorkManager / iOS BGTask 스케줄링을 지원합니다.
- 크로스 플랫폼: 모바일 우선(iOS/iPadOS, Android)이며 데스크톱은 점진적으로 개선됩니다.

## 지원 플랫폼

- Velock 관리 데이터 V1: iOS/iPadOS, 전용 App Group을 통해 Velock과 데이터를 교환합니다.
- 선택한 폴더 및 클라우드 Provider: Android, iOS/iPadOS.
- 데스크톱: 계획 중.

## 오픈소스 및 상업적 고지

**오픈소스**

Velock Sync는 Apache-2.0 라이선스 하에 완전한 오픈소스입니다. 누구나 동기화 코어를 감사하고, 소스에서 빌드하고, 새 데이터 소스와 클라우드 Provider를 기여할 수 있습니다.

**상업적 고지**

이 프로젝트는 Chongqing Win Data Technology Co., Ltd.가 유지 관리합니다. 오픈소스와 Velock의 상업적 운영은 서로 독립적입니다. 언제든 소스에서 빌드하거나, 자체 호스팅하거나, 공식 채널의 버전을 사용할 수 있습니다. Velock Sync 사용에는 Velock 계정이 필요하지 않으며 특정 클라우드 서비스에 묶이지 않습니다.

## Velock은 App Store에서 이용할 수 있습니다

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">또는</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
