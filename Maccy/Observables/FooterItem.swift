import SwiftUI

@Observable
class FooterItem: Equatable, Identifiable, HasVisibility {
  struct Confirmation {
    var message: LocalizedStringKey
    var comment: LocalizedStringKey
    var confirm: LocalizedStringKey
    var cancel: LocalizedStringKey
  }

  static func == (lhs: FooterItem, rhs: FooterItem) -> Bool {
    return lhs.id == rhs.id
  }

  let id = UUID()

  var title: String
  var icon: String?
  var hasTopDivider: Bool
  var shortcuts: [KeyShortcut] = []
  var help: LocalizedStringKey?
  var isSelected: Bool = false
  var confirmation: Confirmation?
  var showConfirmation: Bool = false
  var suppressConfirmation: Binding<Bool>?
  var isVisible: Bool = true
  var action: () -> Void

  init(
    title: String,
    icon: String? = nil,
    hasTopDivider: Bool = false,
    shortcuts: [KeyShortcut] = [],
    help: LocalizedStringKey? = nil,
    confirmation: Confirmation? = nil,
    suppressConfirmation: Binding<Bool>? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.icon = icon
    self.hasTopDivider = hasTopDivider
    self.shortcuts = shortcuts
    self.help = help
    self.confirmation = confirmation
    self.suppressConfirmation = suppressConfirmation
    self.action = action
  }
}
