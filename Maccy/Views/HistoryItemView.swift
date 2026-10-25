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

  var body: some View {
    ListItemView(
      id: item.id,
      selectionId: item.id,
      appIcon: item.applicationImage,
      image: item.thumbnailImage,
      accessoryImage: item.thumbnailImage != nil ? nil : colorSwatchImage,
      attributedTitle: item.attributedTitle,
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
        if item.isSelected && appState.navigator.selection.count > 1 {
          appState.toggleSync()
        } else {
          CloudSyncManager.shared.toggleSync(for: [item])
        }
      } label: {
        Label(
          item.isSynced ? "Bỏ đồng bộ Google Drive (⌥S)" : "Đồng bộ lên Google Drive (⌥S)",
          systemImage: item.isSynced ? "icloud.slash" : "icloud.and.arrow.up"
        )
      }

      Button {
        appState.history.togglePin(item)
      } label: {
        Label(
          item.isPinned ? "Bỏ ghim (⌥P)" : "Ghim (⌥P)",
          systemImage: item.isPinned ? "pin.slash" : "pin"
        )
      }

      Divider()

      Button {
        appState.history.select(item, flags: [])
      } label: {
        Label("Sao chép / Dán", systemImage: "doc.on.doc")
      }

      Button(role: .destructive) {
        appState.history.delete(item)
      } label: {
        Label("Xóa (⌥⌫)", systemImage: "trash")
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
