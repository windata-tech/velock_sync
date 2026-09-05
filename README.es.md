# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync es una herramienta de sincronización bidireccional incremental, multiplataforma y de código abierto. Para los usuarios de Velock, es la app complementaria independiente que sincroniza los datos cifrados de tu bóveda entre tus propios dispositivos. También admite sincronizar carpetas que elijas con cifrado de extremo a extremo, sin necesidad de una cuenta de Velock.

## Características principales

- Sincronización bidireccional incremental: solo se transfiere contenido nuevo o modificado; con recuperación por checkpoint, cargas reanudables y recolección de basura; los datos existentes no se vuelven a subir.
- Cifrado de extremo a extremo: en el modo Velock solo se mueven deltas cifrados opacos generados por Velock. Velock Sync nunca posee la clave maestra ni las claves de sincronización de Velock, ni lee su base de datos.
ormal.
- Varios destinos en la nube: compatibles con WebDAV, Google Drive y OneDrive; más nubes como Baidu Netdisk y Aliyun Drive se añaden mediante adaptadores de Provider.
- Colaboración multidispositivo: los vectores de versión y los tombstones garantizan que las ediciones simultáneas nunca se pierdan en silencio; ante un conflicto se conservan ambas versiones y eliges tú.
- Sincronización en segundo plano: activación manual, en primer plano y al recuperar la red, además de Android WorkManager / iOS BGTask.
- Multiplataforma: prioridad móvil (iOS/iPadOS, Android); el escritorio se irá mejorando progresivamente.

## Plataformas

- Datos gestionados por Velock V1: iOS/iPadOS, con intercambio de datos con Velock mediante un App Group dedicado.
- Carpetas elegidas y providers en la nube: Android e iOS/iPadOS.
- Escritorio: planificado.

## Código abierto y nota comercial

**Código abierto**

Velock Sync es totalmente de código abierto bajo la licencia Apache-2.0. Cualquier persona puede auditar el núcleo de sincronización, compilarlo desde el código fuente o contribuir con nuevas fuentes de datos y providers.

**Nota comercial**

El proyecto es mantenido por Chongqing Win Data Technology Co., Ltd. El código abierto y la operación comercial de Velock son independientes: siempre puedes compilar desde el código fuente, autoalojarlo o usar versiones de canales oficiales. Usar Velock Sync no requiere cuenta de Velock ni te ata a ningún servicio en la nube concreto.

## Velock está disponible en App Store

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">o</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
