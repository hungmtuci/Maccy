import Foundation

nonisolated struct SizedString: Sendable {
  let string: String
  let byteCount: Int
  let totalOriginalBytes: Int
  let isTruncated: Bool

  init(
    _ string: String,
    maxParagraphBytes: Int = 10_000,
    maxTotalBytes: Int = 32_768,
    originalByteCount: Int? = nil
  ) {
    let bytes = string.utf8
    let shortenedBytes = bytes.shortened(
      maxParagraphBytes: maxParagraphBytes,
      maxTotalBytes: maxTotalBytes
    )
    let truncatedByShortening = shortenedBytes.endIndex != bytes.endIndex
    let resolvedOriginalBytes = originalByteCount ?? bytes.count

    self.byteCount = shortenedBytes.count
    self.totalOriginalBytes = Swift.max(resolvedOriginalBytes, shortenedBytes.count)
    self.isTruncated = truncatedByShortening || (self.totalOriginalBytes > shortenedBytes.count)

    if truncatedByShortening {
      self.string = String(bytes: shortenedBytes, encoding: .utf8) ?? String(decoding: shortenedBytes, as: UTF8.self)
    } else {
      self.string = string
    }
  }
}
