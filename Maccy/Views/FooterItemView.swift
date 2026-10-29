import SwiftUI

struct FooterItemView: View {
  @Bindable var item: FooterItem
  @Environment(AppState.self) private var appState

  var body: some View {
    VStack(spacing: 0) {
      if item.hasTopDivider && item.isVisible {
        Divider()
          .padding(.horizontal, Popup.horizontalSeparatorPadding)
          .padding(.vertical, 3)
      }

      ConfirmationView(item: item) {
        ListItemView(
          id: item.id,
          selectionId: item.id,
          shortcuts: item.shortcuts,
          isSelected: item.isSelected,
          accessibilityLabel: NSLocalizedString(item.title, comment: "")
        ) {
          HStack(spacing: 7) {
            if let iconName = item.icon {
              Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.isSelected ? Color.white : Color.secondary)
                .frame(width: 15, alignment: .center)
            }
            Text(LocalizedStringKey(item.title))
          }
        }
      }
      .onHover { hovering in
        if hovering && appState.preview.state.isOpen {
          appState.preview.togglePreview()
        }
      }
    }
  }
}
