import AppKit.NSWorkspace
import Defaults
import Foundation
import Observation
import Sauce
import SwiftUI

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  private static let previewMaxParagraphSize = 10_000
  private static let previewMaxTotalSize = 32_768

  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewImageSize: NSSize { NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536) }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()

  var title: String = ""
  var attributedTitle: AttributedString?
  var matchedSnippet: AttributedString?

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var isSynced: Bool = false
  var shortcuts: [KeyShortcut] = []

  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }

  var hasImage: Bool { item.imageData != nil }
  var hasFileURLs: Bool { !item.fileURLs.isEmpty }
  var hasPlainText: Bool { item.text != nil }
  var hasRichText: Bool { item.rtfData != nil || item.htmlData != nil }

  var previewImageGenerationTask: Task<(), Error>?
  var thumbnailImageGenerationTask: Task<(), Error>?
  var previewImage: NSImage?

  @ObservationIgnored
  private var _cachedPreviewText: SizedString?
  @ObservationIgnored
  private var _cachedFoldedTitle: String?
  @ObservationIgnored
  private var _cachedSearchableBodyText: String?
  @ObservationIgnored
  private var _cachedFoldedBodyText: String?

  var foldedTitle: String {
    if let cached = _cachedFoldedTitle {
      return cached
    }
    let folded = title.foldingVietnameseDiacritics
    _cachedFoldedTitle = folded
    return folded
  }

  /// Lazily extracted plain body text (up to 64 KB) for deep search & snippet generation.
  var searchableBodyText: String {
    if let cached = _cachedSearchableBodyText {
      return cached
    }
    let extracted = item.previewableTextPrefix(maxBytes: 65_536).text
    _cachedSearchableBodyText = extracted
    return extracted
  }

  /// Lazily computed folded body text (up to 64 KB) for deep full-text search in long items.
  var foldedSearchableBodyText: String {
    if let cached = _cachedFoldedBodyText {
      return cached
    }
    let folded = searchableBodyText.foldingVietnameseDiacritics
    _cachedFoldedBodyText = folded
    return folded
  }

  var syncSourceDevice: String? {
    CloudSyncManager.shared.syncMetadata(for: item.contentHash)?.deviceName
  }

  var syncUpdatedAt: Date? {
    CloudSyncManager.shared.syncMetadata(for: item.contentHash)?.updatedAt
  }

  /// Lazily computed & bounded preview text so loading hundreds of large history items never blocks the main thread.
  var previewText: SizedString {
    if let cached = _cachedPreviewText {
      return cached
    }
    let extracted = item.previewableTextPrefix(maxBytes: 40_000)
    let sized = SizedString(
      extracted.text,
      maxParagraphBytes: Self.previewMaxParagraphSize,
      maxTotalBytes: Self.previewMaxTotalSize,
      originalByteCount: extracted.totalBytes
    )
    _cachedPreviewText = sized
    return sized
  }

  func invalidatePreviewText() {
    _cachedPreviewText = nil
    _cachedFoldedTitle = nil
    _cachedSearchableBodyText = nil
    _cachedFoldedBodyText = nil
  }

  var thumbnailImage: NSImage?
  var applicationImage: ApplicationImage

  @ObservationIgnored
  private(set) lazy var imageSize: String? = item.imageData.map {
    ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file)
  }

  var formattedDataSize: String {
    ByteCountFormatter.string(fromByteCount: Int64(item.totalByteCount), countStyle: .file)
  }

  // Bounded text accessor for menu bar icon & quick inspection
  var text: String {
    if !title.isEmpty {
      return title
    }
    return previewText.string.shortened(to: 10_000)
  }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
    hasher.combine(matchedSnippet)
    hasher.combine(isSynced)
  }

  private(set) var item: HistoryItem

  var multiSelectionIndex: Int? {
    guard selectionIndex >= 0, AppState.shared.navigator.isMultiSelectInProgress else {
      return nil
    }
    return selectionIndex
  }

  // Describe the complete item independently of its potentially truncated visual content.
  var accessibilityLabel: String {
    var parts: [String] = []
    if hasImage, let image = item.image {
      let size = image.pixelSize
      parts.append(
        String(
          format: NSLocalizedString("history_item_image_accessibility_label_no_app", comment: ""),
          Int(size.width),
          Int(size.height)
        )
      )
    } else {
      parts.append(title)
    }
    if let application = application {
      parts.append(application)
    }
    if isPinned {
      parts.append(NSLocalizedString("history_item_pinned_accessibility_value", comment: ""))
    }
    if isSynced {
      parts.append("Đã đồng bộ Google Drive")
    }
    if let index = multiSelectionIndex {
      parts.append(
        String(
          format: NSLocalizedString("history_item_selected_accessibility_value", comment: ""),
          index + 1,
          AppState.shared.navigator.selection.count
        )
      )
    }
    return parts.joined(separator: ", ")
  }

  @MainActor
  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.isSynced = Defaults[.syncedItemHashes].contains(item.contentHash)
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
  }

  @MainActor
  func ensureThumbnailImage() {
    guard item.imageData != nil else {
      return
    }
    guard thumbnailImage == nil else {
      return
    }
    guard thumbnailImageGenerationTask == nil else {
      return
    }
    thumbnailImageGenerationTask = Task { [weak self] in
      self?.generateThumbnailImage()
    }
  }

  @MainActor
  func ensurePreviewImage() {
    guard item.imageData != nil else {
      return
    }
    guard previewImage == nil else {
      return
    }
    guard previewImageGenerationTask == nil else {
      return
    }
    previewImageGenerationTask = Task { [weak self] in
      self?.generatePreviewImage()
    }
  }

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }
    ensurePreviewImage()
    _ = await previewImageGenerationTask?.result
    return previewImage
  }

  @MainActor
  func cleanupImages() {
    thumbnailImageGenerationTask?.cancel()
    previewImageGenerationTask?.cancel()
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
    _cachedPreviewText = nil
    item.clearDecodedImageCache()
  }

  @MainActor
  private func generateThumbnailImage() {
    guard let image = item.image else {
      return
    }
    thumbnailImage = image.resized(to: HistoryItemDecorator.thumbnailImageSize)
  }

  @MainActor
  private func generatePreviewImage() {
    guard let image = item.image else {
      return
    }
    previewImage = image.resized(to: HistoryItemDecorator.previewImageSize)
  }

  @MainActor
  func sizeImages() {
    generatePreviewImage()
    generateThumbnailImage()
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>], matchedInBody: Bool = false) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      matchedSnippet = nil
      return
    }

    if ranges.isEmpty && matchedInBody {
      attributedTitle = nil
      matchedSnippet = buildMatchedBodySnippet(for: query)
      return
    }

    matchedSnippet = nil
    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        applyHighlightStyle(to: &attributedString, range: lowerBound..<upperBound, baseFont: .body)
      }
    }

    attributedTitle = attributedString
  }

  private func applyHighlightStyle(
    to attributedString: inout AttributedString,
    range: Range<AttributedString.Index>,
    baseFont: Font
  ) {
    switch Defaults[.highlightMatch] {
    case .bold:
      attributedString[range].font = baseFont.bold()
    case .italic:
      attributedString[range].font = baseFont.italic()
    case .underline:
      attributedString[range].underlineStyle = .single
    default:
      attributedString[range].backgroundColor = .findHighlightColor
      attributedString[range].foregroundColor = .black
    }
  }

  private func buildMatchedBodySnippet(for query: String) -> AttributedString? {
    let body = searchableBodyText
    guard !body.isEmpty else { return nil }

    let matches = body.allRangesByVietnameseSearch(
      of: query,
      precomputedFoldedSelf: foldedSearchableBodyText,
      maxMatches: 1
    )
    guard let firstMatch = matches.first else { return nil }

    let contextBefore = 32
    let contextAfter = 68
    let winStart = body.index(firstMatch.lowerBound, offsetBy: -contextBefore, limitedBy: body.startIndex) ?? body.startIndex
    let winEnd = body.index(firstMatch.upperBound, offsetBy: contextAfter, limitedBy: body.endIndex) ?? body.endIndex

    var rawSlice = String(body[winStart..<winEnd])
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawSlice.isEmpty else { return nil }

    if winStart > body.startIndex {
      rawSlice = "…" + rawSlice
    }
    if winEnd < body.endIndex {
      rawSlice += "…"
    }

    var snippetAttr = AttributedString(rawSlice)
    let snippetRanges = rawSlice.allRangesByVietnameseSearch(of: query, maxMatches: 8)
    let snippetFont = Font.system(size: 11)
    for range in snippetRanges {
      if let lower = AttributedString.Index(range.lowerBound, within: snippetAttr),
         let upper = AttributedString.Index(range.upperBound, within: snippetAttr) {
        applyHighlightStyle(to: &snippetAttr, range: lower..<upper, baseFont: snippetFont)
      }
    }

    return snippetAttr
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.title
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.title = self.item.title
        self._cachedPreviewText = nil
        self._cachedFoldedTitle = nil
        self._cachedSearchableBodyText = nil
        self._cachedFoldedBodyText = nil
        self.synchronizeItemTitle()
      }
    }
  }
}
