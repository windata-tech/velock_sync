# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync adalah alat sinkronisasi dua arah inkremental, sumber terbuka, dan lintas platform. Bagi pengguna Velock, ini adalah aplikasi pendamping mandiri yang menyinkronkan data brankas terenkripsi antar perangkat Anda sendiri. Aplikasi ini juga mendukung sinkronisasi folder pilihan pengguna dengan enkripsi ujung-ke-ujung, tanpa memerlukan akun Velock.

## Fitur Utama

- Sinkronisasi dua arah inkremental: hanya konten baru atau yang berubah yang ditransfer; dengan pemulihan checkpoint, unggahan yang dapat dilanjutkan, dan pembersihan; data yang ada tidak diunggah ulang.
- Enkripsi ujung-ke-ujung: dalam mode Velock, hanya delta terenkripsi buram yang dihasilkan Velock yang dipindahkan. Velock Sync tidak pernah memegang kunci utama atau kunci sinkronisasi Velock dan tidak membaca basis datanya.
- Sinkronisasi folder umum: pengguna non-Velock dapat memilih folder lokal, terenkripsi ujung-ke-ujung secara default, dengan mode cermin biasa.
- Beberapa tujuan cloud: WebDAV, Google Drive, dan OneDrive didukung; lebih banyak cloud seperti Baidu Netdisk dan Aliyun Drive ditambahkan melalui adaptor Provider.
- Kolaborasi multi-perangkat: vektor versi dan tombstone memastikan perubahan bersamaan tidak pernah hilang secara diam-diam; saat konflik, kedua versi dipertahankan dan Anda yang memilih.
- Sinkronisasi latar belakang: pemicu manual, latar depan, dan pemulihan jaringan, serta penjadwalan Android WorkManager / iOS BGTask.
- Lintas platform: mobile-first (iOS/iPadOS, Android); desktop dikembangkan secara bertahap.

## Platform

- Data terkelola Velock V1: iOS/iPadOS, bertukar data dengan Velock melalui App Group khusus.
- Folder pilihan dan Provider cloud: Android dan iOS/iPadOS.
- Desktop: direncanakan.

## Sumber Terbuka & Catatan Komersial

**Sumber terbuka**

Velock Sync sepenuhnya sumber terbuka di bawah lisensi Apache-2.0. Siapa pun dapat mengaudit inti sinkronisasi, membangunnya dari sumber, atau berkontribusi sumber data dan Provider cloud baru.

**Catatan komersial**

Proyek ini dikelola oleh Chongqing Win Data Technology Co., Ltd. Sumber terbuka dan operasi komersial Velock saling independen: Anda selalu dapat membangun dari sumber, melakukan hosting sendiri, atau menggunakan versi dari kanal resmi. Menggunakan Velock Sync tidak memerlukan akun Velock dan tidak mengikat Anda ke layanan cloud tertentu.

## Velock tersedia di App Store

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">atau</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
