import AppKit
import CryptoKit
import Defaults
import Observation
import Sauce
import SwiftData
import Vision

nonisolated final class HistoryItem: PersistentModel, Observable, @unchecked Sendable {
  private let _$observationRegistrar = Observation.ObservationRegistrar()
  var _$backingData: any SwiftData.BackingData<HistoryItem> = HistoryItem.createBackingData()

  var persistentBackingData: any SwiftData.BackingData<HistoryItem> {
    get { _$backingData }
    set { _$backingData = newValue }
  }

  static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
    return [
      SwiftData.Schema.PropertyMetadata(
        name: "application",
        keypath: \HistoryItem.application,
        defaultValue: nil,
        metadata: nil
      ),
      SwiftData.Schema.PropertyMetadata(
        name: "firstCopiedAt",
        keypath: \HistoryItem.firstCopiedAt,
        defaultValue: Date.now,
        metadata: nil
      ),
      SwiftData.Schema.PropertyMetadata(
        name: "lastCopiedAt",
        keypath: \HistoryItem.lastCopiedAt,
        defaultValue: Date.now,
        metadata: nil
      ),
      SwiftData.Schema.PropertyMetadata(
        name: "numberOfCopies",
        keypath: \HistoryItem.numberOfCopies,
        defaultValue: 1,
        metadata: nil
      ),
      SwiftData.Schema.PropertyMetadata(
        name: "pin",
        keypath: \HistoryItem.pin,
        defaultValue: nil,
        metadata: nil
      ),
      SwiftData.Schema.PropertyMetadata(
        name: "title",
        keypath: \HistoryItem.title,
        defaultValue: "",
        metadata: nil
      ),
      SwiftData.Schema.PropertyMetadata(
        name: "contents",
        keypath: \HistoryItem.contents,
        defaultValue: [HistoryItemContent](),
        metadata: SwiftData.Schema.Relationship(
          deleteRule: .cascade,
          inverse: \HistoryItemContent.item
        )
      )
    ]
  }

  @MainActor
  static var supportedPins: Set<String> {
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y",
      "[", "]", ";", "'", ".", "/", "-", "=", "\\"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }
    if let previewKey = KeyChord.previewKey,
       let character = Sauce.shared.character(for: Int(previewKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }
    if let syncKey = KeyChord.syncKey,
       let character = Sauce.shared.character(for: Int(syncKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }

    return keys
  }

  // Letters first, then symbols.
  static func sortedPins(_ pins: some Sequence<String>) -> [String] {
    pins.sorted { lhs, rhs in
      let lhsIsLetter = lhs.first?.isLetter ?? false
      let rhsIsLetter = rhs.first?.isLetter ?? false
      return lhsIsLetter == rhsIsLetter ? lhs < rhs : lhsIsLetter
    }
  }

  @MainActor
  static var availablePins: [String] {
    History.shared.availablePins
  }

  @MainActor
  static func availablePins(in items: [HistoryItem]) -> [String] {
    let assignedPins = Set(items.compactMap(\.pin))
    return Array(supportedPins.subtracting(assignedPins))
  }

  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  static let transientTypes: Set<String> = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromMaccy.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]
  private static let imageTypes: [NSPasteboard.PasteboardType] = StorageType.images.types

  var application: String? {
    get {
      _$observationRegistrar.access(self, keyPath: \.application)
      return self.getValue(forKey: \.application)
    }
    set {
      _$observationRegistrar.withMutation(of: self, keyPath: \.application) {
        self.setValue(forKey: \.application, to: newValue)
      }
    }
  }

  var firstCopiedAt: Date {
    get {
      _$observationRegistrar.access(self, keyPath: \.firstCopiedAt)
      return self.getValue(forKey: \.firstCopiedAt)
    }
    set {
      _$observationRegistrar.withMutation(of: self, keyPath: \.firstCopiedAt) {
        self.setValue(forKey: \.firstCopiedAt, to: newValue)
      }
    }
  }

  var lastCopiedAt: Date {
    get {
      _$observationRegistrar.access(self, keyPath: \.lastCopiedAt)
      return self.getValue(forKey: \.lastCopiedAt)
    }
    set {
      _$observationRegistrar.withMutation(of: self, keyPath: \.lastCopiedAt) {
        self.setValue(forKey: \.lastCopiedAt, to: newValue)
      }
    }
  }

  var numberOfCopies: Int {
    get {
      _$observationRegistrar.access(self, keyPath: \.numberOfCopies)
      return self.getValue(forKey: \.numberOfCopies)
    }
    set {
      _$observationRegistrar.withMutation(of: self, keyPath: \.numberOfCopies) {
        self.setValue(forKey: \.numberOfCopies, to: newValue)
      }
    }
  }

  var pin: String? {
    get {
      _$observationRegistrar.access(self, keyPath: \.pin)
      return self.getValue(forKey: \.pin)
    }
    set {
      _$observationRegistrar.withMutation(of: self, keyPath: \.pin) {
        self.setValue(forKey: \.pin, to: newValue)
      }
    }
  }

  var title: String {
    get {
      _$observationRegistrar.access(self, keyPath: \.title)
      return self.getValue(forKey: \.title)
    }
    set {
      _$observationRegistrar.withMutation(of: self, keyPath: \.title) {
        self.setValue(forKey: \.title, to: newValue)
      }
    }
  }

  var contents: [HistoryItemContent] {
    get {
      _$observationRegistrar.access(self, keyPath: \.contents)
      return self.getValue(forKey: \.contents)
    }
    set {
      cachedContentHash = nil
      cachedTotalByteCount = nil
      _$observationRegistrar.withMutation(of: self, keyPath: \.contents) {
        self.setValue(forKey: \.contents, to: newValue)
      }
    }
  }

  private var cachedDecodedImage: NSImage?
  private var cachedContentHash: String?
  private var cachedTotalByteCount: Int?

  init(contents: [HistoryItemContent] = []) {
    let now = Date.now
    _$backingData.setValue(forKey: \.application, to: nil)
    _$backingData.setValue(forKey: \.firstCopiedAt, to: now)
    _$backingData.setValue(forKey: \.lastCopiedAt, to: now)
    _$backingData.setValue(forKey: \.numberOfCopies, to: 1)
    _$backingData.setValue(forKey: \.pin, to: nil)
    _$backingData.setValue(forKey: \.title, to: "")
    _$backingData.setValue(forKey: \.contents, to: [])
    if !contents.isEmpty {
      self.contents = contents
    }
  }

  required init(backingData: any SwiftData.BackingData<HistoryItem>) {
    self._$backingData = backingData
  }

  func invalidateContentCache() {
    cachedContentHash = nil
    cachedTotalByteCount = nil
  }

  /// Fast, bounded SHA-256 fingerprint of non-transient contents.
  /// Avoids scanning or loading multi-megabyte SQLite blobs repeatedly during deduplication and sync.
  var contentHash: String {
    if let cached = cachedContentHash {
      return cached
    }

    var hasher = SHA256()
    let relevantContents = contents
      .filter { !Self.transientTypes.contains($0.type) }
      .sorted { $0.type < $1.type }

    if relevantContents.isEmpty {
      hasher.update(data: Data(title.utf8))
    } else {
      for content in relevantContents {
        hasher.update(data: Data(content.type.utf8))
        if let data = content.value {
          var count = data.count
          withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
          if data.count <= 65_536 {
            hasher.update(data: data)
          } else {
            // Sample first 32 KB, middle 16 KB, and last 16 KB for O(1) hashing on multi-MB data
            hasher.update(data: data.prefix(32_768))
            let midStart = data.count / 2 - 8_192
            hasher.update(data: data.subdata(in: midStart..<(midStart + 16_384)))
            hasher.update(data: data.suffix(16_384))
          }
        }
      }
    }

    let digest = hasher.finalize()
    let hashString = digest.map { String(format: "%02x", $0) }.joined()
    cachedContentHash = hashString
    return hashString
  }

  var totalByteCount: Int {
    if let cached = cachedTotalByteCount {
      return cached
    }
    let total = contents.reduce(0) { $0 + ($1.value?.count ?? 0) }
    cachedTotalByteCount = total
    return total
  }

  func supersedes(_ item: HistoryItem) -> Bool {
    let otherNonTransient = item.contents.filter { !Self.transientTypes.contains($0.type) }
    guard !otherNonTransient.isEmpty else { return false }

    let myTypes = Set(contents.lazy.filter { !Self.transientTypes.contains($0.type) }.map(\.type))
    let otherTypes = Set(otherNonTransient.map(\.type))
    guard myTypes.isSuperset(of: otherTypes) else { return false }

    if myTypes == otherTypes {
      return self.contentHash == item.contentHash
    }

    return otherNonTransient.allSatisfy { otherContent in
      contents.contains { myContent in
        guard myContent.type == otherContent.type else { return false }
        guard myContent.value?.count == otherContent.value?.count else { return false }
        return myContent.value == otherContent.value
      }
    }
  }

  @MainActor
  func generateTitle() -> String {
    let pasteboardImageData = contentData(Self.imageTypes)
    let universalClipboardImageURL = universalClipboardImage ? fileURLs.first : nil
    guard pasteboardImageData == nil && universalClipboardImageURL == nil else {
      Task { @MainActor in
        if let recognizedText = await Self.recognizeText(
          imageData: pasteboardImageData,
          fileURL: universalClipboardImageURL
        ), !recognizedText.isEmpty {
          self.title = recognizedText
          try? Storage.shared.context.save()
        }
      }
      return ""
    }

    // Decode at most 4 KB of UTF-8 to generate a 1,000-character title without allocating multi-MB strings.
    var title = previewableTextPrefix(maxBytes: 4_096).text
      .shortened(to: 1_000)
      .removingScalarsUnsafeForTitleLayout()

    if Defaults[.showSpecialSymbols] {
      if let range = title.range(of: "^ +", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      if let range = title.range(of: " +$", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  /// Bounded preview text extractor that never decodes multi-megabyte strings on the main thread.
  func previewableTextPrefix(maxBytes: Int = 40_000) -> (text: String, totalBytes: Int) {
    if !fileURLs.isEmpty {
      let joined = fileURLs
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
      return (joined.shortened(to: maxBytes), joined.utf8.count)
    }

    if let stringData = contentData([.string]), !stringData.isEmpty {
      let prefixText = stringData.utf8PrefixString(maxBytes: maxBytes) ?? ""
      if !prefixText.isEmpty {
        return (prefixText, stringData.count)
      }
    }

    if let rtfData = contentData([.rtf]), !rtfData.isEmpty {
      // Only parse RTF via NSAttributedString if <= 256 KB to prevent main-thread CoreText freezes
      if rtfData.count <= 262_144,
         let attr = NSAttributedString(rtf: rtfData, documentAttributes: nil),
         !attr.string.isEmpty {
        return (attr.string.shortened(to: maxBytes), rtfData.count)
      } else if let rawPrefix = rtfData.utf8PrefixString(maxBytes: maxBytes) {
        return (rawPrefix, rtfData.count)
      }
    }

    if let htmlData = contentData([.html]), !htmlData.isEmpty {
      // NSAttributedString(html:) invokes WebKit on the main thread and freezes on large HTML
      if htmlData.count <= 65_536,
         let attr = NSAttributedString(html: htmlData, documentAttributes: nil),
         !attr.string.isEmpty {
        return (attr.string.shortened(to: maxBytes), htmlData.count)
      } else if let rawHTML = htmlData.utf8PrefixString(maxBytes: maxBytes) {
        let stripped = rawHTML.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return (stripped, htmlData.count)
      }
    }

    return (title, title.utf8.count)
  }

  var previewableText: String {
    previewableTextPrefix(maxBytes: 40_000).text
  }

  var fileURLs: [URL] {
    guard !universalClipboardText else {
      return []
    }

    return allContentData([.fileURL])
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  var htmlData: Data? { contentData([.html]) }
  var html: NSAttributedString? {
    guard let data = htmlData, data.count <= 131_072 else {
      return nil
    }

    return NSAttributedString(html: data, documentAttributes: nil)
  }

  var imageData: Data? {
    var data: Data?
    data = contentData(Self.imageTypes)
    if data == nil, universalClipboardImage, let url = fileURLs.first {
      data = try? Data(contentsOf: url)
    }

    return data
  }

  var image: NSImage? {
    if let img = cachedDecodedImage {
      return img
    }
    guard let data = imageData else {
      return nil
    }

    cachedDecodedImage = NSImage(data: data)
    return cachedDecodedImage
  }

  var rtfData: Data? { contentData([.rtf]) }
  var rtf: NSAttributedString? {
    guard let data = rtfData, data.count <= 262_144 else {
      return nil
    }

    return NSAttributedString(rtf: data, documentAttributes: nil)
  }

  func clearDecodedImageCache() {
    cachedDecodedImage?.recache()
    cachedDecodedImage = nil
  }

  var text: String? {
    guard let data = contentData([.string]) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  var fromMaccy: Bool { contentData([.fromMaccy]) != nil }
  var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

  private var universalClipboardImage: Bool { universalClipboard && fileURLs.first?.pathExtension == "jpeg" }
  private var universalClipboardText: Bool {
    universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic]) != nil
  }

  private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
    let content = contents.first(where: { content in
      return types.contains(NSPasteboard.PasteboardType(content.type))
    })

    return content?.value
  }

  private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
    return contents
      .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
      .compactMap { $0.value }
  }

  nonisolated private static let textRecognitionQueue = DispatchQueue(
    label: "org.p0deje.Maccy.textRecognition",
    qos: .utility
  )

  /// Runs OCR on a dedicated queue so the blocking Vision call never occupies
  /// a thread of Swift's cooperative pool or the main thread.
  nonisolated private static func recognizeText(imageData: Data?, fileURL: URL?) async -> String? {
    await withCheckedContinuation { continuation in
      textRecognitionQueue.async {
        continuation.resume(returning: performTextRecognition(imageData: imageData, fileURL: fileURL))
      }
    }
  }

  nonisolated private static func performTextRecognition(imageData: Data?, fileURL: URL?) -> String? {
    guard let data = imageData ?? fileURL.flatMap({ try? Data(contentsOf: $0) }) else {
      return nil
    }

    let requestHandler = VNImageRequestHandler(data: data)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if let supported = try? request.supportedRecognitionLanguages() {
      // Note: Apple Vision uses "vi-VT" for Vietnamese in VNRecognizeTextRequest; match any "vi*" code dynamically!
      let vietnameseCodes = supported.filter { $0.lowercased().hasPrefix("vi") }
      let englishCodes = supported.filter { $0 == "en-US" }
      let preferred = vietnameseCodes + englishCodes
      if !preferred.isEmpty {
        request.recognitionLanguages = preferred
      }
    }
    request.automaticallyDetectsLanguage = true

    do {
      try requestHandler.perform([request])
    } catch {
      print("Unable to perform the request: \(error).")
      return nil
    }

    guard let observations = request.results else {
      return nil
    }

    return observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
}
