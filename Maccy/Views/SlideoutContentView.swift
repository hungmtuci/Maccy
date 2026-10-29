import SwiftUI

struct SlideoutContentView: View {
  @Environment(AppState.self) var appState

  var body: some View {
    VStack {
      if appState.popupMode == .snippets {
        if let snippet = SnippetStore.shared.selectedPopupItem {
          SnippetSlideoutPreviewView(item: snippet)
        } else {
          EmptyView()
        }
      } else {
        ToolbarView()

        if let item = appState.navigator.leadHistoryItem {
          PreviewItemView(item: item)
        } else if let pasteStack = appState.history.pasteStack,
          appState.navigator.pasteStackSelected {
          PasteStackPreviewView(pasteStack: pasteStack)
        } else {
          EmptyView()
        }
      }
    }
    .padding(.horizontal)
    .padding(.bottom)
    .padding(.top, Popup.verticalPadding)
  }

}
