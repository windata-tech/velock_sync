# Velock Sync

**Language / 语言 / Sprache / Idioma / Langue / 言語 / 언어 / Taal / Język / Язык / Lingua / Dil / Ngôn ngữ / Bahasa / भाषा / اللغة:**
[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [Deutsch](README.de.md) · [Español](README.es.md) · [Français](README.fr.md) · [हिन्दी](README.hi.md) · [Bahasa Indonesia](README.id.md) · [Italiano](README.it.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Nederlands](README.nl.md) · [Polski](README.pl.md) · [Português](README.pt.md) · [Русский](README.ru.md) · [Türkçe](README.tr.md) · [Tiếng Việt](README.vi.md) · [العربية](README.ar.md)

---

Velock Sync là công cụ đồng bộ hai chiều gia tăng, mã nguồn mở và đa nền tảng. Với người dùng Velock, đây là ứng dụng đồng hành độc lập giúp đồng bộ dữ liệu két đã mã hóa giữa các thiết bị của chính bạn. Nó cũng hỗ trợ đồng bộ các thư mục do người dùng chọn với mã hóa đầu cuối, không cần tài khoản Velock.

## Tính năng chính

- Đồng bộ hai chiều gia tăng: chỉ truyền nội dung mới hoặc đã thay đổi; hỗ trợ khôi phục checkpoint, tải lên tiếp tục và thu gom rác; dữ liệu hiện có không bị tải lại.
- Mã hóa đầu cuối: ở chế độ Velock, chỉ di chuyển các delta mã hóa không rõ ràng do Velock tạo ra. Velock Sync không bao giờ nắm khóa chính hoặc khóa đồng bộ của Velock và không đọc cơ sở dữ liệu của Velock.
- Đồng bộ thư mục thông thường: người dùng không dùng Velock có thể chọn thư mục cục bộ, được mã hóa đầu cuối theo mặc định, kèm chế độ phản chiếu đơn giản.
- Nhiều đích đám mây: đã hỗ trợ WebDAV, Google Drive và OneDrive; nhiều đám mây khác như Baidu Netdisk và Aliyun Drive sẽ được bổ sung qua bộ điều hợp Provider.
- Cộng tác đa thiết bị: vector phiên bản và cơ chế tombstone đảm bảo các thay đổi đồng thời không bao giờ bị mất âm thầm; khi xung đột, cả hai phiên bản đều được giữ lại và bạn lựa chọn.
- Đồng bộ nền: kích hoạt thủ công, ở tiền cảnh và khi khôi phục mạng, cùng lập lịch Android WorkManager / iOS BGTask.
- Đa nền tảng: ưu tiên di động (iOS/iPadOS, Android); máy tính để bàn sẽ được cải thiện dần.

## Nền tảng

- Dữ liệu do Velock quản lý V1: iOS/iPadOS, trao đổi dữ liệu với Velock qua App Group chuyên dụng.
- Thư mục đã chọn và Provider đám mây: Android và iOS/iPadOS.
- Máy tính để bàn: đang lên kế hoạch.

## Mã nguồn mở và ghi chú thương mại

**Mã nguồn mở**

Velock Sync hoàn toàn mã nguồn mở theo giấy phép Apache-2.0. Bất kỳ ai cũng có thể kiểm toán lõi đồng bộ, tự xây dựng từ mã nguồn hoặc đóng góp nguồn dữ liệu và Provider đám mây mới.

**Ghi chú thương mại**

Dự án được duy trì bởi Chongqing Win Data Technology Co., Ltd. Mã nguồn mở và hoạt động thương mại của Velock độc lập với nhau: bạn luôn có thể tự xây dựng từ mã nguồn, tự lưu trữ hoặc dùng phiên bản từ kênh chính thức. Sử dụng Velock Sync không yêu cầu tài khoản Velock và không ràng buộc bạn vào bất kỳ dịch vụ đám mây cụ thể nào.

## Velock có sẵn trên App Store

<div style="text-align: left;">
  <a href="https://apps.apple.com/us/app/velock-offline-privacy-guard/id6748689303">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="160">
  </a>
</div>

<p style="text-align: left;">hoặc</p>

<div style="text-align: left;">
  <img src="./velock_qrcode.png" alt="App QR Code" width="160">
</div>
