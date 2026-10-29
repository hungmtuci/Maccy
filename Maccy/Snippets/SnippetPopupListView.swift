import AppKit
import Defaults
import SwiftUI

struct SnippetPopupListView: View {
  @FocusState.Binding var searchFocused: Bool

  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase
  @State private var store = SnippetStore.shared
  @State private var engine = TextExpansionEngine.shared
  @Default(.textExpansionEnabled) private var textExpansionEnabled

  var body: some View {
    let filtered = store.filteredPopupItems

    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        collectionFilterBar
        if textExpansionEnabled && !engine.isEventTapActive {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .font(.system(size: 11))
            Text("Gõ tắt tự động thiếu quyền Bàn phím")
              .font(.system(size: 11, weight: .semibold))
            Spacer()
            Button("Cấp quyền ngay") {
              appState.popup.close()
              engine.requestOrRepairAccessibilityPermission(resetStaleTCC: true)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.mini)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
          .padding(.horizontal, 6)
        }
      }
      .padding(.top, 4)
      .padding(.bottom, 4)
      .readHeight(appState, into: \.popup.extraTopHeight)

      Divider()
        .padding(.horizontal, Popup.horizontalSeparatorPadding)

      if filtered.isEmpty {
        emptySnippetsView
          .frame(maxWidth: .infinity)
          .padding(.vertical, 16)
          .background {
            GeometryReader { geo in
              Color.clear
                .task(id: appState.popup.needsResize) {
                  try? await Task.sleep(for: .milliseconds(10))
                  if appState.popup.needsResize {
                    appState.popup.resize(height: max(geo.size.height, 190))
                  }
                }
            }
          }
      } else {
        ScrollView {
          ScrollViewReader { proxy in
            LazyVStack(alignment: .leading, spacing: 1) {
              ForEach(Array(filtered.enumerated()), id: \.element.id) { index, snippet in
                SnippetPopupRowView(
                  item: snippet,
                  collection: store.collection(for: snippet.collectionId),
                  index: index,
                  isSelected: store.selectedPopupItemId == snippet.id,
                  searchQuery: store.popupSearchQuery,
                  onSelect: {
                    appState.triggerSnippetFromPopup(snippet)
                  },
                  onHoverSelect: {
                    if !appState.navigator.isKeyboardNavigating {
                      store.selectedPopupItemId = snippet.id
                    }
                  }
                )
                .id(snippet.id)
              }
            }
            .padding(.vertical, Popup.verticalSeparatorPadding)
            .background {
              GeometryReader { geo in
                Color.clear
                  .task(id: filtered.count) {
                    try? await Task.sleep(for: .milliseconds(15))
                    appState.popup.resize(height: geo.size.height)
                  }
                  .task(id: appState.popup.needsResize) {
                    try? await Task.sleep(for: .milliseconds(10))
                    if appState.popup.needsResize {
                      appState.popup.resize(height: geo.size.height)
                    }
                  }
              }
            }
            .onChange(of: store.selectedPopupItemId) { _, newId in
              if let newId {
                withAnimation(.easeOut(duration: 0.1)) {
                  proxy.scrollTo(newId, anchor: .center)
                }
              }
            }
          }
        }
      }
    }
    .onAppear {
      store.ensureValidPopupSelection()
      appState.popup.needsResize = true
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active {
        searchFocused = true
        store.ensureValidPopupSelection()
      }
    }
  }

  private var collectionFilterBar: some View {
    HStack(spacing: 6) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          collectionPill(title: "Tất cả", count: store.items.count, isSelected: store.selectedPopupCollectionId == nil) {
            store.selectedPopupCollectionId = nil
          }

          ForEach(store.collections) { col in
            let count = store.itemCount(in: col.id)
            if count > 0 {
              collectionPill(
                title: col.name,
                count: count,
                isSelected: store.selectedPopupCollectionId == col.id
              ) {
                store.selectedPopupCollectionId = (store.selectedPopupCollectionId == col.id) ? nil : col.id
              }
            }
          }
        }
        .padding(.horizontal, 6)
      }

      Button {
        appState.popup.close()
        SnippetManagerWindowController.shared.show(selecting: store.selectedPopupItemId)
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "slider.horizontal.3")
          Text("Quản lý")
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .help("Mở Trình quản lý Gõ tắt (Snippet Studio)")
      .padding(.trailing, 6)
    }
  }

  private func collectionPill(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 3) {
        Text(title)
          .lineLimit(1)
        Text("\(count)")
          .font(.system(size: 9.5, weight: .semibold))
          .opacity(0.75)
      }
      .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
      .foregroundStyle(isSelected ? Color.white : Color.primary)
      .padding(.horizontal, 7)
      .padding(.vertical, 2.5)
      .background(
        Capsule()
          .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
      )
    }
    .buttonStyle(.plain)
  }

  private var emptySnippetsView: some View {
    VStack(spacing: 10) {
      Image(systemName: "text.badge.plus")
        .font(.system(size: 24))
        .foregroundStyle(.secondary)

      if !store.popupSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text("Không tìm thấy gõ tắt khớp \"\(store.popupSearchQuery)\"")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(.secondary)
      } else {
        Text("Chưa có mục Gõ tắt nào trong danh sách này")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(.secondary)

        HStack(spacing: 8) {
          if SnippetImporter.isTypinatorInstalled {
            Button("⚡ Nhập từ Typinator") {
              appState.popup.close()
              SnippetManagerWindowController.shared.showAndImportTypinator()
            }
            .controlSize(.small)
          }
          if SnippetImporter.isAlfredInstalled {
            Button("🎩 Nhập từ Alfred") {
              if let payload = try? SnippetImporter.loadFromInstalledAlfred() {
                _ = store.importPayload(payload)
                appState.popup.needsResize = true
              }
            }
            .controlSize(.small)
          }
          Button("📦 Cài gói mẫu") {
            _ = store.importPayload(SnippetImporter.starterPackPayload(for: .academicSymbols))
            _ = store.importPayload(SnippetImporter.starterPackPayload(for: .dynamicTemplates))
            appState.popup.needsResize = true
          }
          .controlSize(.small)
        }
      }

      Button("Mở Trình quản lý Gõ tắt…") {
        appState.popup.close()
        SnippetManagerWindowController.shared.show()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    }
    .padding(.horizontal, 12)
  }
}

private struct SnippetPopupRowView: View {
  let item: SnippetItem
  let collection: SnippetCollection?
  let index: Int
  let isSelected: Bool
  let searchQuery: String
  let onSelect: () -> Void
  let onHoverSelect: () -> Void

  private var effectiveAbbr: String {
    item.effectiveAbbreviation(in: collection)
  }

  private var singleLineBodyPreview: String {
    item.content
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .shortened(to: 110)
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: item.contentMode.iconName)
        .font(.system(size: 12))
        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(item.displayTitle)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .lineLimit(1)

          if let colName = collection?.name, !colName.isEmpty {
            Text(colName)
              .font(.system(size: 10))
              .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
              .lineLimit(1)
          }
        }

        if !singleLineBodyPreview.isEmpty && singleLineBodyPreview != item.displayTitle {
          Text(singleLineBodyPreview)
            .font(.system(size: 11))
            .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 4)

      if !effectiveAbbr.isEmpty {
        Text(effectiveAbbr)
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(isSelected ? Color.white : Color.accentColor)
          .padding(.horizontal, 6)
          .padding(.vertical, 1.5)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(isSelected ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.14))
          )
      }

      if index < 9 {
        Text("⌘\(index + 1)")
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: Popup.cornerRadius)
        .fill(isSelected ? Color.accentColor : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { hovering in
      if hovering {
        onHoverSelect()
      }
    }
    .onTapGesture {
      onSelect()
    }
    .contextMenu {
      Button {
        onSelect()
      } label: {
        Label("Chèn Gõ tắt ngay (↩)", systemImage: "bolt.fill")
      }

      Button {
        AppState.shared.popup.close()
        Clipboard.shared.copyInMaccy(item.content)
      } label: {
        Label("Sao chép nội dung thô vào Clipboard", systemImage: "doc.on.doc")
      }

      Divider()

      Button {
        AppState.shared.popup.close()
        SnippetManagerWindowController.shared.show(selecting: item.id)
      } label: {
        Label("Chỉnh sửa trong Trình quản lý… (⌘E)", systemImage: "slider.horizontal.3")
      }

      Button {
        _ = SnippetStore.shared.duplicateItem(item.id)
      } label: {
        Label("Nhân bản Gõ tắt", systemImage: "plus.square.on.square")
      }

      Divider()

      Button(role: .destructive) {
        SnippetStore.shared.deleteItem(item.id)
      } label: {
        Label("Xoá Gõ tắt", systemImage: "trash")
      }
    }
  }
}

struct SnippetSlideoutPreviewView: View {
  let item: SnippetItem
  private var collection: SnippetCollection? {
    SnippetStore.shared.collection(for: item.collectionId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 8) {
        Image(systemName: item.contentMode.iconName)
          .foregroundStyle(Color.accentColor)
        Text(item.displayTitle)
          .font(.headline)
          .lineLimit(2)
        Spacer()
        if let abbr = Optional(item.effectiveAbbreviation(in: collection)), !abbr.isEmpty {
          Text(abbr)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.15)))
        }
      }

      Divider()

      if item.contentMode == .image,
         let data = item.imagePNGData,
         let nsImage = NSImage(data: data) {
        Image(nsImage: nsImage)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 260)
          .clipShape(RoundedRectangle(cornerRadius: 6))
      } else {
        ScrollView {
          Text(item.content)
            .font(.system(size: 12.5, design: item.contentMode == .plainText ? .default : .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      Divider()

      HStack(spacing: 12) {
        if let col = collection {
          Label(col.name, systemImage: col.icon)
        }
        Label(item.triggerMode.title, systemImage: item.triggerMode.badgeSymbol)
        Spacer()
        Text("Đã dùng \(item.usageCount) lần")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
