import AppKit
import CryptoKit
import Defaults
import Foundation
import Logging
import Observation

enum SnippetStudioScope: Hashable, Sendable {
  case all
  case activeTriggers
  case collection(UUID)
}

nonisolated struct SnippetDeduplicationSummary: Sendable {
  var didMutate: Bool
  var mergedCollectionsCount: Int
  var removedDuplicateItemsCount: Int
  var didFindTypinatorDefaultSet: Bool
}

nonisolated struct ActiveExpansionCandidate: Sendable {
  var item: SnippetItem
  var collection: SnippetCollection
  var effectiveAbbreviation: String
  var lowercasedAbbreviation: String
}

private nonisolated struct SnippetSearchEntry: Sendable {
  var sourceItemUpdatedAt: Date
  var sourceCollectionUpdatedAt: Date
  var foldedName: String
  var foldedAbbreviation: String
  var strippedFoldedAbbreviation: String
  var foldedCollectionName: String
  var foldedContent: String
  var singleLinePreview: String
}

@Observable
@MainActor
class SnippetStore {
  static let shared = SnippetStore()

  private let logger = Logger(label: "org.p0deje.Maccy.Snippets")
  private nonisolated static let localFileName = "maccy-snippets-local.json"
  nonisolated static let cloudFileName = "maccy-snippets.json"

  private var allCollections: [UUID: SnippetCollection] = [:]
  private var allItems: [UUID: SnippetItem] = [:]
  @ObservationIgnored private var searchIndex: [UUID: SnippetSearchEntry] = [:]
  @ObservationIgnored private var itemCountsByCollection: [UUID: Int] = [:]
  @ObservationIgnored private var enabledItemCountsByCollection: [UUID: Int] = [:]
  @ObservationIgnored private var activeExpansionItemIds: Set<UUID> = []
  @ObservationIgnored private var immediateBuckets: [Character: [ActiveExpansionCandidate]] = [:]
  @ObservationIgnored private var delimiterBuckets: [Character: [ActiveExpansionCandidate]] = [:]

  private(set) var collections: [SnippetCollection] = []
  private(set) var items: [SnippetItem] = []
  private(set) var activeExpansionItems: [SnippetItem] = []
  private(set) var activeExpansionCandidates: [ActiveExpansionCandidate] = []
  private(set) var totalPopupEnabledItemCount: Int = 0
  private(set) var maxAbbreviationLength: Int = 24
  @ObservationIgnored private(set) var lastObservedCloudModificationDate: Date?

  // Popup Snippet Mode state
  var popupSearchQuery: String = "" {
    didSet {
      ensureValidPopupSelection()
    }
  }
  var selectedPopupCollectionId: UUID? {
    didSet {
      ensureValidPopupSelection()
    }
  }
  var selectedPopupItemId: UUID?

  var isSyncingSnippets: Bool = false
  var lastSnippetSyncMessage: String = ""

  private var saveTask: Task<Void, Never>?

  private nonisolated static var localStoreURL: URL {
    URL.applicationSupportDirectory.appending(path: "Maccy/\(localFileName)")
  }

  init() {
    #if DEBUG
    if AppDelegate.isTesting || History.isRunningUnitTests {
      ensureDefaultCollectionIfNeeded(persist: false)
      rebuildCaches()
      return
    }
    #endif

    loadFromLocalDisk()
    let shouldSanitizeDefaultSet = !Defaults[.didSanitizeTypinatorDefaultSet]
    let cleanupSummary = Self.deduplicateAndSanitize(
      collections: &allCollections,
      items: &allItems,
      sanitizeTypinatorDefaultSet: shouldSanitizeDefaultSet
    )
    if shouldSanitizeDefaultSet && cleanupSummary.didFindTypinatorDefaultSet {
      Defaults[.didSanitizeTypinatorDefaultSet] = true
    }

    ensureDefaultCollectionIfNeeded(persist: false)
    rebuildCaches()

    if cleanupSummary.didMutate {
      scheduleSaveAndSync()
    } else if Defaults[.cloudSyncEnabled] {
      Task {
        await syncWithGoogleDrive()
      }
    }
  }

  // MARK: - Queries & Filtering

  func collection(for id: UUID) -> SnippetCollection? {
    allCollections[id]
  }

  func item(for id: UUID) -> SnippetItem? {
    guard let found = allItems[id], !found.isDeleted else { return nil }
    return found
  }

  var selectedPopupItem: SnippetItem? {
    guard let id = selectedPopupItemId else { return filteredPopupItems.first }
    return item(for: id) ?? filteredPopupItems.first
  }

  func itemCount(in collectionId: UUID) -> Int {
    itemCountsByCollection[collectionId] ?? 0
  }

  func enabledItemCount(in collectionId: UUID) -> Int {
    enabledItemCountsByCollection[collectionId] ?? 0
  }

  func isActivelyExpanding(_ item: SnippetItem) -> Bool {
    activeExpansionItemIds.contains(item.id)
  }

  func singleLinePreview(for item: SnippetItem) -> String {
    if let cached = searchIndex[item.id]?.singleLinePreview {
      return cached
    }
    return Self.makeSingleLinePreview(item.content)
  }

  func immediateCandidates(endingWith lastChar: Character) -> [ActiveExpansionCandidate] {
    immediateBuckets[Self.bucketKey(for: lastChar)] ?? []
  }

  func delimiterCandidates(endingWith lastChar: Character) -> [ActiveExpansionCandidate] {
    delimiterBuckets[Self.bucketKey(for: lastChar)] ?? []
  }

  nonisolated static func bucketKey(for char: Character) -> Character {
    if let ascii = char.asciiValue {
      if ascii >= 65 && ascii <= 90 {
        return Character(UnicodeScalar(ascii + 32))
      }
      return char
    }
    return char.lowercased().last ?? char
  }

  nonisolated static func makeSingleLinePreview(_ raw: String, maxChars: Int = 140) -> String {
    guard !raw.isEmpty else { return "" }
    let prefix = raw.shortened(to: maxChars * 3)
    var out = ""
    out.reserveCapacity(min(prefix.count, maxChars))
    var pendingSpace = false
    var count = 0

    for ch in prefix {
      if ch.isWhitespace || ch.isNewline {
        if !out.isEmpty {
          pendingSpace = true
        }
      } else {
        if pendingSpace {
          out.append(" ")
          count += 1
          pendingSpace = false
          if count >= maxChars { break }
        }
        out.append(ch)
        count += 1
        if count >= maxChars { break }
      }
    }
    return out
  }

  func items(
    for scope: SnippetStudioScope,
    searchQuery: String = "",
    searchAllCollectionsWhenQuerying: Bool = true
  ) -> [SnippetItem] {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedScope: SnippetStudioScope = (!trimmed.isEmpty && searchAllCollectionsWhenQuerying) ? .all : scope
    let base: [SnippetItem]
    switch resolvedScope {
    case .all:
      base = items
    case .activeTriggers:
      base = activeExpansionItems
    case .collection(let collectionId):
      base = items.filter { $0.collectionId == collectionId }
    }
    return filterAndRank(base, query: trimmed)
  }

  func items(in collectionId: UUID?, searchQuery: String = "") -> [SnippetItem] {
    let scope: SnippetStudioScope = collectionId.map { .collection($0) } ?? .all
    return items(for: scope, searchQuery: searchQuery, searchAllCollectionsWhenQuerying: false)
  }

  var filteredPopupItems: [SnippetItem] {
    let enabledCollectionIds = Set(collections.filter(\.isEnabled).map(\.id))
    let base: [SnippetItem]
    if let selectedCol = selectedPopupCollectionId, enabledCollectionIds.contains(selectedCol) {
      base = items.filter { $0.collectionId == selectedCol && $0.isEnabled }
    } else {
      base = items.filter { $0.isEnabled && enabledCollectionIds.contains($0.collectionId) }
    }
    return filterAndRank(base, query: popupSearchQuery)
  }

  private func filterAndRank(_ candidates: [SnippetItem], query: String) -> [SnippetItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      // `items` and `activeExpansionItems` are already deterministically sorted by
      // effectiveAbbreviation (A→Z) first, followed by manual snippets by displayTitle (A→Z).
      return candidates
    }

    let foldedQuery = trimmed.foldingVietnameseDiacritics
    let queryTokens = foldedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !queryTokens.isEmpty else { return candidates }

    var scored: [(item: SnippetItem, score: Int)] = []
    scored.reserveCapacity(min(candidates.count, 128))

    for item in candidates {
      guard let idx = searchIndex[item.id] else { continue }

      // All query tokens must appear somewhere across (abbreviation, name, collectionName, content)
      let allMatch = queryTokens.allSatisfy { token in
        idx.foldedAbbreviation.contains(token)
          || idx.strippedFoldedAbbreviation.contains(token)
          || idx.foldedName.contains(token)
          || idx.foldedCollectionName.contains(token)
          || idx.foldedContent.contains(token)
      }
      guard allMatch else { continue }

      var score = 0
      if idx.foldedAbbreviation == foldedQuery {
        score += 2_000
      } else if !idx.strippedFoldedAbbreviation.isEmpty && idx.strippedFoldedAbbreviation == foldedQuery {
        score += 1_650
      } else if idx.foldedAbbreviation.hasPrefix(foldedQuery)
                  || (!idx.strippedFoldedAbbreviation.isEmpty && idx.strippedFoldedAbbreviation.hasPrefix(foldedQuery)) {
        score += 1_100
      } else if idx.foldedAbbreviation.contains(foldedQuery) {
        score += 650
      }

      if idx.foldedName == foldedQuery {
        score += 900
      } else if idx.foldedName.hasPrefix(foldedQuery) {
        score += 550
      } else if idx.foldedName.contains(foldedQuery) {
        score += 320
      }

      if idx.foldedCollectionName.contains(foldedQuery) {
        score += 200
      }
      if idx.foldedContent.contains(foldedQuery) {
        score += 120
      }
      if activeExpansionItemIds.contains(item.id) {
        score += 40
      }
      score += min(item.usageCount, 30)
      scored.append((item, score))
    }

    scored.sort { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return Self.compareItemsForDisplay(lhs.item, rhs.item, colMap: allCollections)
    }
    return scored.map(\.item)
  }

  func ensureValidPopupSelection() {
    let currentList = filteredPopupItems
    guard !currentList.isEmpty else {
      selectedPopupItemId = nil
      return
    }
    if let selected = selectedPopupItemId, currentList.contains(where: { $0.id == selected }) {
      return
    }
    selectedPopupItemId = currentList.first?.id
  }

  func highlightNextInPopup(allowCycle: Bool = false) {
    let list = filteredPopupItems
    guard !list.isEmpty else { return }
    guard let currentId = selectedPopupItemId,
          let idx = list.firstIndex(where: { $0.id == currentId }) else {
      selectedPopupItemId = list.first?.id
      return
    }
    if idx + 1 < list.count {
      selectedPopupItemId = list[idx + 1].id
    } else if allowCycle {
      selectedPopupItemId = list.first?.id
    }
  }

  func highlightPreviousInPopup() {
    let list = filteredPopupItems
    guard !list.isEmpty else { return }
    guard let currentId = selectedPopupItemId,
          let idx = list.firstIndex(where: { $0.id == currentId }) else {
      selectedPopupItemId = list.first?.id
      return
    }
    if idx > 0 {
      selectedPopupItemId = list[idx - 1].id
    }
  }

  func highlightFirstInPopup() {
    selectedPopupItemId = filteredPopupItems.first?.id
  }

  func highlightLastInPopup() {
    selectedPopupItemId = filteredPopupItems.last?.id
  }

  // MARK: - CRUD Operations

  @discardableResult
  func createCollection(
    name: String,
    icon: String = "folder.fill",
    keywordPrefix: String = "",
    keywordSuffix: String = "",
    isEnabled: Bool = true
  ) -> SnippetCollection {
    let nextOrder = (collections.map(\.sortOrder).max() ?? -1) + 1
    let col = SnippetCollection(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bộ gõ tắt mới" : name,
      icon: icon,
      isEnabled: isEnabled,
      keywordPrefix: keywordPrefix,
      keywordSuffix: keywordSuffix,
      sortOrder: nextOrder,
      updatedAt: Date.now,
      isDeleted: false
    )
    allCollections[col.id] = col
    rebuildCaches()
    scheduleSaveAndSync()
    return col
  }

  func updateCollection(_ updated: SnippetCollection) {
    var copy = updated
    copy.updatedAt = Date.now
    allCollections[copy.id] = copy
    rebuildCaches()
    scheduleSaveAndSync()
  }

  func setCollectionEnabled(_ id: UUID, isEnabled: Bool) {
    guard var col = allCollections[id] else { return }
    col.isEnabled = isEnabled
    col.updatedAt = Date.now
    allCollections[id] = col
    rebuildCaches()
    scheduleSaveAndSync()
  }

  func deleteCollection(_ id: UUID) {
    let now = Date.now
    if var col = allCollections[id] {
      col.isDeleted = true
      col.updatedAt = now
      allCollections[id] = col
    }
    for (itemId, var item) in allItems where item.collectionId == id && !item.isDeleted {
      item.isDeleted = true
      item.updatedAt = now
      allItems[itemId] = item
    }
    ensureDefaultCollectionIfNeeded(persist: false)
    rebuildCaches()
    scheduleSaveAndSync()
  }

  func moveCollections(fromOffsets source: IndexSet, toOffset destination: Int) {
    var reordered = collections
    reordered.move(fromOffsets: source, toOffset: destination)
    let now = Date.now
    for (idx, var col) in reordered.enumerated() {
      col.sortOrder = idx
      col.updatedAt = now
      allCollections[col.id] = col
    }
    rebuildCaches()
    scheduleSaveAndSync()
  }

  @discardableResult
  func createItem(
    in collectionId: UUID? = nil,
    name: String = "",
    abbreviation: String = "",
    content: String = "",
    contentMode: SnippetContentMode = .plainText,
    triggerMode: SnippetTriggerMode = .immediate,
    caseMode: SnippetCaseMode = .ignoreCase,
    wholeWord: Bool = false,
    rtfData: Data? = nil,
    htmlData: Data? = nil,
    imagePNGData: Data? = nil
  ) -> SnippetItem {
    let targetColId = collectionId ?? collections.first?.id ?? ensureDefaultCollectionIfNeeded(persist: false).id
    let cleanAbbr = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTrigger: SnippetTriggerMode = cleanAbbr.isEmpty ? .manualOnly : triggerMode
    let newItem = SnippetItem(
      collectionId: targetColId,
      name: name,
      abbreviation: cleanAbbr,
      content: content,
      rtfData: rtfData,
      htmlData: htmlData,
      imagePNGData: imagePNGData,
      contentMode: contentMode,
      triggerMode: resolvedTrigger,
      caseMode: caseMode,
      wholeWord: wholeWord,
      isEnabled: true,
      usageCount: 0,
      updatedAt: Date.now,
      isDeleted: false
    )
    allItems[newItem.id] = newItem
    rebuildCaches()
    scheduleSaveAndSync()
    return newItem
  }

  func updateItem(_ updated: SnippetItem) {
    var copy = updated
    copy.abbreviation = copy.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
    if copy.abbreviation.isEmpty && copy.triggerMode != .manualOnly {
      copy.triggerMode = .manualOnly
    }
    copy.updatedAt = Date.now

    let previous = allItems[copy.id]
    allItems[copy.id] = copy

    // Fast O(1) incremental path when only body/payload fields changed (e.g. typing in Studio TextEditor)
    if let prev = previous,
       !prev.isDeleted,
       !copy.isDeleted,
       prev.collectionId == copy.collectionId,
       prev.abbreviation == copy.abbreviation,
       prev.name == copy.name,
       prev.isEnabled == copy.isEnabled,
       prev.triggerMode == copy.triggerMode,
       prev.caseMode == copy.caseMode,
       prev.wholeWord == copy.wholeWord,
       let col = allCollections[copy.collectionId],
       let itemIdx = items.firstIndex(where: { $0.id == copy.id }) {
      items[itemIdx] = copy
      if let actIdx = activeExpansionItems.firstIndex(where: { $0.id == copy.id }) {
        activeExpansionItems[actIdx] = copy
      }
      let effAbbr = copy.effectiveAbbreviation(in: col)
      searchIndex[copy.id] = Self.buildSearchEntry(for: copy, collection: col, effectiveAbbreviation: effAbbr)
      if let candIdx = activeExpansionCandidates.firstIndex(where: { $0.item.id == copy.id }) {
        activeExpansionCandidates[candIdx].item = copy
        rebuildExpansionBuckets(from: activeExpansionCandidates)
      }
      scheduleSaveAndSync()
      return
    }

    rebuildCaches()
    scheduleSaveAndSync()
  }

  @discardableResult
  func duplicateItem(_ id: UUID) -> SnippetItem? {
    guard var copy = item(for: id) else { return nil }
    copy.id = UUID()
    copy.name = copy.displayTitle + " (Bản sao)"
    if !copy.abbreviation.isEmpty {
      copy.abbreviation += "2"
    }
    copy.usageCount = 0
    copy.lastUsedAt = nil
    copy.updatedAt = Date.now
    allItems[copy.id] = copy
    rebuildCaches()
    scheduleSaveAndSync()
    return copy
  }

  func deleteItem(_ id: UUID) {
    guard var target = allItems[id] else { return }
    target.isDeleted = true
    target.updatedAt = Date.now
    allItems[id] = target
    rebuildCaches()
    scheduleSaveAndSync()
  }

  func recordUsage(for itemId: UUID) {
    guard var target = allItems[itemId], !target.isDeleted else { return }
    let now = Date.now
    target.usageCount += 1
    target.lastUsedAt = now
    target.updatedAt = now
    allItems[itemId] = target
    if let idx = items.firstIndex(where: { $0.id == itemId }) {
      items[idx] = target
    }
    if let actIdx = activeExpansionItems.firstIndex(where: { $0.id == itemId }) {
      activeExpansionItems[actIdx] = target
    }
    if var existingEntry = searchIndex[itemId] {
      existingEntry.sourceItemUpdatedAt = now
      searchIndex[itemId] = existingEntry
    }
    if let candIdx = activeExpansionCandidates.firstIndex(where: { $0.item.id == itemId }) {
      activeExpansionCandidates[candIdx].item = target
      rebuildExpansionBuckets(from: activeExpansionCandidates)
    }
    scheduleSaveAndSync()
  }

  @discardableResult
  func createSnippet(
    from historyItem: HistoryItem,
    name: String,
    abbreviation: String,
    collectionId: UUID? = nil
  ) -> SnippetItem {
    if let img = historyItem.image,
       let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
      return createItem(
        in: collectionId,
        name: name.isEmpty ? "Hình ảnh đã lưu" : name,
        abbreviation: abbreviation,
        content: historyItem.title,
        contentMode: .image,
        triggerMode: abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .manualOnly : .immediate,
        imagePNGData: png
      )
    }

    let plain = historyItem.text ?? historyItem.title
    let rtf = historyItem.rtfData
    let html = historyItem.htmlData
    let mode: SnippetContentMode = (rtf != nil) ? .richText : .plainText

    return createItem(
      in: collectionId,
      name: name,
      abbreviation: abbreviation,
      content: plain,
      contentMode: mode,
      triggerMode: abbreviation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .manualOnly : .immediate,
      rtfData: rtf,
      htmlData: html
    )
  }

  // MARK: - Deduplicated Batch Import & Store Sanitization

  func importPayload(_ payload: SnippetImportPayload) -> SnippetImportSummary {
    var colsAdded = 0
    var itemsAdded = 0
    var itemsUpdated = 0
    let now = Date.now

    for importedCol in payload.collections {
      let trimmedColName = importedCol.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let liveCollections = allCollections.values.filter { !$0.isDeleted }
      let targetCol: SnippetCollection
      if let existing = liveCollections.first(where: {
        $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedColName) == .orderedSame
          && ($0.keywordPrefix == importedCol.keywordPrefix || $0.keywordPrefix.isEmpty || importedCol.keywordPrefix.isEmpty)
          && ($0.keywordSuffix == importedCol.keywordSuffix || $0.keywordSuffix.isEmpty || importedCol.keywordSuffix.isEmpty)
      }) {
        var updatedCol = existing
        if updatedCol.keywordPrefix.isEmpty && !importedCol.keywordPrefix.isEmpty {
          updatedCol.keywordPrefix = importedCol.keywordPrefix
        }
        if updatedCol.keywordSuffix.isEmpty && !importedCol.keywordSuffix.isEmpty {
          updatedCol.keywordSuffix = importedCol.keywordSuffix
        }
        updatedCol.updatedAt = now
        allCollections[updatedCol.id] = updatedCol
        targetCol = updatedCol
      } else {
        let nextOrder = (liveCollections.map(\.sortOrder).max() ?? -1) + 1
        let created = SnippetCollection(
          name: trimmedColName.isEmpty ? "Imported" : trimmedColName,
          icon: importedCol.icon,
          isEnabled: importedCol.isEnabled,
          keywordPrefix: importedCol.keywordPrefix,
          keywordSuffix: importedCol.keywordSuffix,
          sortOrder: nextOrder,
          updatedAt: now,
          isDeleted: false
        )
        allCollections[created.id] = created
        targetCol = created
        colsAdded += 1
      }

      let existingInCol = allItems.values.filter { !$0.isDeleted && $0.collectionId == targetCol.id }
      var byAbbr: [String: SnippetItem] = [:]
      var byNameWhenNoAbbr: [String: SnippetItem] = [:]
      for ex in existingInCol {
        if !ex.abbreviation.isEmpty {
          byAbbr[ex.abbreviation.lowercased()] = ex
        } else if !ex.name.isEmpty {
          byNameWhenNoAbbr[ex.name.lowercased()] = ex
        }
      }

      for entry in importedCol.items {
        let abbr = entry.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedExisting: SnippetItem? = !abbr.isEmpty
          ? byAbbr[abbr.lowercased()]
          : byNameWhenNoAbbr[entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]

        if var current = matchedExisting {
          current.name = entry.name.isEmpty ? current.name : entry.name
          current.content = entry.content
          current.contentMode = entry.contentMode
          current.triggerMode = abbr.isEmpty ? .manualOnly : entry.triggerMode
          current.caseMode = entry.caseMode
          current.wholeWord = entry.wholeWord
          current.usageCount = max(current.usageCount, entry.usageCount)
          current.updatedAt = now
          allItems[current.id] = current
          itemsUpdated += 1
        } else {
          let newItem = SnippetItem(
            collectionId: targetCol.id,
            name: entry.name,
            abbreviation: abbr,
            content: entry.content,
            contentMode: entry.contentMode,
            triggerMode: abbr.isEmpty ? .manualOnly : entry.triggerMode,
            caseMode: entry.caseMode,
            wholeWord: entry.wholeWord,
            isEnabled: entry.isEnabled,
            usageCount: entry.usageCount,
            updatedAt: now,
            isDeleted: false
          )
          allItems[newItem.id] = newItem
          if !abbr.isEmpty {
            byAbbr[abbr.lowercased()] = newItem
          } else if !newItem.name.isEmpty {
            byNameWhenNoAbbr[newItem.name.lowercased()] = newItem
          }
          itemsAdded += 1
        }
      }
    }

    let shouldSanitizeDefaultSet = !Defaults[.didSanitizeTypinatorDefaultSet]
    let cleanupSummary = Self.deduplicateAndSanitize(
      collections: &allCollections,
      items: &allItems,
      sanitizeTypinatorDefaultSet: shouldSanitizeDefaultSet
    )
    if shouldSanitizeDefaultSet && cleanupSummary.didFindTypinatorDefaultSet {
      Defaults[.didSanitizeTypinatorDefaultSet] = true
    }

    rebuildCaches()
    scheduleSaveAndSync()
    return SnippetImportSummary(
      collectionsImported: colsAdded,
      snippetsImported: itemsAdded,
      snippetsUpdated: itemsUpdated,
      sourceDescription: payload.sourceDescription
    )
  }

  @discardableResult
  func deduplicateAndSanitizeNow() -> SnippetDeduplicationSummary {
    let summary = Self.deduplicateAndSanitize(
      collections: &allCollections,
      items: &allItems,
      sanitizeTypinatorDefaultSet: false
    )
    if summary.didMutate {
      rebuildCaches()
      scheduleSaveAndSync()
    }
    return summary
  }

  /// Deterministically merges duplicate collections (e.g., 3x Typinator `Default Set` or duplicate imports across Macs),
  /// deduplicates identical active items within each collection, and optionally performs one-time sanitization of
  /// Typinator's factory demo `Default Set` (`dt` → `{{isodate}}`).
  nonisolated static func deduplicateAndSanitize(
    collections: inout [UUID: SnippetCollection],
    items: inout [UUID: SnippetItem],
    sanitizeTypinatorDefaultSet: Bool
  ) -> SnippetDeduplicationSummary {
    let now = Date.now
    var didMutate = false
    var mergedColsCount = 0
    var removedDupItemsCount = 0
    var didFindDefaultSet = false

    // 1. Coalesce active collections sharing the same canonical `(name, keywordPrefix, keywordSuffix)`
    var groupsByKey: [String: [SnippetCollection]] = [:]
    for col in collections.values where !col.isDeleted {
      let cleanName = col.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let key = "\(cleanName)|\(col.keywordPrefix)|\(col.keywordSuffix)"
      groupsByKey[key, default: []].append(col)
    }

    var movedFromDuplicateCollectionIds = Set<UUID>()
    for (_, group) in groupsByKey where group.count > 1 {
      let sortedGroup = group.sorted { lhs, rhs in
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      var winner = sortedGroup[0]
      let minOrder = sortedGroup.map(\.sortOrder).min() ?? winner.sortOrder
      if winner.sortOrder != minOrder {
        winner.sortOrder = minOrder
        winner.updatedAt = now
        collections[winner.id] = winner
      }

      for var dupCol in sortedGroup.dropFirst() {
        movedFromDuplicateCollectionIds.insert(dupCol.id)
        for (itemId, var item) in items where !item.isDeleted && item.collectionId == dupCol.id {
          item.collectionId = winner.id
          item.updatedAt = now
          items[itemId] = item
        }
        dupCol.isDeleted = true
        dupCol.updatedAt = now
        collections[dupCol.id] = dupCol
        mergedColsCount += 1
        didMutate = true
      }
    }

    // 2. Deduplicate active items within each active collection
    var activeItemsByCol: [UUID: [SnippetItem]] = [:]
    for item in items.values where !item.isDeleted && collections[item.collectionId]?.isDeleted == false {
      activeItemsByCol[item.collectionId, default: []].append(item)
    }

    for (colId, colItems) in activeItemsByCol where colItems.count > 1 {
      let ordered = colItems.sorted { lhs, rhs in
        if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled && !rhs.isEnabled }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
        return lhs.id.uuidString < rhs.id.uuidString
      }

      var winnerByAbbr: [String: UUID] = [:]
      var winnerByManualKey: [String: UUID] = [:]

      for candidate in ordered {
        let cleanAbbr = candidate.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanAbbr.isEmpty {
          let abbrKey = candidate.caseMode == .caseSensitive
            ? "cs:\(cleanAbbr)"
            : "ci:\(cleanAbbr.lowercased())"
          if let winId = winnerByAbbr[abbrKey], var winItem = items[winId] {
            let sameContent = winItem.content.trimmingCharacters(in: .whitespacesAndNewlines)
              == candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if sameContent || !movedFromDuplicateCollectionIds.isEmpty {
              if candidate.usageCount > winItem.usageCount {
                winItem.usageCount = candidate.usageCount
                winItem.updatedAt = now
                items[winId] = winItem
              }
              var dup = candidate
              dup.isDeleted = true
              dup.updatedAt = now
              items[dup.id] = dup
              removedDupItemsCount += 1
              didMutate = true
            }
          } else {
            winnerByAbbr[abbrKey] = candidate.id
          }
        } else {
          let cleanName = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          guard !cleanName.isEmpty || !candidate.content.isEmpty else { continue }
          let manualKey = "\(colId.uuidString)|\(cleanName)|\(candidate.content)"
          if let winId = winnerByManualKey[manualKey], var winItem = items[winId] {
            if candidate.usageCount > winItem.usageCount {
              winItem.usageCount = candidate.usageCount
              winItem.updatedAt = now
              items[winId] = winItem
            }
            var dup = candidate
            dup.isDeleted = true
            dup.updatedAt = now
            items[dup.id] = dup
            removedDupItemsCount += 1
            didMutate = true
          } else {
            winnerByManualKey[manualKey] = candidate.id
          }
        }
      }
    }

    // 3. Sanitize Typinator's bundled demo `Default Set` (`dt` → `{{isodate}}`) so short demo words
    //    do not unexpectedly expand inside normal Vietnamese/English typing (`sdt` → `s2026-11-03`).
    for (colId, var col) in collections where !col.isDeleted {
      let cleanColName = col.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard cleanColName.caseInsensitiveCompare("Default Set") == .orderedSame else { continue }
      didFindDefaultSet = true

      if sanitizeTypinatorDefaultSet {
        if col.isEnabled {
          col.isEnabled = false
          col.updatedAt = now
          collections[colId] = col
          didMutate = true
        }
        for (itemId, var item) in items where !item.isDeleted && item.collectionId == colId {
          let cleanAbbr = item.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
          if !cleanAbbr.isEmpty && cleanAbbr.allSatisfy(\.isLetter) {
            if !item.wholeWord || item.triggerMode == .immediate {
              item.wholeWord = true
              if item.triggerMode == .immediate {
                item.triggerMode = .afterDelimiter
              }
              item.updatedAt = now
              items[itemId] = item
              didMutate = true
            }
          }
        }
      }
    }

    return SnippetDeduplicationSummary(
      didMutate: didMutate,
      mergedCollectionsCount: mergedColsCount,
      removedDuplicateItemsCount: removedDupItemsCount,
      didFindTypinatorDefaultSet: didFindDefaultSet
    )
  }

  // MARK: - Internal Cache & Search Index Builder

  @discardableResult
  private func ensureDefaultCollectionIfNeeded(persist: Bool) -> SnippetCollection {
    if let first = allCollections.values.first(where: { !$0.isDeleted }) {
      return first
    }
    let def = SnippetCollection(
      name: "Gõ tắt của tôi",
      icon: "bolt.horizontal.fill",
      isEnabled: true,
      sortOrder: 0,
      updatedAt: Date.now,
      isDeleted: false
    )
    allCollections[def.id] = def
    if persist {
      scheduleSaveAndSync()
    }
    return def
  }

  private nonisolated static func compareItemsForDisplay(
    _ lhs: SnippetItem,
    _ rhs: SnippetItem,
    colMap: [UUID: SnippetCollection]
  ) -> Bool {
    let lAbbr = lhs.effectiveAbbreviation(in: colMap[lhs.collectionId])
    let rAbbr = rhs.effectiveAbbreviation(in: colMap[rhs.collectionId])
    // Always place snippets with an actual abbreviation ahead of manual-only templates (`—`)
    if lAbbr.isEmpty != rAbbr.isEmpty {
      return !lAbbr.isEmpty
    }
    if !lAbbr.isEmpty {
      let abbrCmp = lAbbr.localizedStandardCompare(rAbbr)
      if abbrCmp != .orderedSame {
        return abbrCmp == .orderedAscending
      }
    }
    let titleCmp = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
    if titleCmp != .orderedSame {
      return titleCmp == .orderedAscending
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private nonisolated static func buildSearchEntry(
    for item: SnippetItem,
    collection: SnippetCollection,
    effectiveAbbreviation: String
  ) -> SnippetSearchEntry {
    let contentSample = item.content.shortened(to: 8_192)
    let foldedAbbr = effectiveAbbreviation.foldingVietnameseDiacritics
    let strippedAbbr = String(foldedAbbr.drop(while: { !$0.isLetter && !$0.isNumber }))
    return SnippetSearchEntry(
      sourceItemUpdatedAt: item.updatedAt,
      sourceCollectionUpdatedAt: collection.updatedAt,
      foldedName: item.displayTitle.foldingVietnameseDiacritics,
      foldedAbbreviation: foldedAbbr,
      strippedFoldedAbbreviation: strippedAbbr,
      foldedCollectionName: collection.name.foldingVietnameseDiacritics,
      foldedContent: contentSample.foldingVietnameseDiacritics,
      singleLinePreview: makeSingleLinePreview(item.content)
    )
  }

  private func rebuildExpansionBuckets(from orderedCandidates: [ActiveExpansionCandidate]) {
    var imm: [Character: [ActiveExpansionCandidate]] = [:]
    var del: [Character: [ActiveExpansionCandidate]] = [:]
    for cand in orderedCandidates {
      guard let lastChar = cand.lowercasedAbbreviation.last else { continue }
      let key = Self.bucketKey(for: lastChar)
      switch cand.item.triggerMode {
      case .immediate:
        imm[key, default: []].append(cand)
      case .afterDelimiter:
        del[key, default: []].append(cand)
      case .manualOnly:
        break
      }
    }
    self.immediateBuckets = imm
    self.delimiterBuckets = del
  }

  private func rebuildCaches() {
    let activeCols = allCollections.values
      .filter { !$0.isDeleted }
      .sorted { lhs, rhs in
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
    self.collections = activeCols

    let colMap = Dictionary(uniqueKeysWithValues: activeCols.map { ($0.id, $0) })
    let activeItems = allItems.values
      .filter { !$0.isDeleted && colMap[$0.collectionId] != nil }
      .sorted { lhs, rhs in
        Self.compareItemsForDisplay(lhs, rhs, colMap: colMap)
      }
    self.items = activeItems

    let previousIndex = self.searchIndex
    var newSearchIndex: [UUID: SnippetSearchEntry] = [:]
    newSearchIndex.reserveCapacity(activeItems.count)

    var counts: [UUID: Int] = [:]
    counts.reserveCapacity(activeCols.count)
    var enabledCounts: [UUID: Int] = [:]
    enabledCounts.reserveCapacity(activeCols.count)
    var totalPopupEnabled = 0

    var newCandidates: [ActiveExpansionCandidate] = []
    var orderedActiveItems: [SnippetItem] = []
    var activeIds = Set<UUID>()
    var longest = 16

    for item in activeItems {
      guard let col = colMap[item.collectionId] else { continue }
      counts[col.id, default: 0] += 1
      if item.isEnabled {
        enabledCounts[col.id, default: 0] += 1
        if col.isEnabled {
          totalPopupEnabled += 1
        }
      }
      let effAbbr = item.effectiveAbbreviation(in: col)

      // Reuse pre-folded Vietnamese search entry if neither item nor parent collection changed
      if let existing = previousIndex[item.id],
         existing.sourceItemUpdatedAt == item.updatedAt,
         existing.sourceCollectionUpdatedAt == col.updatedAt {
        newSearchIndex[item.id] = existing
      } else {
        newSearchIndex[item.id] = Self.buildSearchEntry(for: item, collection: col, effectiveAbbreviation: effAbbr)
      }

      if col.isEnabled && item.isEnabled && item.triggerMode != .manualOnly && !effAbbr.isEmpty {
        longest = max(longest, effAbbr.count)
        orderedActiveItems.append(item)
        activeIds.insert(item.id)
        newCandidates.append(
          ActiveExpansionCandidate(
            item: item,
            collection: col,
            effectiveAbbreviation: effAbbr,
            lowercasedAbbreviation: effAbbr.lowercased()
          )
        )
      }
    }

    // Priority order for keyboard matching: longer abbreviation first so `;p001` wins over `;p0`, then collection sortOrder
    newCandidates.sort { lhs, rhs in
      if lhs.effectiveAbbreviation.count != rhs.effectiveAbbreviation.count {
        return lhs.effectiveAbbreviation.count > rhs.effectiveAbbreviation.count
      }
      return lhs.collection.sortOrder < rhs.collection.sortOrder
    }

    self.itemCountsByCollection = counts
    self.enabledItemCountsByCollection = enabledCounts
    self.totalPopupEnabledItemCount = totalPopupEnabled
    self.searchIndex = newSearchIndex
    self.activeExpansionItems = orderedActiveItems
    self.activeExpansionItemIds = activeIds
    self.activeExpansionCandidates = newCandidates
    self.maxAbbreviationLength = min(max(longest + 2, 24), 128)
    rebuildExpansionBuckets(from: newCandidates)

    if let selectedCol = selectedPopupCollectionId, colMap[selectedCol]?.isEnabled != true {
      selectedPopupCollectionId = nil
    } else {
      ensureValidPopupSelection()
    }
  }

  // MARK: - Local Disk Persistence & Two-Way Google Drive Sync

  private func loadFromLocalDisk() {
    let url = Self.localStoreURL
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url) else {
      return
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let db = try? decoder.decode(SnippetSyncDatabase.self, from: data) else {
      return
    }
    self.allCollections = db.collections
    self.allItems = db.items
  }

  private func scheduleSaveAndSync() {
    saveTask?.cancel()
    let snapshotCollections = allCollections
    let snapshotItems = allItems

    saveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }

      await Self.writeLocalSnapshot(collections: snapshotCollections, items: snapshotItems)
      if Defaults[.cloudSyncEnabled] {
        await self?.syncWithGoogleDrive()
      }
    }
  }

  private nonisolated static func writeLocalSnapshot(
    collections: [UUID: SnippetCollection],
    items: [UUID: SnippetItem]
  ) async {
    await Task.detached(priority: .utility) {
      let url = Self.localStoreURL
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let db = SnippetSyncDatabase(
        version: 1,
        updatedAt: Date.now,
        deviceName: Host.current().localizedName ?? "Mac",
        collections: collections,
        items: items
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      if let data = try? encoder.encode(db) {
        try? data.write(to: url, options: [.atomic])
      }
    }.value
  }

  func syncWithGoogleDrive() async {
    guard Defaults[.cloudSyncEnabled] else { return }
    var folderPath = Defaults[.cloudSyncFolderPath].trimmingCharacters(in: .whitespacesAndNewlines)
    if folderPath.isEmpty {
      folderPath = (CloudSyncManager.shared.autoDetectGoogleDriveIfNeeded() ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !folderPath.isEmpty, !isSyncingSnippets else { return }

    isSyncingSnippets = true
    defer { isSyncingSnippets = false }

    let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
    let primaryURL = folderURL.appendingPathComponent(Self.cloudFileName, isDirectory: false)
    let localCols = allCollections
    let localItems = allItems
    let encryptionEnabled = Defaults[.cloudSyncEncryptionEnabled]
    let passphrase = Defaults[.cloudSyncPassphrase].trimmingCharacters(in: .whitespacesAndNewlines)
    let deviceName = Host.current().localizedName ?? "Mac"
    let shouldSanitizeDefaultSet = !Defaults[.didSanitizeTypinatorDefaultSet]

    let mergedOutcome = await Task.detached(priority: .utility) { () -> (SnippetSyncDatabase, Bool, Bool, Date?)? in
      try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

      let key: SymmetricKey? = (encryptionEnabled && !passphrase.isEmpty)
        ? SymmetricKey(data: SHA256.hash(data: Data(("MaccySync-AES256-v1:" + passphrase).utf8)))
        : nil

      var mergedCols = localCols
      var mergedItems = localItems
      var localChangedFromRemote = false

      // Read primary + any Google Drive conflict files ("maccy-snippets (1).json", etc.)
      var candidateURLs: [URL] = [primaryURL]
      if let dirFiles = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
        for f in dirFiles where f.lastPathComponent != Self.cloudFileName
            && f.lastPathComponent.lowercased().hasPrefix("maccy-snippets")
            && f.pathExtension.lowercased() == "json" {
          candidateURLs.append(f)
        }
      }

      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601

      var primaryRemoteDB: SnippetSyncDatabase?

      for url in candidateURLs where FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let existingSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard let rawData = try? Data(contentsOf: url),
              let remoteDB = try? decoder.decode(SnippetSyncDatabase.self, from: rawData) else {
          // CRITICAL SAFETY GUARD: If the primary cloud file exists and is non-empty, but reading or decoding
          // failed (e.g. Google Drive File Provider streaming timeout while offline), abort this sync pass
          // instead of treating `primaryRemoteDB` as nil and overwriting remote data!
          if url == primaryURL && existingSize > 2 {
            return nil
          }
          continue
        }
        if url == primaryURL {
          primaryRemoteDB = remoteDB
        }

        for (colId, remoteCol) in remoteDB.collections {
          if let existing = mergedCols[colId] {
            if remoteCol.updatedAt > existing.updatedAt {
              mergedCols[colId] = remoteCol
              localChangedFromRemote = true
            }
          } else {
            mergedCols[colId] = remoteCol
            localChangedFromRemote = true
          }
        }

        for (itemId, remoteItem) in remoteDB.items {
          guard let decodedRemote = Self.decryptCloudSnippetItem(remoteItem, key: key) else {
            continue
          }
          if let existing = mergedItems[itemId] {
            if decodedRemote.updatedAt > existing.updatedAt {
              mergedItems[itemId] = decodedRemote
              localChangedFromRemote = true
            }
          } else {
            mergedItems[itemId] = decodedRemote
            localChangedFromRemote = true
          }
        }
      }

      // Deduplicate any same-named collections imported independently across Macs + sanitize demo Default Set
      let dedupSummary = Self.deduplicateAndSanitize(
        collections: &mergedCols,
        items: &mergedItems,
        sanitizeTypinatorDefaultSet: shouldSanitizeDefaultSet
      )
      if dedupSummary.didMutate {
        localChangedFromRemote = true
      }

      // Prune tombstones older than 30 days
      let tombstoneCutoff = Date.now.addingTimeInterval(-30 * 86_400)
      mergedCols = mergedCols.filter { !$0.value.isDeleted || $0.value.updatedAt >= tombstoneCutoff }
      mergedItems = mergedItems.filter { !$0.value.isDeleted || $0.value.updatedAt >= tombstoneCutoff }

      // Determine whether Google Drive file actually needs to be written (avoids two-Mac ping-pong uploads)
      var remoteNeedsWrite = (primaryRemoteDB == nil) || (candidateURLs.count > 1) || dedupSummary.didMutate
      if !remoteNeedsWrite, let primary = primaryRemoteDB {
        if primary.collections.count != mergedCols.count || primary.items.count != mergedItems.count {
          remoteNeedsWrite = true
        } else {
          for (colId, col) in mergedCols where primary.collections[colId]?.updatedAt != col.updatedAt {
            remoteNeedsWrite = true
            break
          }
          if !remoteNeedsWrite {
            let shouldEncrypt = (key != nil)
            for (itemId, item) in mergedItems {
              guard let remItem = primary.items[itemId] else {
                remoteNeedsWrite = true
                break
              }
              if remItem.updatedAt != item.updatedAt || (remItem.isPayloadEncrypted == true) != shouldEncrypt {
                remoteNeedsWrite = true
                break
              }
            }
          }
        }
      }

      if remoteNeedsWrite {
        var cloudItems: [UUID: SnippetItem] = [:]
        cloudItems.reserveCapacity(mergedItems.count)
        for (id, plainItem) in mergedItems {
          cloudItems[id] = Self.prepareCloudSnippetItem(plainItem, key: key)
        }

        let outDB = SnippetSyncDatabase(
          version: 1,
          updatedAt: Date.now,
          deviceName: deviceName,
          collections: mergedCols,
          items: cloudItems
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(outDB) else {
          return nil
        }
        try? encoded.write(to: primaryURL, options: [.atomic])

        for conflictURL in candidateURLs.dropFirst() {
          try? FileManager.default.removeItem(at: conflictURL)
        }
      }

      let attrs = try? FileManager.default.attributesOfItem(atPath: primaryURL.path)
      let observedModDate = attrs?[.modificationDate] as? Date

      let plainMergedDB = SnippetSyncDatabase(
        version: 1,
        updatedAt: Date.now,
        deviceName: deviceName,
        collections: mergedCols,
        items: mergedItems
      )
      return (plainMergedDB, localChangedFromRemote, dedupSummary.didFindTypinatorDefaultSet, observedModDate)
    }.value

    if let (mergedPlainDB, changedFromRemote, didFindDefaultSet, modDate) = mergedOutcome {
      if shouldSanitizeDefaultSet && didFindDefaultSet {
        Defaults[.didSanitizeTypinatorDefaultSet] = true
      }
      if let modDate {
        self.lastObservedCloudModificationDate = modDate
      }
      if changedFromRemote {
        self.allCollections = mergedPlainDB.collections
        self.allItems = mergedPlainDB.items
        rebuildCaches()
        await Self.writeLocalSnapshot(collections: allCollections, items: allItems)
      }
      let activeCount = items.count
      lastSnippetSyncMessage = "Đã đồng bộ \(activeCount) gõ tắt qua Google Drive"
    }
  }

  private nonisolated static func prepareCloudSnippetItem(_ item: SnippetItem, key: SymmetricKey?) -> SnippetItem {
    var out = item
    guard let key else {
      out.isPayloadEncrypted = nil
      out.encryptedContent = nil
      return out
    }
    if let utf8 = item.content.data(using: .utf8),
       let box = try? AES.GCM.seal(utf8, using: key).combined {
      out.content = ""
      out.encryptedContent = box
      out.isPayloadEncrypted = true
    }
    return out
  }

  private nonisolated static func decryptCloudSnippetItem(_ item: SnippetItem, key: SymmetricKey?) -> SnippetItem? {
    var out = item
    if item.isPayloadEncrypted == true, let enc = item.encryptedContent {
      guard let key,
            let box = try? AES.GCM.SealedBox(combined: enc),
            let opened = try? AES.GCM.open(box, using: key),
            let text = String(data: opened, encoding: .utf8) else {
        return nil
      }
      out.content = text
      out.encryptedContent = nil
      out.isPayloadEncrypted = nil
    }
    return out
  }
}
