import AppKit
import ApplicationServices

struct Accessibility {
  static var allowed: Bool { AXIsProcessTrustedWithOptions(nil) }

  static func check() {
    guard !allowed else {
      return
    }
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }
}
