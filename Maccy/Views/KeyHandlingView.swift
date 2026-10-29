import Sauce
import Defaults
import SwiftUI

struct KeyHandlingView<Content: View>: View {
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool
  @ViewBuilder let content: () -> Content

  @Environment(AppState.self) private var appState

  var body: some View {
    content()
      .onKeyPress { _ in
        guard !appState.isEditingItem else { return .ignored }

        // Unfortunately, key presses don't allow access to
        // key code and don't properly work with multiple inputs,
        // so pressing ⌘, on non-English layout doesn't open
        // preferences. Stick to NSEvent to fix this behavior.

        if searchFocused {
          // Ignore input when candidate window is open
          // https://stackoverflow.com/questions/73677444/how-to-detect-the-candidate-window-when-using-japanese-keyboard
          if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
             inputClient.hasMarkedText() {
            return .ignored
          }
        }

        switch KeyChord(NSApp.currentEvent) {
        case .clearHistory:
          if let item = appState.footer.items.first(where: { $0.title == "clear" }),
             item.confirmation != nil,
             let suppressConfirmation = item.suppressConfirmation {
            if suppressConfirmation.wrappedValue {
              item.action()
            } else {
              item.showConfirmation = true
            }
            return .handled
          } else {
            return .ignored
          }
        case .clearHistoryAll:
          if let item = appState.footer.items.first(where: { $0.title == "clear_all" }),
             item.confirmation != nil,
             let suppressConfirmation = item.suppressConfirmation {
            if suppressConfirmation.wrappedValue {
              item.action()
            } else {
              item.showConfirmation = true
            }
            return .handled
          } else {
            return .ignored
          }
        case .clearSearch:
          searchQuery = ""
          return .handled
        case .deleteCurrentItem:
          if appState.popupMode == .snippets {
            if let selectedId = appState.snippets.selectedPopupItemId {
              appState.snippets.deleteItem(selectedId)
            }
            return .handled
          }
          if appState.navigator.pasteStackSelected {
            appState.removePasteStack()
          } else {
            appState.deleteSelection()
          }
          return .handled
        case .deleteOneCharFromSearch:
          searchFocused = true
          _ = searchQuery.popLast()
          return .handled
        case .deleteLastWordFromSearch:
          searchFocused = true
          let newQuery = searchQuery.split(separator: " ").dropLast().joined(separator: " ")
          if newQuery.isEmpty {
            searchQuery = ""
          } else {
            searchQuery = "\(newQuery) "
          }

          return .handled
        case .moveToNext:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          if appState.popupMode == .snippets {
            appState.navigator.isKeyboardNavigating = true
            appState.snippets.highlightNextInPopup()
            return .handled
          }

          appState.navigator.highlightNext()
          return .handled
        case .moveToLast:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          if appState.popupMode == .snippets {
            appState.navigator.isKeyboardNavigating = true
            appState.snippets.highlightLastInPopup()
            return .handled
          }

          appState.navigator.highlightLast()
          return .handled
        case .moveToPrevious:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          if appState.popupMode == .snippets {
            appState.navigator.isKeyboardNavigating = true
            appState.snippets.highlightPreviousInPopup()
            return .handled
          }

          appState.navigator.highlightPrevious()
          return .handled
        case .moveToFirst:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          if appState.popupMode == .snippets {
            appState.navigator.isKeyboardNavigating = true
            appState.snippets.highlightFirstInPopup()
            return .handled
          }

          appState.navigator.highlightFirst()
          return .handled
        case .extendToNext:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToNext()
          return .handled
        case .extendToLast:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToLast()
          return .handled
        case .extendToPrevious:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToPrevious()
          return .handled
        case .extendToFirst:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToFirst()
          return .handled
        case .openPreferences:
          appState.openPreferences()
          return .handled
        case .openSnippetStudio:
          appState.popup.close()
          SnippetManagerWindowController.shared.show(
            selecting: appState.popupMode == .snippets ? appState.snippets.selectedPopupItemId : nil
          )
          return .handled
        case .togglePopupMode:
          appState.togglePopupMode()
          return .handled
        case .editCurrentItem:
          if appState.popupMode == .snippets {
            let targetId = appState.snippets.selectedPopupItemId
            appState.popup.close()
            SnippetManagerWindowController.shared.show(selecting: targetId)
            return .handled
          }
          appState.beginEditing()
          return .handled
        case .pinOrUnpin:
          appState.togglePin()
          return .handled
        case .syncOrUnsync:
          appState.toggleSync()
          return .handled
        case .toggleSyncFilter:
          appState.toggleSyncFilter()
          return .handled
        case .selectCurrentItem:
          appState.select(flags: .currentModifierFlags)
          return .handled
        case .close:
          appState.popup.close()
          return .handled
        case .togglePreview:
          appState.preview.togglePreview()
          return .handled
        default:
          ()
        }

        if appState.popupMode == .snippets,
           let event = NSApp.currentEvent,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
           let ch = event.charactersIgnoringModifiers?.first,
           let num = Int(String(ch)),
           (1...9).contains(num) {
          let list = appState.snippets.filteredPopupItems
          if list.indices.contains(num - 1) {
            appState.triggerSnippetFromPopup(list[num - 1])
            return .handled
          }
        }

        if appState.popupMode == .clipboard, let item = appState.history.pressedShortcutItem {
          appState.navigator.select(item: item)
          Task {
            try? await Task.sleep(for: .milliseconds(50))
            appState.history.select(item, flags: .currentModifierFlags)
          }
          return .handled
        }

        return .ignored
      }
  }
}
