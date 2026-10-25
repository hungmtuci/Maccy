import AppKit
import Defaults

enum MenuIcon: String, CaseIterable, Identifiable, Defaults.Serializable {
  case maccy
  case clipboard
  case scissors
  case paperclip

  var id: Self { self }

  var image: NSImage {
    let resolved: NSImage?
    switch self {
    case .maccy:
      resolved = NSImage(named: .maccyStatusBar) ?? NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Maccy")
    case .clipboard:
      resolved = NSImage(named: .clipboard) ?? NSImage(systemSymbolName: "clipboard.fill", accessibilityDescription: "Clipboard")
    case .scissors:
      resolved = NSImage(named: .scissors) ?? NSImage(systemSymbolName: "scissors", accessibilityDescription: "Scissors")
    case .paperclip:
      resolved = NSImage(named: .paperclip) ?? NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Paperclip")
    }
    let img = resolved ?? NSImage()
    img.isTemplate = true
    return img
  }
}
