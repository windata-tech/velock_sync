# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync एक ओपन-सोर्स, क्रॉस-प्लेटफ़ॉर्म, वृद्धिशील द्वि-दिशात्मक सिंक टूल है। Velock उपयोगकर्ताओं के लिए, यह एक स्टैंडअलोन साथी ऐप है जो आपके एन्क्रिप्टेड वॉल्ट डेटा को आपके अपने डिवाइसों के बीच सिंक करता है। यह उपयोगकर्ता द्वारा चुने गए फ़ोल्डरों को एंड-टू-एंड एन्क्रिप्शन के साथ सिंक करने का भी समर्थन करता है, बिना Velock खाते की आवश्यकता के।

## मुख्य विशेषताएँ

- वृद्धिशील द्वि-दिशात्मक सिंक: केवल नई या बदली हुई सामग्री स्थानांतरित होती है; चेकपॉइंट पुनर्प्राप्ति, फिर से शुरू होने वाले अपलोड और कचरा संग्रहण के साथ; मौजूदा डेटा दोबारा अपलोड नहीं होता।
- एंड-टू-एंड एन्क्रिप्शन: Velock मोड में केवल Velock द्वारा उत्पन्न अपारदर्शी एन्क्रिप्टेड डेल्टा स्थानांतरित होते हैं। Velock Sync कभी भी Velock की मास्टर कुंजी या सिंक कुंजियाँ नहीं रखता और उसका डेटाबेस नहीं पढ़ता।
- सामान्य फ़ोल्डर सिंक: गैर-Velock उपयोगकर्ता एक स्थानीय फ़ोल्डर चुन सकते हैं, डिफ़ॉल्ट रूप से एंड-टू-एंड एन्क्रिप्टेड, साथ ही सामान्य मिरर मोड।
- कई क्लाउड लक्ष्य: WebDAV, Google Drive और OneDrive समर्थित हैं; Baidu Netdisk और Aliyun Drive जैसे और क्लाउड Provider एडाप्टर के माध्यम से जोड़े जा रहे हैं।
- बहु-डिवाइस सहयोग: वर्जन वेक्टर और tombstone तंत्र सुनिश्चित करते हैं कि समवर्ती संपादन कभी चुपचाप न खोएँ; संघर्ष की स्थिति में दोनों संस्करण रखे जाते हैं और चुनाव आपका होता है।
- बैकग्राउंड सिंक: मैनुअल, फोरग्राउंड और नेटवर्क-रिकवरी ट्रिगर, साथ ही Android WorkManager / iOS BGTask शेड्यूलिंग।
- क्रॉस-प्लेटफ़ॉर्म: मोबाइल-प्रथम (iOS/iPadOS, Android); डेस्कटॉप धीरे-धीरे बेहतर हो रहा है।

## प्लेटफ़ॉर्म

- Velock द्वारा प्रबंधित डेटा V1: iOS/iPadOS, समर्पित App Group के माध्यम से Velock के साथ डेटा का आदान-प्रदान।
- चुने गए फ़ोल्डर और क्लाउड Provider: Android और iOS/iPadOS।
- डेस्कटॉप: योजनाबद्ध।

## ओपन सोर्स और व्यावसायिक नोट

**ओपन सोर्स**

Velock Sync Apache-2.0 लाइसेंस के अंतर्गत पूरी तरह से ओपन सोर्स है। कोई भी सिंक कोर का ऑडिट कर सकता है, स्रोत से इसे बना सकता है, या नए डेटा स्रोतों और क्लाउड Provider का योगदान कर सकता है।

**व्यावसायिक नोट**

परियोजना का रखरखाव Chongqing Win Data Technology Co., Ltd. द्वारा किया जाता है। ओपन सोर्स और Velock के व्यावसायिक संचालन एक-दूसरे से स्वतंत्र हैं: आप हमेशा स्रोत से बना सकते हैं, स्वयं होस्ट कर सकते हैं, या आधिकारिक चैनलों से संस्करण उपयोग कर सकते हैं। Velock Sync का उपयोग करने के लिए Velock खाते की आवश्यकता नहीं है और यह आपको किसी विशेष क्लाउड सेवा से बाँधता नहीं है।

## Velock App Store पर उपलब्ध है

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">या</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
