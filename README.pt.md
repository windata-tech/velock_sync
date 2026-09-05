# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

ta Velock.

## Principais funcionalidades

- Sincronização bidirecional incremental: só é transferido conteúdo novo ou alterado; com recuperação por checkpoint, carregamentos retomáveis e recolha de lixo; os dados existentes não são recarregados.
- Cifragem de ponta a ponta: no modo Velock, só são movidos deltas cifrados opacos gerados pelo Velock. O Velock Sync nunca detém a chave mestra nem as chaves de sincronização do Velock e nunca lê a sua base de dados.
- Sincronização genérica de pastas: utilizadores não Velock podem escolher uma pasta local, cifrada de ponta a ponta por predefinição, com um modo espelho simples.
- Vários destinos na nuvem: WebDAV, Google Drive e OneDrive são suportados; mais serviços como Baidu Netdisk e Aliyun Drive chegam através de adaptadores de Provider.
- Colaboração multi-dispositivo: vetores de versão e tombstones garantem que edições simultâneas nunca se perdem silenciosamente; em caso de conflito, ambas as versões são mantidas e escolhe o utilizador.
- Sincronização em segundo plano: acionamento manual, em primeiro plano e na recuperação da rede, além de Android WorkManager / iOS BGTask.
- Multiplataforma: mobile primeiro (iOS/iPadOS, Android); o ambiente de trabalho será melhorado gradualmente.

## Plataformas

- Dados geridos pelo Velock V1: iOS/iPadOS, com troca através de um App Group dedicado.
- Pastas escolhidas e providers na nuvem: Android e iOS/iPadOS.
- Ambiente de trabalho: planeado.

## Código aberto e nota comercial

**Código aberto**

O Velock Sync é totalmente open source sob a licença Apache-2.0. Qualquer pessoa pode auditar o núcleo de sincronização, compilá-lo a partir do código-fonte ou contribuir com novas fontes de dados e providers cloud.

**Nota comercial**

O projeto é mantido pela Chongqing Win Data Technology Co., Ltd. O código aberto e a operação comercial do Velock são independentes: pode sempre compilar a partir do código-fonte, autoalojar ou usar versões dos canais oficiais. Usar o Velock Sync não exige conta Velock nem o vincula a nenhum serviço cloud específico.

## O Velock está disponível na App Store

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">ou</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
