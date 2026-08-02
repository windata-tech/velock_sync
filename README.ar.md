# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync أداة مزامنة ثنائية الاتجاه تدريجية، مفتوحة المصدر، ومتعددة المنصات. لمستخدمي Velock، هو التطبيق المصاحب المستقل الذي يزامن بيانات الخزنة المشفرة بين أجهزتك الخاصة. كما يدعم مزامنة المجلدات التي يختارها المستخدم بتشفير من طرف إلى طرف، دون الحاجة إلى حساب Velock.

## الميزات الأساسية

- مزامنة ثنائية الاتجاه تدريجية: يتم نقل المحتوى الجديد أو المعدل فقط؛ مع استعادة نقطة التحقق، واستئناف التحميل، وجمع القمامة؛ لا يتم إعادة تحميل البيانات الموجودة.
- تشفير من طرف إلى طرف: في وضع Velock، يتم نقل حزم دلتا المشفرة غير الشفافة التي ينتجها Velock فقط. لا يحتفظ Velock Sync أبداً بالمفتاح الرئيسي أو مفاتيح المزامنة لـ Velock، ولا يقرأ قاعدة بياناته.
- مزامنة المجلدات العامة: يمكن للمستخدمين غير Velock اختيار مجلد محلي، مشفر من طرف إلى طرف افتراضياً، مع وضع نسخة مطابقة بسيط.
- أهداف سحابية متعددة: يدعم WebDAV وGoogle Drive وOneDrive؛ المزيد من الخدمات مثل Baidu Netdisk وAliyun Drive تُضاف عبر محولات Provider.
- التعاون متعدد الأجهزة: ناقلات الإصدارات وآلية tombstone تضمن عدم فقدان التعديلات المتزامنة بصمت؛ عند التعارض، يتم الاحتفاظ بالنسختين ويُترك الاختيار لك.
- المزامنة في الخلفية: تشغيل يدوي، وفي المقدمة، وعند استعادة الشبكة، بالإضافة إلى جدولة Android WorkManager / iOS BGTask.
- متعدد المنصات: الأجهزة المحمولة أولاً (iOS/iPadOS وAndroid)؛ سطح المكتب قيد التحسين تدريجياً.

## المنصات

- بيانات Velock المدارة V1: iOS/iPadOS، مع تبادل البيانات مع Velock عبر App Group مخصص.
- المجلدات المختارة وموفرو السحابة: Android وiOS/iPadOS.
- سطح المكتب: مخطط.

## المصدر المفتوح والملاحظة التجارية

**المصدر المفتوح**

Velock Sync مفتوح المصدر بالكامل بموجب رخصة Apache-2.0. يمكن لأي شخص مراجعة نواة المزامنة، أو بناؤها من المصدر، أو المساهمة بمصادر بيانات وموفري سحابة جدد.

**ملاحظة تجارية**

يُدار المشروع بواسطة Chongqing Win Data Technology Co., Ltd. المصدر المفتوح والعمليات التجارية لـ Velock مستقلان عن بعضهما: يمكنك دائماً البناء من المصدر أو الاستضافة الذاتية أو استخدام إصدارات من القنوات الرسمية. استخدام Velock Sync لا يتطلب حساب Velock ولا يقيّدك بأي خدمة سحابية معينة.

## يتوفر Velock في App Store

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">أو</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
