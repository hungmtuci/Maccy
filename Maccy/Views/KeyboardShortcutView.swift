import SwiftUI

struct KeyboardShortcutView: View {
  var shortcut: KeyShortcut?

  var modifiers: String {
    if var shortcut = shortcut?.description {
      _ = shortcut.popLast()
      return shortcut
    }
    return ""
  }

  var character: String {
    return shortcut?.description.last?.description ?? ""
  }

  var body: some View {
    HStack(spacing: 1) {
      ForEach(Array(modifiers.unicodeScalars), id: \.self) { scalar in
          Text(String(scalar))
      }
      Text(character).frame(width: 12, alignment: .center)
    }
    .lineLimit(1)
    .opacity(character.isEmpty ? 0 : 0.7)
  }
}
