import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator
  var previous: HistoryItemDecorator?
  var next: HistoryItemDecorator?
  var index: Int

  private var selectionAppearance: SelectionAppearance {
    let previousSelected = previous?.isSelected ?? false
    let nextSelected = next?.isSelected ?? false
    switch (previousSelected, nextSelected) {
    case (true, false):
      return .topConnection
    case (false, true):
      return .bottomConnection
    case (true, true):
      return .topBottomConnection
    default:
      return .none
    }
  }

  @Default(.showHexColorSwatch) private var showHexColorSwatch
  @Environment(AppState.self) private var appState

  private var colorSwatchImage: NSImage? {
    guard showHexColorSwatch, item.title.count <= 32 else { return nil }
    return ColorImage.from(item.title)
  }

  private func performSelect() {
    if NSEvent.modifierFlags.contains(.command) && appState.multiSelectionEnabled {
      appState.navigator.addToSelection(item: item)
    } else {
      let flags = NSEvent.ModifierFlags.currentModifierFlags
      Task {
        appState.history.select(item, flags: flags)
      }
    }
  }

  private static let vietnameseLocale = Locale(identifier: "vi_VN")

  private var detectedURL: URL? {
    guard !item.hasImage, !item.hasFileURLs else { return nil }
    return Clipboard.extractURL(from: item.item)
  }

  private var canTransformText: Bool {
    !item.hasImage && !item.hasFileURLs && (item.hasPlainText || item.hasRichText || !item.title.isEmpty)
  }

  private var looksLikeJSON: Bool {
    guard canTransformText, item.item.totalByteCount <= 2_097_152 else { return false }
    let prefix = item.item.previewableTextPrefix(maxBytes: 256).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return prefix.hasPrefix("{") || prefix.hasPrefix("[")
  }

  private func resolveEditableSourceText() -> String? {
    guard !item.hasImage, !item.hasFileURLs else { return nil }
    if let fullText = item.item.text, !fullText.isEmpty {
      return fullText
    }
    let preview = item.previewText.string
    return preview.isEmpty ? nil : preview
  }

  private func formatJSON(prettyPrinted: Bool) -> String? {
    guard let raw = resolveEditableSourceText()?.trimmingCharacters(in: .whitespacesAndNewlines),
          raw.utf8.count <= 2_097_152,
          (raw.hasPrefix("{") || raw.hasPrefix("[")),
          let data = raw.data(using: .utf8),
          let jsonObj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
      return nil
    }
    let options: JSONSerialization.WritingOptions = prettyPrinted
      ? [.prettyPrinted, .sortedKeys]
      : [.sortedKeys]
    guard let outData = try? JSONSerialization.data(withJSONObject: jsonObj, options: options) else {
      return nil
    }
    return String(data: outData, encoding: .utf8)
  }

  private func copyTransformedText(_ transformed: String, pasteImmediately: Bool = false) {
    guard !transformed.isEmpty else { return }
    appState.popup.close()
    Clipboard.shared.copyInMaccy(transformed)
    if pasteImmediately {
      Clipboard.shared.paste()
    }
  }

  var body: some View {
    ListItemView(
      id: item.id,
      selectionId: item.id,
      appIcon: item.applicationImage,
      image: item.thumbnailImage,
      accessoryImage: item.thumbnailImage != nil ? nil : colorSwatchImage,
      attributedTitle: item.attributedTitle,
      matchedSnippet: item.matchedSnippet,
      shortcuts: item.shortcuts,
      isSelected: item.isSelected,
      isSynced: item.isSynced,
      onToggleSync: {
        CloudSyncManager.shared.toggleSync(for: [item])
      },
      selectionIndex: item.multiSelectionIndex,
      selectionAppearance: selectionAppearance,
      accessibilityLabel: item.accessibilityLabel
    ) {
      Text(verbatim: item.title)
    }
    .accessibilityIdentifier("copy-history-item")
    .buttonAction(performSelect)
    .contextMenu {
      Button {
        appState.history.select(item, flags: [])
      } label: {
        Label("Dán / Sao chép", systemImage: "doc.on.doc")
      }

      if !item.hasImage {
        Button {
          appState.popup.close()
          Clipboard.shared.copy(item.item, removeFormatting: true)
          Clipboard.shared.paste()
        } label: {
          Label("Dán văn bản thuần (Plain Text)", systemImage: "doc.plaintext")
        }
      } else if !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Button {
          copyTransformedText(item.title, pasteImmediately: false)
        } label: {
          Label("Sao chép chữ trong ảnh (OCR)", systemImage: "text.viewfinder")
        }
      }

      if let url = detectedURL {
        Button {
          copyTransformedText(url.absoluteString)
        } label: {
          Label("Sao chép liên kết thuần", systemImage: "link")
        }

        let stripped = Clipboard.stripTrackingParameters(from: url)
        if stripped.absoluteString != url.absoluteString {
          Button {
            copyTransformedText(stripped.absoluteString)
          } label: {
            Label("Sao chép liên kết sạch (xoá UTM/fbclid)", systemImage: "sparkles")
          }
        }
      }

      Divider()

      Button {
        appState.history.togglePin(item)
      } label: {
        Label(
          item.isPinned ? "Bỏ ghim" : "Ghim cố định",
          systemImage: item.isPinned ? "pin.slash" : "pin"
        )
      }

      Button {
        if item.isSelected && appState.navigator.selection.count > 1 {
          appState.toggleSync()
        } else {
          CloudSyncManager.shared.toggleSync(for: [item])
        }
      } label: {
        Label(
          item.isSynced ? "Bỏ đồng bộ Google Drive" : "Đồng bộ lên Google Drive",
          systemImage: item.isSynced ? "icloud.slash" : "icloud.and.arrow.up"
        )
      }

      if item.hasPlainText || item.hasRichText || item.hasImage {
        Button {
          appState.popup.close()
          SnippetManagerWindowController.shared.showAndCreateFromClipboardItem(item.item)
        } label: {
          Label("Lưu thành Gõ tắt…", systemImage: "bolt.horizontal.circle")
        }

        Button {
          appState.navigator.select(item: item)
          appState.beginEditing(item)
        } label: {
          Label("Đặt tên gợi nhớ & Chỉnh sửa…", systemImage: "pencil")
        }
      }

      if canTransformText {
        Divider()
        Menu {
          Button("Xoá khoảng trắng & dòng trống thừa") {
            guard let sourceText = resolveEditableSourceText() else { return }
            let cleaned = sourceText
              .components(separatedBy: .newlines)
              .map { $0.trimmingCharacters(in: .whitespaces) }
              .joined(separator: "\n")
              .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            copyTransformedText(cleaned)
          }

          Button("Gộp thành 1 dòng duy nhất") {
            guard let sourceText = resolveEditableSourceText() else { return }
            let singleLine = sourceText
              .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            copyTransformedText(singleLine)
          }

          if looksLikeJSON {
            Divider()
            Button("Định dạng JSON đẹp (Pretty Print)") {
              if let pretty = formatJSON(prettyPrinted: true) {
                copyTransformedText(pretty)
              }
            }
            Button("Nén gọn JSON (Minify)") {
              if let minified = formatJSON(prettyPrinted: false) {
                copyTransformedText(minified)
              }
            }
          }

          Divider()

          Button("CHỮ IN HOA") {
            guard let sourceText = resolveEditableSourceText() else { return }
            copyTransformedText(sourceText.uppercased(with: Self.vietnameseLocale))
          }

          Button("chữ thường") {
            guard let sourceText = resolveEditableSourceText() else { return }
            copyTransformedText(sourceText.lowercased(with: Self.vietnameseLocale))
          }

          Button("Viết Hoa Đầu Từ") {
            guard let sourceText = resolveEditableSourceText() else { return }
            copyTransformedText(sourceText.capitalized(with: Self.vietnameseLocale))
          }

          Button("Bỏ dấu Tiếng Việt") {
            guard let sourceText = resolveEditableSourceText() else { return }
            copyTransformedText(sourceText.removingVietnameseDiacriticsPreservingCase)
          }
        } label: {
          Label("Biến đổi văn bản", systemImage: "wand.and.stars")
        }
      }

      Divider()

      Button(role: .destructive) {
        appState.history.delete(item)
      } label: {
        Label("Xoá mục này", systemImage: "trash")
      }
    }
    .onAppear {
      item.ensureThumbnailImage()
    }
    .accessibilityAction(named: Text(item.isPinned ? "history_item_unpin_action" : "history_item_pin_action")) {
      appState.history.togglePin(item)
    }
    .accessibilityAction(named: Text("history_item_delete_action")) {
      appState.history.delete(item)
    }
  }
}
