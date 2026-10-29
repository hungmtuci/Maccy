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

  private var detectedURL: URL? {
    guard !item.hasImage, !item.hasFileURLs else { return nil }
    return Clipboard.extractURL(from: item.item)
  }

  private var editableSourceText: String? {
    guard !item.hasImage, !item.hasFileURLs else { return nil }
    if let fullText = item.item.text, !fullText.isEmpty {
      return fullText
    }
    let preview = item.previewText.string
    return preview.isEmpty ? nil : preview
  }

  private var formattedJSONCandidate: (pretty: String, minified: String)? {
    guard let raw = editableSourceText?.trimmingCharacters(in: .whitespacesAndNewlines),
          raw.count <= 2_097_152,
          (raw.hasPrefix("{") || raw.hasPrefix("[")),
          let data = raw.data(using: .utf8),
          let jsonObj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          let prettyData = try? JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys]),
          let minifiedData = try? JSONSerialization.data(withJSONObject: jsonObj, options: [.sortedKeys]),
          let pretty = String(data: prettyData, encoding: .utf8),
          let minified = String(data: minifiedData, encoding: .utf8) else {
      return nil
    }
    return (pretty, minified)
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

      if let sourceText = editableSourceText {
        Divider()
        Menu {
          Button("Xoá khoảng trắng & dòng trống thừa") {
            let cleaned = sourceText
              .components(separatedBy: .newlines)
              .map { $0.trimmingCharacters(in: .whitespaces) }
              .joined(separator: "\n")
              .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            copyTransformedText(cleaned)
          }

          Button("Gộp thành 1 dòng duy nhất") {
            let singleLine = sourceText
              .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            copyTransformedText(singleLine)
          }

          if let json = formattedJSONCandidate {
            Divider()
            Button("Định dạng JSON đẹp (Pretty Print)") {
              copyTransformedText(json.pretty)
            }
            Button("Nén gọn JSON (Minify)") {
              copyTransformedText(json.minified)
            }
          }

          Divider()

          Button("CHỮ IN HOA") {
            copyTransformedText(sourceText.uppercased(with: Locale(identifier: "vi_VN")))
          }

          Button("chữ thường") {
            copyTransformedText(sourceText.lowercased(with: Locale(identifier: "vi_VN")))
          }

          Button("Viết Hoa Đầu Từ") {
            copyTransformedText(sourceText.capitalized(with: Locale(identifier: "vi_VN")))
          }

          Button("Bỏ dấu Tiếng Việt") {
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
