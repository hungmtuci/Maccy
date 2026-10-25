import AppKit
import CryptoKit
import Defaults
import Foundation
import Logging
import Observation
import SwiftData

nonisolated struct SyncedContentPayload: Codable, Sendable {
  var type: String
  var value: Data
  var isCompressed: Bool? = nil
  var isEncrypted: Bool? = nil
  var blobFileName: String? = nil
}

nonisolated struct SyncedClipboardItem: Codable, Identifiable, Sendable {
  var id: String { syncId }
  var syncId: String
  var title: String
  var encryptedTitle: Data? = nil
  var pin: String?
  var application: String?
  var firstCopiedAt: Date
  var lastCopiedAt: Date
  var numberOfCopies: Int
  var updatedAt: Date
  var isDeleted: Bool
  var deviceName: String
  var contents: [SyncedContentPayload]
}

nonisolated struct SyncItemMetadata: Sendable {
  var deviceName: String
  var updatedAt: Date
}

nonisolated struct SyncDatabasePayload: Codable, Sendable {
  var version: Int = 2
  var updatedAt: Date
  var items: [String: SyncedClipboardItem]
}

@Observable
@MainActor
class CloudSyncManager {
  static let shared = CloudSyncManager()

  private let logger = Logger(label: "org.p0deje.Maccy.CloudSync")
  private static let syncFileName = "maccy-synced-items.json"
  private static let maxSingleContentSyncBytes = 16 * 1024 * 1024 // 16 MB per content blob with external blob storage
  private static let externalBlobThresholdBytes = 65_536 // Offload payloads > 64 KB to blobs/<syncId>_<idx>.blob

  var isSyncing: Bool = false
  var filterOnlySynced: Bool = false {
    didSet {
      guard filterOnlySynced != oldValue else { return }
      AppState.shared.history.refreshSyncFilter()
    }
  }
  var lastSyncDate: Date? = Defaults[.lastCloudSyncAt]
  var lastSyncError: String?
  var statusMessage: String = ""
  var detectedGoogleDrivePath: String?

  private var fileWatcherSource: DispatchSourceFileSystemObject?
  private var watcherFileDescriptor: Int32 = -1
  private var pollTimer: Timer?
  private var lastObservedFileModificationDate: Date?
  private var isWritingSyncFile = false
  private var localUpdatedAtByHash: [String: Date] = [:]
  private var metadataByHash: [String: SyncItemMetadata] = [:]

  func syncMetadata(for hash: String) -> SyncItemMetadata? {
    metadataByHash[hash]
  }

  var syncFolderPath: String {
    get { Defaults[.cloudSyncFolderPath] }
    set {
      Defaults[.cloudSyncFolderPath] = newValue
      setupFileWatcher()
      Task {
        await syncNow()
      }
    }
  }

  var isEnabled: Bool {
    Defaults[.cloudSyncEnabled] && !Defaults[.cloudSyncFolderPath].isEmpty
  }

  var syncedCount: Int {
    Defaults[.syncedItemHashes].count
  }

  var syncFileURL: URL? {
    let path = Defaults[.cloudSyncFolderPath].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
      .appendingPathComponent(Self.syncFileName, isDirectory: false)
  }

  init() {
    #if DEBUG
    if History.isRunningUnitTests { return }
    #endif

    autoDetectGoogleDriveIfNeeded()
    setupFileWatcher()
    startPollingTimer()

    Task {
      for await _ in Defaults.updates(.cloudSyncEnabled, initial: false) {
        setupFileWatcher()
        if isEnabled {
          await syncNow()
        }
      }
    }
  }

  /// Automatically locates Google Drive for Desktop on macOS (`~/Library/CloudStorage/GoogleDrive-...`)
  @discardableResult
  func autoDetectGoogleDriveIfNeeded(forceUpdate: Bool = false) -> String? {
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser

    var candidateRoots: [URL] = []
    let cloudStorageURL = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    if let entries = try? fileManager.contentsOfDirectory(
      at: cloudStorageURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      let driveEntries = entries
        .filter { $0.lastPathComponent.hasPrefix("GoogleDrive") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

      for entry in driveEntries {
        let myDriveNames = ["My Drive", "Bộ nhớ của tôi", "Mon disque", "Meine Ablage", "マイドライブ"]
        var matchedSubfolder = false
        for subName in myDriveNames {
          let subURL = entry.appendingPathComponent(subName, isDirectory: true)
          if fileManager.fileExists(atPath: subURL.path) {
            candidateRoots.append(subURL)
            matchedSubfolder = true
            break
          }
        }
        if !matchedSubfolder {
          candidateRoots.append(entry)
        }
      }
    }

    let legacyPaths = [
      "/Volumes/GoogleDrive/My Drive",
      "/Volumes/GoogleDrive/Bộ nhớ của tôi",
      home.appendingPathComponent("Google Drive").path
    ]
    for legacy in legacyPaths where fileManager.fileExists(atPath: legacy) {
      candidateRoots.append(URL(fileURLWithPath: legacy, isDirectory: true))
    }

    guard let firstRoot = candidateRoots.first else {
      detectedGoogleDrivePath = nil
      return nil
    }

    let maccySyncFolder = firstRoot.appendingPathComponent("MaccySync", isDirectory: true)
    detectedGoogleDrivePath = maccySyncFolder.path

    if forceUpdate || Defaults[.cloudSyncFolderPath].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try? fileManager.createDirectory(at: maccySyncFolder, withIntermediateDirectories: true)
      Defaults[.cloudSyncFolderPath] = maccySyncFolder.path
      statusMessage = "Đã kết nối thư mục Google Drive"
      setupFileWatcher()
    }

    return maccySyncFolder.path
  }

  func chooseSyncFolderWithPanel() {
    AppState.shared.suppressPopupAutoClose = true
    defer { AppState.shared.suppressPopupAutoClose = false }

    let panel = NSOpenPanel()
    panel.title = "Chọn thư mục Google Drive để đồng bộ Maccy"
    panel.message = "Chọn thư mục nằm trong Google Drive (hoặc tạo thư mục MaccySync trong Google Drive của bạn)"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Chọn thư mục"

    if let detected = detectedGoogleDrivePath {
      panel.directoryURL = URL(fileURLWithPath: detected).deletingLastPathComponent()
    } else {
      let cloudStorage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
      if FileManager.default.fileExists(atPath: cloudStorage.path) {
        panel.directoryURL = cloudStorage
      }
    }

    NSApp.activate(ignoringOtherApps: true)
    if panel.runModal() == .OK, let selectedURL = panel.url {
      try? FileManager.default.createDirectory(at: selectedURL, withIntermediateDirectories: true)
      syncFolderPath = selectedURL.path
      statusMessage = "Đã chọn thư mục đồng bộ"
    }
  }

  func openSyncFolderInFinder() {
    let path = Defaults[.cloudSyncFolderPath]
    guard !path.isEmpty else { return }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
  }

  func isSynced(_ item: HistoryItem) -> Bool {
    Defaults[.syncedItemHashes].contains(item.contentHash)
  }

  func toggleSync(for decorators: [HistoryItemDecorator]) {
    guard !decorators.isEmpty else { return }
    let allCurrentlySynced = decorators.allSatisfy { $0.isSynced }
    setSynced(!allCurrentlySynced, for: decorators, askForSecretConfirmation: true)
  }

  func setSynced(_ synced: Bool, for decorators: [HistoryItemDecorator], askForSecretConfirmation: Bool = false) {
    guard !decorators.isEmpty else { return }

    if synced,
       askForSecretConfirmation,
       Defaults[.warnBeforeSyncingSecrets],
       currentEncryptionKey == nil {
      let detectedSecrets = decorators.compactMap { detectSensitiveSecret(in: $0.item) }
      if let firstSecret = detectedSecrets.first {
        guard confirmSyncingSensitiveContent(secretKind: firstSecret) else {
          return
        }
      }
    }

    var hashes = Defaults[.syncedItemHashes]
    let now = Date.now
    let deviceName = Host.current().localizedName ?? "Mac"

    for decorator in decorators {
      let hash = decorator.item.contentHash
      decorator.isSynced = synced
      localUpdatedAtByHash[hash] = now
      if synced {
        hashes.insert(hash)
        metadataByHash[hash] = SyncItemMetadata(deviceName: deviceName, updatedAt: now)
      } else {
        hashes.remove(hash)
        metadataByHash.removeValue(forKey: hash)
      }
    }

    Defaults[.syncedItemHashes] = hashes
    AppState.shared.history.refreshSyncFilter()

    Task {
      await syncNow()
    }
  }

  /// Detects common secret patterns (Private Keys, OpenAI/GitHub/AWS/Google API keys) before cloud sync.
  private func detectSensitiveSecret(in item: HistoryItem) -> String? {
    let prefix = item.previewableTextPrefix(maxBytes: 16_384).text
    guard !prefix.isEmpty else { return nil }

    let patterns: [(name: String, regex: String)] = [
      ("Private Key (SSH/RSA/PEM)", "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
      ("OpenAI / Anthropic API Key", "\\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{24,}\\b"),
      ("GitHub Token", "\\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\\b"),
      ("AWS Access Key", "\\bAKIA[0-9A-Z]{16}\\b"),
      ("Google Cloud / Firebase API Key", "\\bAIza[0-9A-Za-z_-]{35}\\b"),
      ("Slack Token", "\\bxox[baprs]-[0-9A-Za-z-]{15,}\\b")
    ]

    for (name, pattern) in patterns {
      if prefix.range(of: pattern, options: .regularExpression) != nil {
        return name
      }
    }
    return nil
  }

  private func confirmSyncingSensitiveContent(secretKind: String) -> Bool {
    AppState.shared.suppressPopupAutoClose = true
    defer { AppState.shared.suppressPopupAutoClose = false }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Phát hiện nội dung nhạy cảm: \(secretKind)"
    alert.informativeText = "Mục bạn chọn có chứa khoá bảo mật hoặc token nhạy cảm trong khi tính năng Mã hoá AES-256 trên Google Drive chưa được bật.\n\nBạn vẫn muốn đồng bộ mục này lên Google Drive?"
    alert.addButton(withTitle: "Vẫn đồng bộ")
    alert.addButton(withTitle: "Huỷ")

    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
  }

  private var currentEncryptionKey: SymmetricKey? {
    guard Defaults[.cloudSyncEncryptionEnabled] else { return nil }
    let pass = Defaults[.cloudSyncPassphrase].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pass.isEmpty else { return nil }
    let digest = SHA256.hash(data: Data(("MaccySync-AES256-v1:" + pass).utf8))
    return SymmetricKey(data: digest)
  }

  func handleItemPinned(_ decorator: HistoryItemDecorator) {
    guard Defaults[.autoSyncPinnedItems] else { return }
    if decorator.isPinned && !decorator.isSynced {
      setSynced(true, for: [decorator], askForSecretConfirmation: false)
    }
  }

  func handleItemDeleted(_ item: HistoryItem) {
    let hash = item.contentHash
    guard Defaults[.syncedItemHashes].contains(hash) else { return }
    Defaults[.syncedItemHashes].remove(hash)
    metadataByHash.removeValue(forKey: hash)
    localUpdatedAtByHash[hash] = Date.now
    Task {
      await syncNow()
    }
  }

  /// Performs a two-way merge between local synced items and `<GoogleDrive>/maccy-synced-items.json`.
  func syncNow() async {
    guard Defaults[.cloudSyncEnabled] else { return }
    if Defaults[.cloudSyncFolderPath].isEmpty {
      autoDetectGoogleDriveIfNeeded()
    }
    guard let fileURL = syncFileURL else {
      lastSyncError = "Chưa chọn thư mục Google Drive"
      return
    }

    let folderURL = fileURL.deletingLastPathComponent()
    let blobsURL = folderURL.appendingPathComponent("blobs", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: blobsURL, withIntermediateDirectories: true)
    } catch {
      lastSyncError = "Không thể tạo thư mục: \(error.localizedDescription)"
      return
    }

    isSyncing = true
    defer { isSyncing = false }

    let deviceName = Host.current().localizedName ?? "Mac"
    let encryptionKey = currentEncryptionKey
    var database = readDatabase(from: fileURL) ?? SyncDatabasePayload(updatedAt: Date.now, items: [:])
    var hashes = Defaults[.syncedItemHashes]
    let allLocalDecorators = AppState.shared.history.allDecorators
    var localByHash: [String: HistoryItemDecorator] = [:]
    for decorator in allLocalDecorators {
      localByHash[decorator.item.contentHash] = decorator
    }

    // Auto-enroll pinned items if autoSyncPinnedItems is enabled
    if Defaults[.autoSyncPinnedItems] {
      for decorator in allLocalDecorators where decorator.isPinned && !decorator.isSynced {
        let hash = decorator.item.contentHash
        if let remote = database.items[hash], remote.isDeleted {
          // Was explicitly unsynced remotely; don't re-add automatically unless re-pinned
        } else {
          hashes.insert(hash)
          decorator.isSynced = true
        }
      }
    }

    var localHistoryChanged = false

    // 1. Merge remote items into local History
    for (syncId, remoteItem) in database.items {
      let localStamp = localUpdatedAtByHash[syncId] ?? .distantPast
      if remoteItem.isDeleted {
        if remoteItem.updatedAt >= localStamp, hashes.contains(syncId) {
          hashes.remove(syncId)
          metadataByHash.removeValue(forKey: syncId)
          if let localDecorator = localByHash[syncId] {
            localDecorator.isSynced = false
            localHistoryChanged = true
          }
        }
        continue
      }

      metadataByHash[syncId] = SyncItemMetadata(
        deviceName: remoteItem.deviceName,
        updatedAt: remoteItem.updatedAt
      )

      // Remote item is active (!isDeleted)
      if let localDecorator = localByHash[syncId] {
        if !hashes.contains(syncId) {
          // If locally unsynced more recently than remote update, mark remote as deleted
          if localStamp > remoteItem.updatedAt {
            var tombstone = remoteItem
            tombstone.isDeleted = true
            tombstone.updatedAt = localStamp
            tombstone.contents = []
            database.items[syncId] = tombstone
            metadataByHash.removeValue(forKey: syncId)
            continue
          } else {
            hashes.insert(syncId)
            localDecorator.isSynced = true
            localHistoryChanged = true
          }
        }
      } else {
        // Remote item does not exist locally yet -> import into Maccy History!
        if localStamp > remoteItem.updatedAt {
          // Locally deleted/unsynced more recently
          var tombstone = remoteItem
          tombstone.isDeleted = true
          tombstone.updatedAt = localStamp
          tombstone.contents = []
          database.items[syncId] = tombstone
          metadataByHash.removeValue(forKey: syncId)
          continue
        }

        if let importedDecorator = importRemoteItem(remoteItem, folderURL: folderURL, encryptionKey: encryptionKey) {
          hashes.insert(syncId)
          importedDecorator.isSynced = true
          localByHash[syncId] = importedDecorator
          localHistoryChanged = true
        }
      }
    }

    // 2. Push local synced items into database
    for syncId in hashes {
      guard let decorator = localByHash[syncId] else { continue }
      let item = decorator.item
      let existingRemote = database.items[syncId]
      let localStamp = localUpdatedAtByHash[syncId] ?? item.lastCopiedAt

      if existingRemote == nil || existingRemote?.isDeleted == true || localStamp > (existingRemote?.updatedAt ?? .distantPast) || existingRemote?.pin != item.pin {
        let payloadContents = buildSyncContents(
          for: item,
          syncId: syncId,
          folderURL: folderURL,
          encryptionKey: encryptionKey
        )
        let encryptedTitleData: Data?
        let plainTitle: String
        if let key = encryptionKey, let titleData = item.title.data(using: .utf8),
           let sealed = try? AES.GCM.seal(titleData, using: key).combined {
          encryptedTitleData = sealed
          plainTitle = "🔒 [Đã mã hoá AES-256]"
        } else {
          encryptedTitleData = nil
          plainTitle = item.title
        }

        let updatedStamp = max(localStamp, Date.now)
        let syncedItem = SyncedClipboardItem(
          syncId: syncId,
          title: plainTitle,
          encryptedTitle: encryptedTitleData,
          pin: item.pin,
          application: item.application,
          firstCopiedAt: item.firstCopiedAt,
          lastCopiedAt: item.lastCopiedAt,
          numberOfCopies: item.numberOfCopies,
          updatedAt: updatedStamp,
          isDeleted: false,
          deviceName: deviceName,
          contents: payloadContents
        )
        database.items[syncId] = syncedItem
        if metadataByHash[syncId] == nil {
          metadataByHash[syncId] = SyncItemMetadata(deviceName: deviceName, updatedAt: updatedStamp)
        }
      }
    }

    // 3. Mark any previously synced remote items that were unsynced locally
    for (syncId, localStamp) in localUpdatedAtByHash where !hashes.contains(syncId) {
      if var remote = database.items[syncId], !remote.isDeleted, localStamp >= remote.updatedAt {
        remote.isDeleted = true
        remote.updatedAt = localStamp
        remote.contents = []
        database.items[syncId] = remote
        metadataByHash.removeValue(forKey: syncId)
      }
    }

    Defaults[.syncedItemHashes] = hashes

    if localHistoryChanged {
      AppState.shared.history.refreshSyncFilter()
    }

    // 4. Write updated database back to Google Drive folder
    database.updatedAt = Date.now
    do {
      isWritingSyncFile = true
      defer { isWritingSyncFile = false }

      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(database)
      try data.write(to: fileURL, options: [.atomic])

      if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
         let modDate = attrs[.modificationDate] as? Date {
        lastObservedFileModificationDate = modDate
      }

      let now = Date.now
      lastSyncDate = now
      Defaults[.lastCloudSyncAt] = now
      lastSyncError = nil
      statusMessage = "Đã đồng bộ \(hashes.count) mục"
    } catch {
      lastSyncError = "Lỗi ghi file đồng bộ: \(error.localizedDescription)"
      logger.error("Failed to write Google Drive sync file: \(error.localizedDescription)")
    }
  }

  private func buildSyncContents(
    for item: HistoryItem,
    syncId: String,
    folderURL: URL,
    encryptionKey: SymmetricKey?
  ) -> [SyncedContentPayload] {
    let nonTransient = item.contents.filter { !HistoryItem.transientTypes.contains($0.type) }
    var rawPayloads: [(type: String, data: Data)] = []

    for content in nonTransient {
      guard let data = content.value, !data.isEmpty else { continue }
      if data.count <= Self.maxSingleContentSyncBytes {
        rawPayloads.append((content.type, data))
      } else if content.type == NSPasteboard.PasteboardType.string.rawValue,
                let truncated = data.utf8PrefixString(maxBytes: Self.maxSingleContentSyncBytes)?.data(using: .utf8) {
        rawPayloads.append((content.type, truncated))
      }
    }

    // Fallback if all blobs were oversized (e.g. a 30MB uncompressed TIFF): compress to PNG or use title
    if rawPayloads.isEmpty {
      if let image = item.image,
         let tiff = image.tiffRepresentation,
         let rep = NSBitmapImageRep(data: tiff),
         let pngData = rep.representation(using: .png, properties: [:]),
         pngData.count <= Self.maxSingleContentSyncBytes {
        rawPayloads.append((NSPasteboard.PasteboardType.png.rawValue, pngData))
      } else if let textData = item.title.data(using: .utf8) {
        rawPayloads.append((NSPasteboard.PasteboardType.string.rawValue, textData))
      }
    }

    var result: [SyncedContentPayload] = []
    for (idx, raw) in rawPayloads.enumerated() {
      var processedData = raw.data
      var isCompressed = false
      var isEncrypted = false

      // 1. LZFSE Compression for payloads > 1 KB
      if processedData.count > 1_024,
         let compressed = try? (processedData as NSData).compressed(using: .lzfse) as Data,
         compressed.count < processedData.count {
        processedData = compressed
        isCompressed = true
      }

      // 2. AES-GCM 256-bit Encryption (if enabled)
      if let key = encryptionKey,
         let sealed = try? AES.GCM.seal(processedData, using: key).combined {
        processedData = sealed
        isEncrypted = true
      }

      // 3. Offload large blobs (> 64 KB) to separate file in `blobs/` to keep JSON lightweight & conflict-free
      if processedData.count >= Self.externalBlobThresholdBytes {
        let relPath = "blobs/\(syncId)_\(idx).blob"
        let blobURL = folderURL.appendingPathComponent(relPath, isDirectory: false)
        if (try? processedData.write(to: blobURL, options: [.atomic])) != nil {
          result.append(
            SyncedContentPayload(
              type: raw.type,
              value: Data(),
              isCompressed: isCompressed,
              isEncrypted: isEncrypted,
              blobFileName: relPath
            )
          )
          continue
        }
      }

      result.append(
        SyncedContentPayload(
          type: raw.type,
          value: processedData,
          isCompressed: isCompressed ? true : nil,
          isEncrypted: isEncrypted ? true : nil,
          blobFileName: nil
        )
      )
    }

    return result
  }

  private func importRemoteItem(
    _ remote: SyncedClipboardItem,
    folderURL: URL,
    encryptionKey: SymmetricKey?
  ) -> HistoryItemDecorator? {
    var contents: [HistoryItemContent] = []

    for payload in remote.contents {
      var data = payload.value
      if let relPath = payload.blobFileName, !relPath.isEmpty {
        let blobURL = folderURL.appendingPathComponent(relPath, isDirectory: false)
        guard let fileData = try? Data(contentsOf: blobURL) else {
          continue
        }
        data = fileData
      }

      if payload.isEncrypted == true {
        guard let key = encryptionKey,
              let box = try? AES.GCM.SealedBox(combined: data),
              let opened = try? AES.GCM.open(box, using: key) else {
          lastSyncError = "Cần nhập đúng Mật khẩu mã hoá trong Cài đặt Google Drive để giải mã mục đồng bộ"
          return nil
        }
        data = opened
      }

      if payload.isCompressed == true {
        if let decompressed = try? (data as NSData).decompressed(using: .lzfse) as Data {
          data = decompressed
        }
      }

      contents.append(HistoryItemContent(type: payload.type, value: data))
    }

    guard !contents.isEmpty else { return nil }

    let newItem = HistoryItem(contents: contents)
    newItem.application = remote.application
    newItem.firstCopiedAt = remote.firstCopiedAt
    newItem.lastCopiedAt = remote.lastCopiedAt
    newItem.numberOfCopies = max(1, remote.numberOfCopies)

    var resolvedTitle = remote.title
    if let encTitle = remote.encryptedTitle,
       let key = encryptionKey,
       let box = try? AES.GCM.SealedBox(combined: encTitle),
       let opened = try? AES.GCM.open(box, using: key),
       let str = String(data: opened, encoding: .utf8) {
      resolvedTitle = str
    }
    newItem.title = (resolvedTitle.isEmpty || resolvedTitle.hasPrefix("🔒")) ? newItem.generateTitle() : resolvedTitle

    if let remotePin = remote.pin,
       History.shared.availablePins.contains(remotePin) {
      newItem.pin = remotePin
    }

    return History.shared.addSyncedItemFromCloud(newItem, syncId: remote.syncId)
  }

  private func readDatabase(from url: URL) -> SyncDatabasePayload? {
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url),
          !data.isEmpty else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(SyncDatabasePayload.self, from: data)
  }

  private func startPollingTimer() {
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.checkRemoteFileChangesIfNeeded()
      }
    }
  }

  private func checkRemoteFileChangesIfNeeded() {
    guard isEnabled, !isWritingSyncFile, !isSyncing, let fileURL = syncFileURL else { return }
    guard FileManager.default.fileExists(atPath: fileURL.path),
          let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
          let modDate = attrs[.modificationDate] as? Date else {
      return
    }

    if let lastObserved = lastObservedFileModificationDate {
      if modDate > lastObserved.addingTimeInterval(0.5) {
        lastObservedFileModificationDate = modDate
        Task {
          await syncNow()
        }
      }
    } else {
      lastObservedFileModificationDate = modDate
      Task {
        await syncNow()
      }
    }
  }

  func setupFileWatcher() {
    fileWatcherSource?.cancel()
    fileWatcherSource = nil
    if watcherFileDescriptor >= 0 {
      close(watcherFileDescriptor)
      watcherFileDescriptor = -1
    }

    guard isEnabled, let fileURL = syncFileURL else { return }
    let folderURL = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

    let fd = open(folderURL.path, O_EVTONLY)
    guard fd >= 0 else { return }
    watcherFileDescriptor = fd

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .rename, .extend, .attrib],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      Task { @MainActor in
        self?.checkRemoteFileChangesIfNeeded()
      }
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    fileWatcherSource = source
  }
}
