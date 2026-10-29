import Defaults
import SwiftUI

struct HeaderView: View {
  @State private var appState = AppState.shared
  @State private var snippetStore = SnippetStore.shared

  let controller: SlideoutController
  @FocusState.Binding var searchFocused: Bool

  var previewPlacement: SlideoutPlacement {
    return controller.placement
  }

  private var activeSearchBinding: Binding<String> {
    appState.popupMode == .snippets
      ? $snippetStore.popupSearchQuery
      : $appState.history.searchQuery
  }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      HStack(alignment: .center, spacing: 5) {
        ListHeaderView(
          searchFocused: $searchFocused,
          searchQuery: activeSearchBinding
        )
        .padding(.leading, Popup.horizontalPadding)

        // Native macOS segmented pill for Clipboard vs Snippets
        HStack(spacing: 2) {
          modeSegmentButton(
            icon: "list.clipboard",
            isSelected: appState.popupMode == .clipboard,
            helpText: "Lịch sử Clipboard (⇧⌘V)"
          ) {
            if appState.popupMode != .clipboard {
              appState.togglePopupMode()
            }
          }

          modeSegmentButton(
            icon: "bolt.horizontal",
            isSelected: appState.popupMode == .snippets,
            helpText: "Danh sách Gõ tắt (⇧⌘S / ⌃Tab)"
          ) {
            if appState.popupMode != .snippets {
              appState.togglePopupMode()
            }
          }
        }
        .padding(2)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.07))
        )

        if appState.popupMode == .clipboard {
          ToolbarButton {
            appState.toggleSyncFilter()
          } label: {
            HStack(spacing: 2) {
              Image(
                systemName: appState.cloudSync.filterOnlySynced
                  ? "icloud.fill" : "icloud"
              )
              .foregroundStyle(appState.cloudSync.filterOnlySynced ? Color.accentColor : Color.primary)
              if appState.cloudSync.syncedCount > 0 {
                Text("\(appState.cloudSync.syncedCount)")
                  .font(.system(size: 10, weight: .semibold, design: .rounded))
                  .foregroundStyle(appState.cloudSync.filterOnlySynced ? Color.accentColor : Color.secondary)
              }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(appState.cloudSync.filterOnlySynced ? Color.accentColor.opacity(0.16) : Color.clear)
            )
          }
          .help("Lọc các mục đồng bộ Google Drive (⌥⌘S)")
        }

        ToolbarButton {
          controller.togglePreview()
        } label: {
          Image(
            systemName: previewPlacement == .right
              ? "sidebar.left" : "sidebar.right"
          )
        }
        .shortcutKeyHelp(
          name: .togglePreview,
          key: controller.state.isOpen ? "ClosePreview" : "OpenPreview",
          tableName: "PreviewItemView",
          replacementKey: "previewKey"
        )
        .padding(.trailing, Popup.horizontalPadding)
      }
      .opacity(appState.searchVisible ? 1 : 0)
      .accessibilityHidden(!appState.searchVisible)
      .layoutPriority(1)
    }
    .padding(.top, Popup.verticalPadding)
    .padding(.horizontal, 10)
    .animation(.default.speed(3), value: appState.navigator.leadSelection)
    .background(.clear)
    .frame(maxHeight: !appState.searchVisible ? 0 : nil, alignment: .top)
    .readHeight(appState, into: \.popup.headerHeight)
  }

  private func modeSegmentButton(
    icon: String,
    isSelected: Bool,
    helpText: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: isSelected ? "\(icon).fill" : icon)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .frame(width: 22, height: 19)
        .background(
          RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            .shadow(color: isSelected ? Color.black.opacity(0.12) : .clear, radius: 1, y: 0.5)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(helpText)
  }
}
