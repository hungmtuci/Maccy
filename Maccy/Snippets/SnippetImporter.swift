import Foundation

nonisolated struct ImportedSnippetPayload: Sendable {
  var name: String
  var abbreviation: String
  var content: String
  var contentMode: SnippetContentMode = .plainText
  var triggerMode: SnippetTriggerMode = .immediate
  var caseMode: SnippetCaseMode = .ignoreCase
  var wholeWord: Bool = false
  var isEnabled: Bool = true
  var usageCount: Int = 0
}

nonisolated struct ImportedCollectionPayload: Sendable {
  var name: String
  var icon: String = "folder.fill"
  var isEnabled: Bool = true
  var keywordPrefix: String = ""
  var keywordSuffix: String = ""
  var items: [ImportedSnippetPayload]
}

nonisolated struct SnippetImportPayload: Sendable {
  var collections: [ImportedCollectionPayload]
  var sourceDescription: String
}

nonisolated enum SnippetImportError: LocalizedError, Sendable {
  case alfredNotFound
  case typinatorNotFound
  case typinatorScriptingFailed(String)
  case unsupportedFormat(String)
  case emptyImport

  var errorDescription: String? {
    switch self {
    case .alfredNotFound:
      return "Không tìm thấy thư mục dữ liệu Alfred Snippets trên máy. Bạn vẫn có thể chọn trực tiếp tệp .alfredpreferences hoặc .alfredsnippets."
    case .typinatorNotFound:
      return "Không tìm thấy ứng dụng Typinator (/Applications/Typinator.app)."
    case .typinatorScriptingFailed(let detail):
      return "Không đọc được dữ liệu từ Typinator qua Automation: \(detail)\n\nHãy bấm \"Allow / Cho phép\" khi macOS hỏi quyền điều khiển Typinator (System Settings → Privacy & Security → Automation → Maccy), hoặc dùng chức năng Export ra tệp .txt/.csv trong Typinator rồi chọn \"Nhập từ tệp\"."
    case .unsupportedFormat(let detail):
      return "Định dạng tệp không hợp lệ hoặc không hỗ trợ: \(detail)"
    case .emptyImport:
      return "Không tìm thấy gõ tắt (snippet) nào để nhập."
    }
  }
}

nonisolated enum SnippetStarterPackID: String, CaseIterable, Identifiable, Sendable {
  case academicSymbols
  case dynamicTemplates
  case academicAutoCorrect

  var id: Self { self }

  var title: String {
    switch self {
    case .academicSymbols:
      return "Ký hiệu Học thuật & Thống kê (±, ≤, ≥, χ², 95% CI, p < 0.05…)"
    case .dynamicTemplates:
      return "Mẫu Email, Lịch hẹn & Biểu mẫu động (Fill-in + Ngày làm việc)"
    case .academicAutoCorrect:
      return "Tự sửa lỗi chính tả Tiếng Anh Học thuật (AutoCorrect)"
    }
  }
}

nonisolated enum SnippetImporter {
  // MARK: - 1. Installed Alfred Snippets Importer

  static var isAlfredInstalled: Bool {
    discoverAlfredSnippetsRootDirectory() != nil
  }

  static func discoverAlfredSnippetsRootDirectory() -> URL? {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser

    // 1. Read ~/Library/Application Support/Alfred/prefs.json -> "current"
    let prefsJSON = home
      .appendingPathComponent("Library/Application Support/Alfred/prefs.json")
    if let data = try? Data(contentsOf: prefsJSON),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let currentPath = json["current"] as? String,
       !currentPath.isEmpty {
      let snippetsDir = URL(fileURLWithPath: currentPath).appendingPathComponent("snippets", isDirectory: true)
      if fm.fileExists(atPath: snippetsDir.path) {
        return snippetsDir
      }
    }

    // 2. Common fallback locations
    let fallbacks = [
      home.appendingPathComponent("Library/Application Support/Alfred/Alfred.alfredpreferences/snippets"),
      home.appendingPathComponent("Sync/Alfred/Alfred.alfredpreferences/snippets")
    ]
    for candidate in fallbacks where fm.fileExists(atPath: candidate.path) {
      return candidate
    }
    return nil
  }

  static func loadFromInstalledAlfred() throws -> SnippetImportPayload {
    guard let snippetsRoot = discoverAlfredSnippetsRootDirectory() else {
      throw SnippetImportError.alfredNotFound
    }
    return try loadFromAlfredSnippetsDirectory(snippetsRoot, sourceDescription: "Alfred Snippets")
  }

  static func loadFromAlfredSnippetsDirectory(_ snippetsRoot: URL, sourceDescription: String) throws -> SnippetImportPayload {
    let fm = FileManager.default
    let entries = try fm.contentsOfDirectory(
      at: snippetsRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )

    var collections: [ImportedCollectionPayload] = []
    for folder in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
      if let col = parseAlfredCollectionFolder(folder, defaultCollectionName: folder.lastPathComponent),
         !col.items.isEmpty {
        collections.append(col)
      }
    }

    // Also handle case where `snippetsRoot` itself directly contains `*.json` snippet files
    if collections.isEmpty,
       let directCol = parseAlfredCollectionFolder(snippetsRoot, defaultCollectionName: snippetsRoot.deletingPathExtension().lastPathComponent),
       !directCol.items.isEmpty {
      collections.append(directCol)
    }

    guard !collections.isEmpty else {
      throw SnippetImportError.emptyImport
    }
    return SnippetImportPayload(collections: collections, sourceDescription: sourceDescription)
  }

  static func loadFromAlfredArchive(url: URL) throws -> SnippetImportPayload {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("maccy-alfred-import-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
      try? fm.removeItem(at: tempDir)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", url.path, tempDir.path]
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw SnippetImportError.unsupportedFormat("Không thể giải nén gói .alfredsnippets (\(url.lastPathComponent)).")
    }

    let collectionName = url.deletingPathExtension().lastPathComponent
    guard let col = parseAlfredCollectionFolder(tempDir, defaultCollectionName: collectionName),
          !col.items.isEmpty else {
      throw SnippetImportError.emptyImport
    }
    return SnippetImportPayload(collections: [col], sourceDescription: "Alfred Archive (\(url.lastPathComponent))")
  }

  private struct RawAlfredFile: Decodable {
    struct Body: Decodable {
      var snippet: String?
      var uid: String?
      var name: String?
      var keyword: String?
      var dontautoexpand: Bool?
    }
    var alfredsnippet: Body
  }

  private static func parseAlfredCollectionFolder(_ folder: URL, defaultCollectionName: String) -> ImportedCollectionPayload? {
    let fm = FileManager.default
    var prefix = ""
    var suffix = ""

    let plistURL = folder.appendingPathComponent("info.plist")
    if let plistData = try? Data(contentsOf: plistURL),
       let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
      prefix = (plist["snippetkeywordprefix"] as? String) ?? ""
      suffix = (plist["snippetkeywordsuffix"] as? String) ?? ""
    }

    guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
      return nil
    }

    let decoder = JSONDecoder()
    var items: [ImportedSnippetPayload] = []

    for file in files where file.pathExtension.lowercased() == "json" {
      guard let data = try? Data(contentsOf: file),
            let parsed = try? decoder.decode(RawAlfredFile.self, from: data) else {
        continue
      }
      let body = parsed.alfredsnippet
      let content = body.snippet ?? ""
      guard !content.isEmpty else { continue }

      let rawKeyword = (body.keyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let rawName = (body.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let disableAuto = (body.dontautoexpand ?? false) || rawKeyword.isEmpty

      items.append(
        ImportedSnippetPayload(
          name: rawName.isEmpty ? rawKeyword : rawName,
          abbreviation: rawKeyword,
          content: content,
          contentMode: .plainText,
          triggerMode: disableAuto ? .manualOnly : .immediate,
          caseMode: .ignoreCase,
          wholeWord: false,
          isEnabled: true
        )
      )
    }

    items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return ImportedCollectionPayload(
      name: defaultCollectionName,
      icon: "sparkles.rectangle.stack",
      isEnabled: true,
      keywordPrefix: prefix,
      keywordSuffix: suffix,
      items: items
    )
  }

  // MARK: - 2. Live Typinator Importer (AppleScript / JXA Bridge)

  static var isTypinatorInstalled: Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: "/Applications/Typinator.app")
      || fm.fileExists(atPath: fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Typinator.app").path)
  }

  private struct RawTypinatorExport: Decodable {
    struct RuleDTO: Decodable {
      var abbreviation: String
      var plainExpansion: String
      var description: String
      var wholeWord: Bool
      var caseHandling: String
      var expansionCount: Int
    }
    struct SetDTO: Decodable {
      var name: String
      var enabled: Bool
      var ruleType: String
      var commonPrefix: String
      var commonSuffix: String
      var rules: [RuleDTO]
    }
    var sets: [SetDTO]
  }

  static func loadFromInstalledTypinator() async throws -> SnippetImportPayload {
    guard isTypinatorInstalled else {
      throw SnippetImportError.typinatorNotFound
    }

    let jxaScript = #"""
    const app = Application("Typinator");
    const sets = app.ruleSets();
    const outSets = [];
    for (let i = 0; i < sets.length; i++) {
      const rs = sets[i];
      const setName = String(rs.name() || ("Set " + (i + 1)));
      const setEnabled = Boolean(rs.enabled());
      let ruleType = "abbreviation rules";
      try { ruleType = String(rs.ruleType() || "abbreviation rules"); } catch (e) {}
      let prefix = "";
      let suffix = "";
      try { prefix = String(rs.commonPrefix() || ""); } catch (e) {}
      try { suffix = String(rs.commonSuffix() || ""); } catch (e) {}

      const rulesOut = [];
      try {
        const abbrs = rs.rules.abbreviation();
        const count = Array.isArray(abbrs) ? abbrs.length : 0;
        if (count > 0) {
          const exps = rs.rules.plainExpansion();
          const descs = rs.rules.description();
          const wws = rs.rules.wholeWord();
          const cases = rs.rules.caseHandling();
          const counts = rs.rules.expansionCount();
          for (let j = 0; j < count; j++) {
            rulesOut.push({
              abbreviation: String(abbrs[j] || ""),
              plainExpansion: String(exps[j] || ""),
              description: String(descs[j] || ""),
              wholeWord: Boolean(wws[j]),
              caseHandling: String(cases[j] || "case does not matter"),
              expansionCount: Number(counts[j] || 0)
            });
          }
        }
      } catch (batchErr) {
        const ruleRefs = rs.rules();
        for (let j = 0; j < ruleRefs.length; j++) {
          const r = ruleRefs[j];
          try {
            rulesOut.push({
              abbreviation: String(r.abbreviation() || ""),
              plainExpansion: String(r.plainExpansion() || ""),
              description: String(r.description() || ""),
              wholeWord: Boolean(r.wholeWord()),
              caseHandling: String(r.caseHandling() || "case does not matter"),
              expansionCount: Number(r.expansionCount() || 0)
            });
          } catch (innerErr) {}
        }
      }

      outSets.push({
        name: setName,
        enabled: setEnabled,
        ruleType: ruleType,
        commonPrefix: prefix,
        commonSuffix: suffix,
        rules: rulesOut
      });
    }
    JSON.stringify({ sets: outSets });
    """#

    let (exitCode, stdout, stderr) = await runOSAScript(language: "JavaScript", script: jxaScript, timeoutSeconds: 30)
    guard exitCode == 0, let jsonData = stdout.data(using: .utf8), !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SnippetImportError.typinatorScriptingFailed(stderr.isEmpty ? "Ứng dụng chưa cấp quyền Automation cho Maccy." : stderr)
    }

    return try parseTypinatorJSONData(jsonData)
  }

  static func parseTypinatorJSONData(_ jsonData: Data) throws -> SnippetImportPayload {
    let decoded: RawTypinatorExport
    do {
      decoded = try JSONDecoder().decode(RawTypinatorExport.self, from: jsonData)
    } catch {
      throw SnippetImportError.typinatorScriptingFailed(error.localizedDescription)
    }

    var collections: [ImportedCollectionPayload] = []
    for rs in decoded.sets {
      let isRegexSet = rs.ruleType.lowercased().contains("regular expression")
      var items: [ImportedSnippetPayload] = []
      items.reserveCapacity(rs.rules.count)

      for rule in rs.rules {
        let abbr = rule.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        let expansion = convertTypinatorPlaceholders(rule.plainExpansion)
        guard !expansion.isEmpty || !abbr.isEmpty else { continue }

        let caseMode: SnippetCaseMode
        switch rule.caseHandling.lowercased() {
        case "case must match":
          caseMode = .caseSensitive
        case "case affects expansion":
          caseMode = .propagateCase
        default:
          caseMode = .ignoreCase
        }

        let triggerMode: SnippetTriggerMode
        if isRegexSet || abbr.isEmpty {
          triggerMode = .manualOnly
        } else if rule.wholeWord {
          triggerMode = .afterDelimiter
        } else {
          triggerMode = .immediate
        }

        let desc = rule.description.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(
          ImportedSnippetPayload(
            name: desc,
            abbreviation: abbr,
            content: expansion,
            contentMode: .plainText,
            triggerMode: triggerMode,
            caseMode: caseMode,
            wholeWord: rule.wholeWord,
            isEnabled: !isRegexSet,
            usageCount: max(0, rule.expansionCount)
          )
        )
      }

      if !items.isEmpty {
        collections.append(
          ImportedCollectionPayload(
            name: rs.name,
            icon: rs.name.lowercased().contains("autocorrect") ? "checkmark.bubble" : "bolt.horizontal.circle",
            isEnabled: rs.enabled && !isRegexSet,
            keywordPrefix: rs.commonPrefix,
            keywordSuffix: rs.commonSuffix,
            items: items
          )
        )
      }
    }

    guard !collections.isEmpty else {
      throw SnippetImportError.emptyImport
    }

    return SnippetImportPayload(collections: collections, sourceDescription: "Typinator")
  }

  /// Pauses Typinator's expansion engine so Typinator and Maccy do not double-expand the same abbreviation.
  static func pauseTypinatorExpansions() async -> Bool {
    guard isTypinatorInstalled else { return false }
    let (code, _, _) = await runOSAScript(
      language: "AppleScript",
      script: #"tell application "Typinator" to pause expansions"#,
      timeoutSeconds: 5
    )
    return code == 0
  }

  private static func convertTypinatorPlaceholders(_ raw: String) -> String {
    guard raw.contains("{") else { return raw }
    return raw
      .replacingOccurrences(of: "{^}", with: "{{cursor}}")
      .replacingOccurrences(of: "{clip}", with: "{{clipboard}}")
      .replacingOccurrences(of: "{key:Tab}", with: "{{tab}}")
      .replacingOccurrences(of: "{key:Return}", with: "{{enter}}")
      .replacingOccurrences(of: "{key:Enter}", with: "{{enter}}")
      .replacingOccurrences(of: "{key:Esc}", with: "{{esc}}")
      .replacingOccurrences(of: "{YYYY}-{MM}-{DD}", with: "{{isodate}}")
      .replacingOccurrences(of: "{DD}/{MM}/{YYYY}", with: "{{date:dd/MM/yyyy}}")
  }

  private static func runOSAScript(
    language: String,
    script: String,
    timeoutSeconds: TimeInterval
  ) async -> (Int32, String, String) {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        if language == "JavaScript" {
          process.arguments = ["-l", "JavaScript", "-e", script]
        } else {
          process.arguments = ["-e", script]
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
          try process.run()
        } catch {
          continuation.resume(returning: (-1, "", error.localizedDescription))
          return
        }

        final class SubprocessBox: @unchecked Sendable {
          var didTimeout = false
          var errData = Data()
        }
        let box = SubprocessBox()

        let timeoutWork = DispatchWorkItem {
          if process.isRunning {
            box.didTimeout = true
            process.terminate()
          }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global(qos: .utility).async {
          box.errData = errPipe.fileHandleForReading.readDataToEndOfFile()
          errGroup.leave()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errGroup.wait()
        process.waitUntilExit()
        timeoutWork.cancel()

        if box.didTimeout {
          continuation.resume(returning: (-2, "", "Quá thời gian chờ phản hồi từ ứng dụng (\(Int(timeoutSeconds))s)."))
          return
        }

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = (String(data: box.errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.resume(returning: (process.terminationStatus, outStr, errStr))
      }
    }
  }

  // MARK: - 3. Generic File Importer & Exporter (.alfredsnippets, .alfredpreferences, .json, .csv, .tsv)

  static func loadFromFile(url: URL) throws -> SnippetImportPayload {
    let ext = url.pathExtension.lowercased()
    if ext == "alfredsnippets" {
      return try loadFromAlfredArchive(url: url)
    }
    if ext == "alfredpreferences" {
      let snippetsSubdir = url.appendingPathComponent("snippets", isDirectory: true)
      return try loadFromAlfredSnippetsDirectory(snippetsSubdir, sourceDescription: url.lastPathComponent)
    }

    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
      let maybeSnippets = url.appendingPathComponent("snippets", isDirectory: true)
      if FileManager.default.fileExists(atPath: maybeSnippets.path) {
        return try loadFromAlfredSnippetsDirectory(maybeSnippets, sourceDescription: url.lastPathComponent)
      }
      return try loadFromAlfredSnippetsDirectory(url, sourceDescription: url.lastPathComponent)
    }

    let data = try Data(contentsOf: url)
    if ext == "json" {
      return try loadFromJSONData(data, fileName: url.deletingPathExtension().lastPathComponent)
    }
    if ext == "csv" || ext == "tsv" || ext == "txt" {
      guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
        throw SnippetImportError.unsupportedFormat("Không đọc được bảng mã văn bản UTF-8/UTF-16.")
      }
      let delimiter: Character = (ext == "tsv" || (text.contains("\t") && !text.contains(","))) ? "\t" : ","
      return try loadFromDelimitedText(
        text,
        delimiter: delimiter,
        defaultCollectionName: url.deletingPathExtension().lastPathComponent
      )
    }

    throw SnippetImportError.unsupportedFormat(url.lastPathComponent)
  }

  private struct SimpleJSONItem: Decodable {
    var name: String?
    var abbreviation: String?
    var keyword: String?
    var content: String?
    var snippet: String?
    var collection: String?
  }

  static func loadFromJSONData(_ data: Data, fileName: String) throws -> SnippetImportPayload {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    // 1. Native Maccy SnippetSyncDatabase backup
    if let syncDB = try? decoder.decode(SnippetSyncDatabase.self, from: data), !syncDB.items.isEmpty {
      let activeCollections = syncDB.collections.values
        .filter { !$0.isDeleted }
        .sorted { $0.sortOrder < $1.sortOrder }
      var resultCols: [ImportedCollectionPayload] = []

      for col in activeCollections {
        let colItems = syncDB.items.values
          .filter { !$0.isDeleted && $0.collectionId == col.id }
          .map { item in
            ImportedSnippetPayload(
              name: item.name,
              abbreviation: item.abbreviation,
              content: item.content,
              contentMode: item.contentMode,
              triggerMode: item.triggerMode,
              caseMode: item.caseMode,
              wholeWord: item.wholeWord,
              isEnabled: item.isEnabled,
              usageCount: item.usageCount
            )
          }
        if !colItems.isEmpty {
          resultCols.append(
            ImportedCollectionPayload(
              name: col.name,
              icon: col.icon,
              isEnabled: col.isEnabled,
              keywordPrefix: col.keywordPrefix,
              keywordSuffix: col.keywordSuffix,
              items: colItems
            )
          )
        }
      }
      if !resultCols.isEmpty {
        return SnippetImportPayload(collections: resultCols, sourceDescription: "JSON (\(fileName))")
      }
    }

    // 2. Simple JSON array of snippets
    if let list = try? JSONDecoder().decode([SimpleJSONItem].self, from: data), !list.isEmpty {
      var grouped: [String: [ImportedSnippetPayload]] = [:]
      for row in list {
        let abbr = (row.abbreviation ?? row.keyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = row.content ?? row.snippet ?? ""
        guard !body.isEmpty else { continue }
        let groupName = (row.collection ?? fileName).trimmingCharacters(in: .whitespacesAndNewlines)
        grouped[groupName.isEmpty ? fileName : groupName, default: []].append(
          ImportedSnippetPayload(
            name: row.name ?? abbr,
            abbreviation: abbr,
            content: body,
            triggerMode: abbr.isEmpty ? .manualOnly : .immediate
          )
        )
      }
      let cols = grouped.keys.sorted().compactMap { key -> ImportedCollectionPayload? in
        guard let items = grouped[key], !items.isEmpty else { return nil }
        return ImportedCollectionPayload(name: key, items: items)
      }
      if !cols.isEmpty {
        return SnippetImportPayload(collections: cols, sourceDescription: "JSON (\(fileName))")
      }
    }

    throw SnippetImportError.unsupportedFormat("Cấu trúc JSON không khớp định dạng Snippet.")
  }

  static func loadFromDelimitedText(
    _ text: String,
    delimiter: Character,
    defaultCollectionName: String
  ) throws -> SnippetImportPayload {
    let rows = parseDelimitedRows(text, delimiter: delimiter)
    guard !rows.isEmpty else { throw SnippetImportError.emptyImport }

    var startIndex = 0
    if let first = rows.first, first.count >= 2 {
      let col0 = first[0].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
      let col1 = first[1].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
      if ["abbreviation", "keyword", "shortcut", "go tat", "gõ tắt"].contains(col0)
          || ["expansion", "content", "snippet", "noi dung", "nội dung"].contains(col1) {
        startIndex = 1
      }
    }

    var grouped: [String: [ImportedSnippetPayload]] = [:]
    for row in rows.dropFirst(startIndex) {
      guard row.count >= 2 else { continue }
      let abbr = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let body = row[1]
      guard !body.isEmpty else { continue }
      let name = row.count >= 3 ? row[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
      let colName = row.count >= 4 && !row[3].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? row[3].trimmingCharacters(in: .whitespacesAndNewlines)
        : defaultCollectionName

      grouped[colName, default: []].append(
        ImportedSnippetPayload(
          name: name,
          abbreviation: abbr,
          content: body,
          triggerMode: abbr.isEmpty ? .manualOnly : .immediate
        )
      )
    }

    let cols = grouped.keys.sorted().compactMap { key -> ImportedCollectionPayload? in
      guard let items = grouped[key], !items.isEmpty else { return nil }
      return ImportedCollectionPayload(name: key, items: items)
    }
    guard !cols.isEmpty else { throw SnippetImportError.emptyImport }
    return SnippetImportPayload(collections: cols, sourceDescription: "CSV/TSV (\(defaultCollectionName))")
  }

  private static func parseDelimitedRows(_ text: String, delimiter: Character) -> [[String]] {
    var rows: [[String]] = []
    var currentRow: [String] = []
    var currentField = ""
    var inQuotes = false
    let chars = Array(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
    var idx = 0

    while idx < chars.count {
      let ch = chars[idx]
      if inQuotes {
        if ch == "\"" {
          if idx + 1 < chars.count && chars[idx + 1] == "\"" {
            currentField.append("\"")
            idx += 2
            continue
          } else {
            inQuotes = false
          }
        } else {
          currentField.append(ch)
        }
      } else {
        if ch == "\"" {
          inQuotes = true
        } else if ch == delimiter {
          currentRow.append(currentField)
          currentField = ""
        } else if ch.isNewline {
          currentRow.append(currentField)
          currentField = ""
          if currentRow.contains(where: { !$0.isEmpty }) {
            rows.append(currentRow)
          }
          currentRow = []
        } else {
          currentField.append(ch)
        }
      }
      idx += 1
    }

    if !currentField.isEmpty || !currentRow.isEmpty {
      currentRow.append(currentField)
      if currentRow.contains(where: { !$0.isEmpty }) {
        rows.append(currentRow)
      }
    }
    return rows
  }

  static func exportToJSONData(collections: [SnippetCollection], items: [SnippetItem]) throws -> Data {
    var db = SnippetSyncDatabase(
      version: 1,
      updatedAt: Date.now,
      deviceName: Host.current().localizedName ?? "Mac",
      collections: Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) }),
      items: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    )
    db.updatedAt = Date.now
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(db)
  }

  static func exportToCSVString(collections: [SnippetCollection], items: [SnippetItem]) -> String {
    let colNames = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.name) })
    var lines = ["\u{FEFF}Abbreviation,Content,Name,Collection"]
    for item in items where !item.isDeleted {
      let colName = colNames[item.collectionId] ?? "Default"
      lines.append(
        [
          escapeCSVField(item.abbreviation),
          escapeCSVField(item.content),
          escapeCSVField(item.name),
          escapeCSVField(colName)
        ].joined(separator: ",")
      )
    }
    return lines.joined(separator: "\r\n")
  }

  private static func escapeCSVField(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
      return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return value
  }

  // MARK: - 4. Built-in Ready-Made Starter Packs

  static func starterPackPayload(for pack: SnippetStarterPackID) -> SnippetImportPayload {
    switch pack {
    case .academicSymbols:
      let items: [ImportedSnippetPayload] = [
        .init(name: "Cộng trừ (±)", abbreviation: ";pm", content: "±"),
        .init(name: "Nhỏ hơn hoặc bằng (≤)", abbreviation: ";le", content: "≤"),
        .init(name: "Lớn hơn hoặc bằng (≥)", abbreviation: ";ge", content: "≥"),
        .init(name: "Khác (≠)", abbreviation: ";ne", content: "≠"),
        .init(name: "Xấp xỉ (≈)", abbreviation: ";ap", content: "≈"),
        .init(name: "Độ (°)", abbreviation: ";deg", content: "°"),
        .init(name: "Mũi tên phải (→)", abbreviation: ";ar", content: "→"),
        .init(name: "Mũi tên trái (←)", abbreviation: ";al", content: "←"),
        .init(name: "Mũi tên hai chiều (↔)", abbreviation: ";ab", content: "↔"),
        .init(name: "Chi-square (χ²)", abbreviation: ";chi2", content: "χ²"),
        .init(name: "Alpha (α)", abbreviation: ";alpha", content: "α"),
        .init(name: "Beta (β)", abbreviation: ";beta", content: "β"),
        .init(name: "p < 0.05", abbreviation: ";p05", content: "p < 0.05"),
        .init(name: "p < 0.01", abbreviation: ";p01", content: "p < 0.01"),
        .init(name: "p < 0.001", abbreviation: ";p001", content: "p < 0.001"),
        .init(name: "Khoảng tin cậy 95% CI", abbreviation: ";ci95", content: "95% CI: [{{cursor}}]"),
        .init(name: "Mean ± SD", abbreviation: ";msd", content: "{{input:Mean}} ± {{input:SD}}")
      ]
      return SnippetImportPayload(
        collections: [
          ImportedCollectionPayload(
            name: "Ký hiệu Học thuật & Thống kê",
            icon: "function",
            isEnabled: true,
            items: items
          )
        ],
        sourceDescription: pack.title
      )

    case .dynamicTemplates:
      let replyBody = """
      Kính gửi {{select:Danh xưng|*Anh|Chị|Thầy|Cô|PGS.TS.|TS.}} {{input:Họ và tên}},

      Cảm ơn {{select:Danh xưng|*Anh|Chị|Thầy|Cô|PGS.TS.|TS.}} đã gửi thông tin về {{input:Chủ đề=bản thảo nghiên cứu}}.
      Tôi xin phép phản hồi chi tiết trước ngày {{date +3bd:dd/MM/yyyy}} (3 ngày làm việc tới).
      {{optional:Đính kèm tài liệu=1}}
      Đính kèm theo email này là tài liệu cập nhật để tham khảo trước.{{/optional}}

      Trân trọng,
      {{cursor}}
      """
      let items: [ImportedSnippetPayload] = [
        .init(name: "Ngày hôm nay (dd/MM/yyyy)", abbreviation: ";today", content: "{{date:dd/MM/yyyy}}"),
        .init(name: "Ngày chuẩn ISO (yyyy-MM-dd)", abbreviation: ";isod", content: "{{isodate}}"),
        .init(name: "Ngày giờ hiện tại", abbreviation: ";now", content: "{{datetime:dd/MM/yyyy HH:mm}}"),
        .init(name: "Hạn +5 ngày làm việc", abbreviation: ";dl5", content: "{{date +5bd:dd/MM/yyyy}}"),
        .init(name: "Email phản hồi tương tác (Fill-in)", abbreviation: ";reply", content: replyBody),
        .init(name: "Trích dẫn nhanh từ Clipboard", abbreviation: ";quote", content: "> {{clipboard}}\n{{cursor}}")
      ]
      return SnippetImportPayload(
        collections: [
          ImportedCollectionPayload(
            name: "Mẫu Động & Biểu mẫu Fill-in",
            icon: "wand.and.stars",
            isEnabled: true,
            items: items
          )
        ],
        sourceDescription: pack.title
      )

    case .academicAutoCorrect:
      let pairs: [(String, String)] = [
        ("teh", "the"),
        ("recieve", "receive"),
        ("seperate", "separate"),
        ("occured", "occurred"),
        ("definately", "definitely"),
        ("accomodate", "accommodate"),
        ("enviroment", "environment"),
        ("statisics", "statistics"),
        ("quesionnaire", "questionnaire"),
        ("prevelance", "prevalence"),
        ("signficant", "significant"),
        ("signficantly", "significantly"),
        ("independant", "independent")
      ]
      let items = pairs.map { wrong, right in
        ImportedSnippetPayload(
          name: "\(wrong) → \(right)",
          abbreviation: wrong,
          content: right,
          contentMode: .plainText,
          triggerMode: .afterDelimiter,
          caseMode: .propagateCase,
          wholeWord: true,
          isEnabled: true
        )
      }
      return SnippetImportPayload(
        collections: [
          ImportedCollectionPayload(
            name: "AutoCorrect (Tiếng Anh Học thuật)",
            icon: "text.badge.checkmark",
            isEnabled: true,
            items: items
          )
        ],
        sourceDescription: pack.title
      )
    }
  }
}
