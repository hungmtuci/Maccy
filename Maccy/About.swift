import Cocoa

class About {
  private let familyCredits = NSAttributedString(
    string: "Original Maccy by Alex Rodionov (@p0deje) • Special thank you to Tonia, Anna & Guy! ❤️",
    attributes: [NSAttributedString.Key.foregroundColor: NSColor.secondaryLabelColor]
  )

  private var forkCredits: NSMutableAttributedString {
    let text = "Custom Edition maintained by Hung Le Xuan (hungmtuci/Maccy)"
    let string = NSMutableAttributedString(
      string: text,
      attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
    )
    if let range = text.range(of: "hungmtuci/Maccy") {
      string.addAttribute(.link, value: "https://github.com/hungmtuci/Maccy", range: NSRange(range, in: text))
    }
    return string
  }

  private var links: NSMutableAttributedString {
    let text = "Trang chủ gốc (maccy.app)  •  Upstream GitHub  •  Bản phát hành (GitHub Releases)"
    let string = NSMutableAttributedString(
      string: text,
      attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
    )
    if let r1 = text.range(of: "Trang chủ gốc (maccy.app)") {
      string.addAttribute(.link, value: "https://maccy.app", range: NSRange(r1, in: text))
    }
    if let r2 = text.range(of: "Upstream GitHub") {
      string.addAttribute(.link, value: "https://github.com/p0deje/Maccy", range: NSRange(r2, in: text))
    }
    if let r3 = text.range(of: "Bản phát hành (GitHub Releases)") {
      string.addAttribute(.link, value: "https://github.com/hungmtuci/Maccy/releases", range: NSRange(r3, in: text))
    }
    return string
  }

  private var credits: NSMutableAttributedString {
    let credits = NSMutableAttributedString(
      string: "",
      attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
    )
    credits.append(links)
    credits.append(NSAttributedString(string: "\n\n"))
    credits.append(forkCredits)
    credits.append(NSAttributedString(string: "\n"))
    credits.append(familyCredits)
    credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
    return credits
  }

  @objc
  func openAbout(_ sender: NSMenuItem?) {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [NSApplication.AboutPanelOptionKey.credits: credits])
  }
}
