import AppKit
import SwiftHEXColors

class ColorImage {
  private nonisolated(unsafe) static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 128
    return cache
  }()

  static func from(_ colorHex: String) -> NSImage? {
    let trimmed = colorHex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isPlausibleHexColor(trimmed) else {
      return nil
    }

    let key = trimmed.lowercased() as NSString
    if let cached = cache.object(forKey: key) {
      return cached
    }

    guard let color = NSColor(hexString: trimmed) else {
      return nil
    }

    let image = NSImage(size: NSSize(width: 12, height: 12))
    image.lockFocus()
    color.drawSwatch(in: NSRect(x: 0, y: 0, width: 12, height: 12))
    image.unlockFocus()

    cache.setObject(image, forKey: key)
    return image
  }

  private static func isPlausibleHexColor(_ raw: String) -> Bool {
    guard !raw.isEmpty, raw.utf8.count <= 10 else { return false }
    var slice = Substring(raw)
    if slice.hasPrefix("#") {
      slice.removeFirst()
    } else if slice.hasPrefix("0x") || slice.hasPrefix("0X") {
      slice.removeFirst(2)
    }

    let count = slice.utf8.count
    guard count == 3 || count == 4 || count == 6 || count == 8 else {
      return false
    }

    return slice.utf8.allSatisfy { byte in
      (byte >= 0x30 && byte <= 0x39) ||
      (byte >= 0x41 && byte <= 0x46) ||
      (byte >= 0x61 && byte <= 0x66)
    }
  }
}
