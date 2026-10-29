import Defaults
import SwiftUI

@Observable
class Footer: ItemsContainer {
  var items: [FooterItem] = []

  var selectedItem: FooterItem? {
    willSet {
      selectedItem?.isSelected = false
      newValue?.isSelected = true
    }
  }

  var suppressClearAlert = Binding<Bool>(
    get: { Defaults[.suppressClearAlert] },
    set: { Defaults[.suppressClearAlert] = $0 }
  )

  private var showFooter: Bool {
    return Defaults[.showFooter]
  }
  var containerVisible: Bool {
    return showFooter
  }

  init() { // swiftlint:disable:this function_body_length
    items = [
      FooterItem(
        title: "clear",
        icon: "trash",
        shortcuts: [KeyShortcut(key: .delete, modifierFlags: [.command, .option])],
        help: "clear_tooltip",
        confirmation: .init(
          message: "clear_alert_message",
          comment: "clear_alert_comment",
          confirm: "clear_alert_confirm",
          cancel: "clear_alert_cancel"
        ),
        suppressConfirmation: suppressClearAlert
      ) {
        Task { @MainActor in
          AppState.shared.history.clear()
        }
      },
      FooterItem(
        title: "clear_all",
        icon: "trash.fill",
        shortcuts: [KeyShortcut(key: .delete, modifierFlags: [.command, .option, .shift])],
        help: "clear_all_tooltip",
        confirmation: .init(
          message: "clear_alert_message",
          comment: "clear_alert_comment",
          confirm: "clear_alert_confirm",
          cancel: "clear_alert_cancel"
        ),
        suppressConfirmation: suppressClearAlert
      ) {
        Task { @MainActor in
          AppState.shared.history.clearAll()
        }
      },
      FooterItem(
        title: "snippets_studio",
        icon: "bolt.horizontal",
        hasTopDivider: true,
        shortcuts: [KeyShortcut(key: .m)]
      ) {
        Task { @MainActor in
          AppState.shared.popup.close()
          SnippetManagerWindowController.shared.show()
        }
      },
      FooterItem(
        title: "preferences",
        icon: "gearshape",
        shortcuts: [KeyShortcut(key: .comma)]
      ) {
        Task { @MainActor in
          AppState.shared.openPreferences()
        }
      },
      FooterItem(
        title: "check_for_updates",
        icon: "arrow.triangle.2.circlepath"
      ) {
        Task { @MainActor in
          AppState.shared.popup.close()
          SoftwareUpdater.shared.checkForUpdates()
        }
      },
      FooterItem(
        title: "about",
        icon: "info.circle",
        help: "about_tooltip"
      ) {
        AppState.shared.openAbout()
      },
      FooterItem(
        title: "quit",
        icon: "power",
        hasTopDivider: true,
        shortcuts: [KeyShortcut(key: .q)],
        help: "quit_tooltip"
      ) {
        AppState.shared.quit()
      }
    ]
  }
}
