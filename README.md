> [!IMPORTANT]
> **Ghi nhận Tác giả gốc / Original Author Attribution**
>
> Đây là phiên bản tùy chỉnh (custom fork) phát triển dựa trên dự án mã nguồn mở **[Maccy](https://github.com/p0deje/Maccy)** của tác giả **Alex Rodionov ([@p0deje](https://github.com/p0deje))**.
> - **Dự án gốc (Upstream Repository)**: [https://github.com/p0deje/Maccy](https://github.com/p0deje/Maccy)
> - **Trang chủ chính thức của tác giả gốc**: [https://maccy.app](https://maccy.app)
> - **Bản quyền gốc & Giấy phép**: `Copyright (c) 2025 Alex Rodionov` — phân phối theo giấy phép **[MIT License](./LICENSE)** (xem chi tiết tại **[NOTICE.md](./NOTICE.md)**).
> - **Người tùy chỉnh & duy trì bản fork**: **Hung Le Xuan** (`hungmtuci@gmail.com` / [@hungmtuci](https://github.com/hungmtuci)).

---

## 🚀 Các tính năng mở rộng trong bản tùy chỉnh này (Custom Fork Enhancements)

Phiên bản này giữ nguyên triết lý gọn nhẹ của Maccy gốc, đồng thời bổ sung các cải tiến chuyên sâu cho nhu cầu làm việc thực tế trên nhiều máy Mac:

### 1. ⚡ Chống treo tuyệt đối khi copy hoặc lưu nội dung dài (Large Content Anti-Freeze)
- **Giữ nguyên 100% dữ liệu gốc khi Paste**, không làm mất bất kỳ ký tự nào kể cả với log/code/JSON hàng chục MB.
- Giới hạn giải mã UTF-8 tối đa **4 KB** cho tiêu đề (`title`) và **32 KB** cho khung xem trước (`preview`), khắc phục triệt để lỗi duyệt chuỗi đa dòng gây treo Main Thread.
- **Lazy Preview**: Chỉ khởi tạo nội dung xem trước khi người dùng thực sự chọn mục đó thay vì nạp đồng loạt toàn bộ lịch sử lúc khởi động.
- **So khớp trùng lặp $O(1)$ bằng SHA-256**: Tính chữ ký băm nhanh trên kích thước + mẫu dữ liệu thay vì so sánh từng byte trên các khối dữ liệu lớn.
- Tự động loại bỏ khối định dạng HTML/RTF dư thừa nặng trên **5 MB** khi đã có Plain Text đi kèm, cùng tùy chọn giới hạn dung lượng mỗi mục trong `Preferences -> Storage`.

### 2. ☁️ Đồng bộ chọn lọc hai chiều qua Google Drive (`CloudSyncManager`)
- Tự động nhận diện thư mục **Google Drive for Desktop** (`~/Library/CloudStorage/GoogleDrive-.../My Drive/MaccySync`) hoặc chọn thư mục bất kỳ — không cần cấu hình OAuth/API phức tạp.
- **3 chế độ chọn nội dung đồng bộ**:
  1. Đánh dấu/bỏ đánh dấu từng mục bằng phím **`⌥S`**, nút biểu tượng đám mây trên thanh công cụ, hoặc menu chuột phải.
  2. Tự động đồng bộ tất cả các mục được **Ghim (`⌥P`)**.
  3. Chọn nhiều mục cùng lúc (**`⌘ + Click`** hoặc **`⇧ + ↑/↓`**) rồi nhấn **`⌥S`** để đồng bộ hàng loạt.
- Nhấn **`⌥⌘S`** (hoặc bấm biểu tượng đám mây trên thanh tìm kiếm) để lọc chỉ xem các mục đã đồng bộ.
- **Bảo mật & Hiệu năng đám mây**:
  - Tùy chọn **Mã hóa đầu-cuối AES-256-GCM** bằng mật khẩu riêng trong `Preferences -> Google Drive`.
  - Tự động **nén LZFSE** (giảm 70–85% dung lượng văn bản) và tách các dữ liệu lớn ($> 64\text{ KB}$) ra thư mục `blobs/` giúp tránh xung đột file khi nhiều máy Mac cùng đồng bộ.
  - Cảnh báo thông minh khi bấm đồng bộ nhầm nội dung chứa **Private Key / API Token** (`sk-...`, `ghp_...`, `AKIA...`, `AIza...`) mà chưa bật mã hóa.
  - Hiển thị tên máy Mac nguồn và thời gian đồng bộ ngay trong khung xem trước (`Preview`).

### 3. 🇻🇳 Tra cứu Tiếng Việt không dấu & Tìm kiếm sâu (Full-Text Search)
- Hỗ trợ tìm kiếm **tiếng Việt không dấu** (bao gồm `đ/Đ` $\leftrightarrow$ `d` và bỏ dấu thanh/mũ) trên mọi chế độ (`Exact`, `Fuzzy`, `Regex`, `Mixed`) và tô sáng chính xác cụm từ có dấu trên giao diện.
- Tự động mở rộng phạm vi tìm kiếm vào tới **64 KB nội dung bên trong** đối với các đoạn văn bản dài hơn tiêu đề hiển thị.

### 4. ⌨️ Phím tắt mặc định tối ưu
- **`Command + Shift + V` (`⌘⇧V`)**: Mở nhanh danh sách lịch sử Clipboard.
- **`Command + Shift + C` (`⌘⇧C`)**: **Dán ngay Plain Text** (văn bản thuần không định dạng) của nội dung copy gần nhất vào ứng dụng đang làm việc (vẫn giữ nguyên bản có định dạng trong lịch sử Maccy).
- **`Option + S` (`⌥S`)**: Đồng bộ / Hủy đồng bộ mục đang chọn lên Google Drive.
- **`Option + Command + S` (`⌥⌘S`)**: Bật/tắt bộ lọc chỉ hiện mục đã đồng bộ.

### 5. 🛠️ Hướng dẫn tự biên dịch nhanh (`build_maccy.sh`)
Hỗ trợ biên dịch trực tiếp bằng Swift Package Manager / CommandLineTools mà không bắt buộc cài đặt toàn bộ Xcode:
```sh
chmod +x build_maccy.sh
./build_maccy.sh
open /Applications/Maccy.app
```

---

> [!WARNING]
> **Beware of fake websites impersonating Maccy.** Malicious sites (such as `maccyapp.net` and `maccyapp.com`) distribute malware disguised as Maccy. [**maccy.app**](https://maccy.app) is the **only** official website.

<img width="128px" src="https://maccy.app/img/maccy/Logo.png" alt="Logo" />

# [Maccy](https://maccy.app)

[![Downloads](https://img.shields.io/github/downloads/p0deje/Maccy/total.svg)](https://github.com/p0deje/Maccy/releases/latest)
[![Build Status](https://img.shields.io/bitrise/716921b669780314/master?token=3pMiCb5dpFzlO-7jTYtO3Q)](https://app.bitrise.io/app/716921b669780314)

Maccy is a lightweight clipboard manager for macOS. It keeps the history of what you copy
and lets you quickly navigate, search, and use previous clipboard contents.

Maccy works on macOS Sonoma 14 or higher.

<!-- vim-markdown-toc GFM -->

* [Features](#features)
* [Install](#install)
* [Usage](#usage)
* [Advanced](#advanced)
  * [Ignore Copied Items](#ignore-copied-items)
  * [Ignore Custom Copy Types](#ignore-custom-copy-types)
  * [Speed up Clipboard Check Interval](#speed-up-clipboard-check-interval)
* [FAQ](#faq)
  * [Why doesn't it paste when I select an item in history?](#why-doesnt-it-paste-when-i-select-an-item-in-history)
  * [When assigning a hotkey to open Maccy, it says that this hotkey is already used in some system setting.](#when-assigning-a-hotkey-to-open-maccy-it-says-that-this-hotkey-is-already-used-in-some-system-setting)
  * [How to restore hidden footer?](#how-to-restore-hidden-footer)
  * [How to ignore copies from Universal Clipboard?](#how-to-ignore-copies-from-universal-clipboard)
  * [My keyboard shortcut stopped working in password fields. How do I fix this?](#my-keyboard-shortcut-stopped-working-in-password-fields-how-do-i-fix-this)
* [Translations](#translations)
* [Motivation](#motivation)
* [License](#license)

<!-- vim-markdown-toc -->

## Features

* Lightweight and fast
* Keyboard-first
* Secure and private
* Native UI
* Open source and free

## Install

Download the latest version from the [releases](https://github.com/p0deje/Maccy/releases/latest) page, or use [Homebrew](https://brew.sh/):

```sh
brew install maccy
```

## Usage

1. <kbd>SHIFT (⇧)</kbd> + <kbd>COMMAND (⌘)</kbd> + <kbd>C</kbd> to popup Maccy or click on its icon in the menu bar.
2. Type what you want to find.
3. To select the history item you wish to copy, press <kbd>ENTER</kbd>, or click the item, or use <kbd>COMMAND (⌘)</kbd> + `n` shortcut.
4. To choose the history item and paste, press <kbd>OPTION (⌥)</kbd> + <kbd>ENTER</kbd>, or <kbd>OPTION (⌥)</kbd> + <kbd>CLICK</kbd> the item, or use <kbd>OPTION (⌥)</kbd> + `n` shortcut.
5. To choose the history item and paste without formatting, press <kbd>OPTION (⌥)</kbd> + <kbd>SHIFT (⇧)</kbd> + <kbd>ENTER</kbd>, or <kbd>OPTION (⌥)</kbd> + <kbd>SHIFT (⇧)</kbd> + <kbd>CLICK</kbd> the item, or use <kbd>OPTION (⌥)</kbd> + <kbd>SHIFT (⇧)</kbd> + `n` shortcut.
6. To delete the history item, press <kbd>OPTION (⌥)</kbd> + <kbd>DELETE (⌫)</kbd>.
7. To see the full text of the history item, wait a couple of seconds for tooltip.
8. To pin the history item so that it remains on top of the list, press <kbd>OPTION (⌥)</kbd> + <kbd>P</kbd>. The item will be moved to the top with a random but permanent keyboard shortcut. To unpin it, press <kbd>OPTION (⌥)</kbd> + <kbd>P</kbd> again.
9. To clear all unpinned items, select _Clear_ in the menu, or press <kbd>OPTION (⌥)</kbd> + <kbd>COMMAND (⌘)</kbd> + <kbd>DELETE (⌫)</kbd>. To clear all items including pinned, select _Clear_ in the menu with  <kbd>OPTION (⌥)</kbd> pressed, or press <kbd>SHIFT (⇧)</kbd> + <kbd>OPTION (⌥)</kbd> + <kbd>COMMAND (⌘)</kbd> + <kbd>DELETE (⌫)</kbd>.
10. To disable Maccy and ignore new copies, click on the menu icon with <kbd>OPTION (⌥)</kbd> pressed.
11. To ignore only the next copy, click on the menu icon with <kbd>OPTION (⌥)</kbd> + <kbd>SHIFT (⇧)</kbd> pressed.
12. To customize the behavior, check "Preferences…" window, or press <kbd>COMMAND (⌘)</kbd> + <kbd>,</kbd>.

## Advanced

### Ignore Copied Items

You can tell Maccy to ignore all copied items:

```sh
defaults write org.p0deje.Maccy ignoreEvents true # default is false
```

This is useful if you have some workflow for copying sensitive data. You can set `ignoreEvents` to true, copy the data and set `ignoreEvents` back to false.

You can also click the menu icon with <kbd>OPTION (⌥)</kbd> pressed. To ignore only the next copy, click with <kbd>OPTION (⌥)</kbd> + <kbd>SHIFT (⇧)</kbd> pressed.

### Ignore Custom Copy Types

By default Maccy will ignore certain copy types that are considered to be confidential
or temporary. The default list always include the following types:

* `org.nspasteboard.TransientType`
* `org.nspasteboard.ConcealedType`
* `org.nspasteboard.AutoGeneratedType`

Also, default configuration includes the following types but they can be removed
or overwritten:

* `com.agilebits.onepassword`
* `com.typeit4me.clipping`
* `de.petermaurer.TransientPasteboardType`
* `Pasteboard generator type`
* `net.antelle.keeweb`

You can add additional custom types using settings.
To find what custom types are used by an application, you can use
free application [Pasteboard-Viewer](https://github.com/sindresorhus/Pasteboard-Viewer).
Simply download the application, open it, copy something from the application you
want to ignore and look for any custom types in the left sidebar. [Here is an example
of using this approach to ignore Adobe InDesign](https://github.com/p0deje/Maccy/issues/125).

### Speed up Clipboard Check Interval

By default, Maccy checks clipboard every 500 ms, which should be enough for most users. If you want
to speed it up, you can change it with `defaults`:

```sh
defaults write org.p0deje.Maccy clipboardCheckInterval 0.1 # 100 ms
```

## FAQ

### Why doesn't it paste when I select an item in history?

1. Make sure you have "Paste automatically" enabled in Preferences.
2. Make sure "Maccy" is added to System Settings -> Privacy & Security -> Accessibility.

### When assigning a hotkey to open Maccy, it says that this hotkey is already used in some system setting.

1. Open System settings -> Keyboard -> Keyboard Shortcuts.
2. Find where that hotkey is used. For example, "Convert text to simplified Chinese" is under Services -> Text.
3. Disable that hotkey or remove assigned combination ([screenshot](https://github.com/p0deje/Maccy/assets/576152/446719e6-c3e5-4eb0-95fb-5a811066487f)).
4. Restart Maccy.
5. Assign hotkey in Maccy settings.

### How to restore hidden footer?

1. Open Maccy window.
2. Press <kbd>COMMAND (⌘)</kbd> + <kbd>,</kbd> to open preferences.
3. Enable footer in Appearance section.

If for some reason it doesn't work, run the following command in Terminal.app:

```sh
defaults write org.p0deje.Maccy showFooter 1
```

### How to ignore copies from [Universal Clipboard](https://support.apple.com/en-us/102430)?

1. Open Preferences -> Ignore -> Pasteboard Types.
2. Add `com.apple.is-remote-clipboard`.

### My keyboard shortcut stopped working in password fields. How do I fix this?

If your shortcut produces a character (like `Option+C` → "ç"), macOS security may block it in password fields. Use [Karabiner-Elements](https://karabiner-elements.pqrs.org/) to remap your shortcut to a different combination like `Cmd+Shift+C`. [See detailed solution](docs/keyboard-shortcut-password-fields.md).

## Translations

The translations are hosted in [Weblate](https://hosted.weblate.org/engage/maccy/).
You can use it to suggest changes in translations and localize the application to a new language.

[![Translation status](https://hosted.weblate.org/widget/maccy/multi-auto.svg)](https://hosted.weblate.org/engage/maccy/)

## Motivation

There are dozens of similar applications out there, so why build another?
Over the past years since I moved from Linux to macOS, I struggled to find
a clipboard manager that is as free and simple as [Parcellite](http://parcellite.sourceforge.net),
but I couldn't. So I've decided to build one.

Also, I wanted to learn Swift and get acquainted with macOS application development.

## License & Credits

* Original project **[Maccy](https://github.com/p0deje/Maccy)** — Copyright (c) 2025 **Alex Rodionov ([@p0deje](https://github.com/p0deje))**, licensed under the [MIT License](./LICENSE).
* Custom fork modifications — Copyright (c) 2026 **Hung Le Xuan (`hungmtuci@gmail.com`)**, licensed under the [MIT License](./LICENSE).
* Full attribution and third-party open-source credits: [NOTICE.md](./NOTICE.md).
