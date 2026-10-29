import AppKit
import CryptoKit
import Defaults
import Foundation
import Logging
import Observation

nonisolated struct ActiveExpansionCandidate: Sendable {
  var item: SnippetItem
  var collection: SnippetCollection
  var effectiveAbbreviation: String
  var lowercasedAbbreviation: String
}

private nonisolated struct SnippetSearchEntry: Sendable {
  var foldedName: String
  var foldedAbbreviation: String
  var foldedCollectionName: String
  var foldedContent: String
}

@Observable
@MainActor
class SnippetStore {
  static let shared = SnippetStore()

  private let logger = Logger(label: "org.p0deje.Maccy.Snippets")
  private nonisolated static let localFileName = "maccy-snippets-local.json"
  private nonisolated static let cloudFileName = "maccy-snippets.json"

  private var allCollections: [UUID: SnippetCollection] = [:]
  private var allItems: [UUID: SnippetItem] = [:]
  private var searchIndex: [UUID: SnippetSearchEntry] = [:]

  private(set) var collections: [SnippetCollection] = []
  private(set) var items: [SnippetItem] = []
  private(set) var activeExpansionCandidates: [ActiveExpansionCandidate] = []
  private(set) var maxAbbreviationLength: Int = 24

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
    ensureDefaultCollectionIfNeeded(persist: false)
    rebuildCaches()

    if Defaults[.cloudSyncEnabled] && !Defaults[.cloudSyncFolderPath].isEmpty {
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
    items.reduce(0) { $0 + ($1.collectionId == collectionId ? 1 : 0) }
  }

  func items(in collectionId: UUID?, searchQuery: String = "") -> [SnippetItem] {
    let base: [SnippetItem]
    if let collectionId {
      base = items.filter { $0.collectionId == collectionId }
    } else {
      base = items
    }
    return filterAndRank(base, query: searchQuery)
  }

  var filteredPopupItems: [SnippetItem] {
    let enabledCollectionIds = Set(collections.filter(\.isEnabled).map(\.id))
    let base: [SnippetItem]
    if let selectedCol = selectedPopupCollectionId {
      base = items.filter { $0.collectionId == selectedCol && $0.isEnabled }
    } else {
      // Show items from enabled collections PLUS manual-only collections when searching in viewer
      base = items.filter { item in
        guard item.isEnabled else { return false }
        if enabledCollectionIds.contains(item.collectionId) { return true }
        return !popupSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }
    return filterAndRank(base, query: popupSearchQuery)
  }

  private func filterAndRank(_ candidates: [SnippetItem], query: String) -> [SnippetItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return candidates.sorted { lhs, rhs in
        if lhs.usageCount != rhs.usageCount {
          return lhs.usageCount > rhs.usageCount
        }
        return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
      }
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
          || idx.foldedName.contains(token)
          || idx.foldedCollectionName.contains(token)
          || idx.foldedContent.contains(token)
      }
      guard allMatch else { continue }

      var score = 0
      if idx.foldedAbbreviation == foldedQuery {
        score += 1_000
      } else if idx.foldedAbbreviation.hasPrefix(foldedQuery) {
        score += 650
      } else if idx.foldedAbbreviation.contains(foldedQuery) {
        score += 400
      }

      if idx.foldedName == foldedQuery {
        score += 800
      } else if idx.foldedName.hasPrefix(foldedQuery) {
        score += 500
      } else if idx.foldedName.contains(foldedQuery) {
        score += 300
      }

      if idx.foldedContent.contains(foldedQuery) {
        score += 120
      }
      score += min(item.usageCount, 50)
      scored.append((item, score))
    }

    scored.sort { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.item.displayTitle.localizedStandardCompare(rhs.item.displayTitle) == .orderedAscending
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
    allItems[copy.id] = copy
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
    rebuildCaches()
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

  // MARK: - Deduplicated Batch Import (Alfred, Typinator, CSV, JSON, Starter Packs)

  func importPayload(_ payload: SnippetImportPayload) -> SnippetImportSummary {
    var colsAdded = 0
    var itemsAdded = 0
    var itemsUpdated = 0
    let now = Date.now

    for importedCol in payload.collections {
      let trimmedColName = importedCol.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let targetCol: SnippetCollection
      if let existing = collections.first(where: { $0.name.caseInsensitiveCompare(trimmedColName) == .orderedSame }) {
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
        let nextOrder = (allCollections.values.filter { !$0.isDeleted }.map(\.sortOrder).max() ?? -1) + 1
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

    rebuildCaches()
    scheduleSaveAndSync()
    return SnippetImportSummary(
      collectionsImported: colsAdded,
      snippetsImported: itemsAdded,
      snippetsUpdated: itemsUpdated,
      sourceDescription: payload.sourceDescription
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
        let lAbbr = lhs.effectiveAbbreviation(in: colMap[lhs.collectionId])
        let rAbbr = rhs.effectiveAbbreviation(in: colMap[rhs.collectionId])
        if !lAbbr.isEmpty && !rAbbr.isEmpty && lAbbr != rAbbr {
          return lAbbr.localizedStandardCompare(rAbbr) == .orderedAscending
        }
        return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
      }
    self.items = activeItems

    var newSearchIndex: [UUID: SnippetSearchEntry] = [:]
    newSearchIndex.reserveCapacity(activeItems.count)

    var newCandidates: [ActiveExpansionCandidate] = []
    var longest = 16

    for item in activeItems {
      guard let col = colMap[item.collectionId] else { continue }
      let effAbbr = item.effectiveAbbreviation(in: col)
      let contentSample = item.content.shortened(to: 8_192)
      newSearchIndex[item.id] = SnippetSearchEntry(
        foldedName: item.displayTitle.foldingVietnameseDiacritics,
        foldedAbbreviation: effAbbr.foldingVietnameseDiacritics,
        foldedCollectionName: col.name.foldingVietnameseDiacritics,
        foldedContent: contentSample.foldingVietnameseDiacritics
      )

      if col.isEnabled && item.isEnabled && item.triggerMode != .manualOnly && !effAbbr.isEmpty {
        longest = max(longest, effAbbr.count)
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

    // Priority order: longer abbreviation first so `;p001` wins over `;p0` if any, then collection sortOrder
    newCandidates.sort { lhs, rhs in
      if lhs.effectiveAbbreviation.count != rhs.effectiveAbbreviation.count {
        return lhs.effectiveAbbreviation.count > rhs.effectiveAbbreviation.count
      }
      return lhs.collection.sortOrder < rhs.collection.sortOrder
    }

    self.searchIndex = newSearchIndex
    self.activeExpansionCandidates = newCandidates
    self.maxAbbreviationLength = min(max(longest + 2, 24), 128)
    ensureValidPopupSelection()
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
      if Defaults[.cloudSyncEnabled] && !Defaults[.cloudSyncFolderPath].isEmpty {
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
    let folderPath = Defaults[.cloudSyncFolderPath].trimmingCharacters(in: .whitespacesAndNewlines)
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

    let mergedOutcome = await Task.detached(priority: .utility) { () -> (SnippetSyncDatabase, Bool)? in
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

      for url in candidateURLs where FileManager.default.fileExists(atPath: url.path) {
        guard let rawData = try? Data(contentsOf: url),
              let remoteDB = try? decoder.decode(SnippetSyncDatabase.self, from: rawData) else {
          continue
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

      // Prepare outbound database (encrypting snippet bodies if AES-256-GCM is turned on)
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

      // Remove merged conflict copies
      for conflictURL in candidateURLs.dropFirst() {
        try? FileManager.default.removeItem(at: conflictURL)
      }

      let plainMergedDB = SnippetSyncDatabase(
        version: 1,
        updatedAt: outDB.updatedAt,
        deviceName: deviceName,
        collections: mergedCols,
        items: mergedItems
      )
      return (plainMergedDB, localChangedFromRemote)
    }.value

    if let (mergedPlainDB, changedFromRemote) = mergedOutcome {
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
