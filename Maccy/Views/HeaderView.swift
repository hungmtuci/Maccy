import Defaults
import SwiftUI

struct HeaderView: View {
  @State private var appState = AppState.shared

  let controller: SlideoutController
  @FocusState.Binding var searchFocused: Bool

  var previewPlacement: SlideoutPlacement {
    return controller.placement
  }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      HStack(alignment: .center, spacing: 4) {
        ListHeaderView(
          searchFocused: $searchFocused,
          searchQuery: $appState.history.searchQuery
        )
        .padding(.leading, Popup.horizontalPadding)

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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(appState.cloudSync.filterOnlySynced ? Color.accentColor : Color.secondary)
            }
          }
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(appState.cloudSync.filterOnlySynced ? Color.accentColor.opacity(0.15) : Color.clear)
          )
        }
        .help("Lọc các mục đồng bộ Google Drive (⌥⌘S). Nhấn ⌥S để đánh dấu đồng bộ mục đang chọn.")

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
}
