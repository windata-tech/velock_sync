# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync, açık kaynaklı, çok platformlu, artımlı çift yönlü bir senkronizasyon aracıdır. Velock kullanıcıları için, şifrelenmiş kasa verilerini kendi cihazlarınız arasında senkronize eden bağımsız yardımcı uygulamadır. Ayrıca Velock hesabı gerektirmeden, kullanıcı tarafından seçilen klasörlerin uçtan uca şifreli senkronizasyonunu destekler.

## Temel Özellikler

- Artımlı çift yönlü senkronizasyon: yalnızca yeni veya değiştirilmiş içerik aktarılır; kontrol noktası kurtarma, sürdürülebilir yükleme ve çöp toplama desteklenir; mevcut veriler yeniden yüklenmez.
- Uçtan uca şifreleme: Velock modunda yalnızca Velock tarafından üretilen opak şifreli deltalar taşınır. Velock Sync, Velock'un ana anahtarını veya senkronizasyon anahtarlarını asla tutmaz ve veritabanını okumaz.
- Genel klasör senkronizasyonu: Velock kullanmayanlar yerel bir klasör seçebilir; varsayılan olarak uçtan uca şifreli, ayrıca düz ayna modu da sunulur.
- Birden çok bulut hedefi: WebDAV, Google Drive ve OneDrive desteklenir; Baidu Netdisk ve Aliyun Drive gibi daha fazla bulut, Provider bağdaştırıcılarıyla ekleniyor.
- Çok cihazlı iş birliği: sürüm vektörleri ve tombstone mekanizması, eş zamanlı değişikliklerin sessizce kaybolmamasını sağlar; çakışmada her iki sürüm korunur ve seçim size bırakılır.
- Arka plan senkronizasyonu: manuel, ön planda ve ağ kurtarma tetikleyicileri ile Android WorkManager / iOS BGTask zamanlaması.
- Çok platformlu: önce mobil (iOS/iPadOS, Android); masaüstü kademeli olarak geliştiriliyor.

## Platformlar

- Velock tarafından yönetilen veriler V1: iOS/iPadOS; Velock ile özel bir App Group üzerinden veri alışverişi yapar.
- Seçilen klasörler ve bulut Provider'ları: Android ve iOS/iPadOS.
- Masaüstü: planlanıyor.

## Açık Kaynak ve Ticari Not

**Açık kaynak**

Velock Sync, Apache-2.0 lisansı altında tamamen açık kaynaktır. Herkes senkronizasyon çekirdeğini denetleyebilir, kaynak koddan derleyebilir veya yeni veri kaynakları ve bulut Provider'larıyla katkıda bulunabilir.

**Ticari not**

Proje, Chongqing Win Data Technology Co., Ltd. tarafından sürdürülmektedir. Açık kaynak ile Velock'un ticari operasyonları birbirinden bağımsızdır: her zaman kaynak koddan derleyebilir, kendi sunucunuzda barındırabilir veya resmi kanallardan sürümleri kullanabilirsiniz. Velock Sync kullanmak için Velock hesabı gerekmez ve sizi belirli bir bulut hizmetine bağlamaz.

## Velock App Store'da mevcuttur

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">veya</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
