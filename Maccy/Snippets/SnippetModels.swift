import Foundation

nonisolated enum SnippetContentMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case plainText
  case richText
  case html
  case image
  case shellScript
  case appleScript
  case javaScript

  var id: Self { self }

  var title: String {
    switch self {
    case .plainText: return "Văn bản thuần (Plain Text)"
    case .richText: return "Văn bản định dạng (Rich Text)"
    case .html: return "HTML / Liên kết Rich Link"
    case .image: return "Hình ảnh (Image)"
    case .shellScript: return "Shell Script (zsh/bash)"
    case .appleScript: return "AppleScript"
    case .javaScript: return "JavaScript (JXA)"
    }
  }

  var iconName: String {
    switch self {
    case .plainText: return "doc.plaintext"
    case .richText: return "textformat"
    case .html: return "chevron.left.forwardslash.chevron.right"
    case .image: return "photo"
    case .shellScript: return "terminal"
    case .appleScript: return "applescript"
    case .javaScript: return "curlybraces"
    }
  }
}

nonisolated enum SnippetTriggerMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case immediate
  case afterDelimiter
  case manualOnly

  var id: Self { self }

  var title: String {
    switch self {
    case .immediate: return "Bung ngay khi gõ khớp (⚡)"
    case .afterDelimiter: return "Sau dấu cách / Enter / dấu câu"
    case .manualOnly: return "Chỉ chọn từ danh sách (⌘⇧S)"
    }
  }

  var badgeSymbol: String {
    switch self {
    case .immediate: return "bolt.fill"
    case .afterDelimiter: return "space"
    case .manualOnly: return "hand.tap"
    }
  }
}

nonisolated enum SnippetCaseMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case ignoreCase
  case caseSensitive
  case propagateCase

  var id: Self { self }

  var title: String {
    switch self {
    case .ignoreCase: return "Không phân biệt HOA/thường (~)"
    case .caseSensitive: return "Khớp chính xác HOA/thường (Aa)"
    case .propagateCase: return "Tự đổi HOA/thường theo chữ gõ"
    }
  }

  var shortSymbol: String {
    switch self {
    case .ignoreCase: return "~"
    case .caseSensitive: return "Aa"
    case .propagateCase: return "A→a"
    }
  }
}

nonisolated struct SnippetCollection: Codable, Identifiable, Hashable, Sendable {
  var id: UUID = UUID()
  var name: String
  var icon: String = "folder.fill"
  var isEnabled: Bool = true
  var keywordPrefix: String = ""
  var keywordSuffix: String = ""
  var sortOrder: Int = 0
  var updatedAt: Date = Date.now
  var isDeleted: Bool = false
}

nonisolated struct SnippetItem: Codable, Identifiable, Hashable, Sendable {
  var id: UUID = UUID()
  var collectionId: UUID
  var name: String
  var abbreviation: String
  var content: String
  var rtfData: Data?
  var htmlData: Data?
  var imagePNGData: Data?
  var isPayloadCompressed: Bool?
  var isPayloadEncrypted: Bool?
  var encryptedContent: Data?
  var contentMode: SnippetContentMode = .plainText
  var triggerMode: SnippetTriggerMode = .immediate
  var caseMode: SnippetCaseMode = .ignoreCase
  var wholeWord: Bool = false
  var isEnabled: Bool = true
  var usageCount: Int = 0
  var lastUsedAt: Date?
  var updatedAt: Date = Date.now
  var isDeleted: Bool = false

  func effectiveAbbreviation(in collection: SnippetCollection?) -> String {
    let raw = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "" }
    let prefix = collection?.keywordPrefix ?? ""
    let suffix = collection?.keywordSuffix ?? ""
    var result = raw
    if !prefix.isEmpty && !result.hasPrefix(prefix) {
      result = prefix + result
    }
    if !suffix.isEmpty && !result.hasSuffix(suffix) {
      result += suffix
    }
    return result
  }

  var displayTitle: String {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedName.isEmpty {
      return trimmedName
    }
    let firstLine = content
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .shortened(to: 80)
    return firstLine.isEmpty ? "(Snippet trống)" : firstLine
  }
}

nonisolated struct SnippetSyncDatabase: Codable, Sendable {
  var version: Int = 1
  var updatedAt: Date = Date.now
  var deviceName: String = ""
  var collections: [UUID: SnippetCollection] = [:]
  var items: [UUID: SnippetItem] = [:]
}

nonisolated enum SnippetFillInKind: Equatable, Sendable {
  case singleLine(defaultValue: String)
  case multiLine(defaultValue: String)
  case dropdown(options: [String], defaultIndex: Int)
  case optionalSection(defaultIncluded: Bool, bodyTemplate: String)
}

nonisolated struct SnippetFillInField: Identifiable, Equatable, Sendable {
  var id: String { key }
  var key: String
  var label: String
  var kind: SnippetFillInKind
}

nonisolated enum EmulatedKeyKind: String, Sendable {
  case tab
  case enter
  case escape
  case upArrow
  case downArrow
  case leftArrow
  case rightArrow
}

nonisolated enum ExpandedActionStep: Sendable {
  case pasteText(String, htmlData: Data?, rtfData: Data?)
  case pasteImage(Data)
  case keyPress(EmulatedKeyKind, count: Int)
  case delayMilliseconds(Int)
}

nonisolated struct SnippetImportSummary: Sendable {
  var collectionsImported: Int
  var snippetsImported: Int
  var snippetsUpdated: Int
  var sourceDescription: String
}
