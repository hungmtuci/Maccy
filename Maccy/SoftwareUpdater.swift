import AppKit
import Defaults
import Foundation
import Observation
import SwiftUI

private nonisolated struct GitHubReleaseAsset: Decodable, Sendable {
  let name: String
  let browserDownloadURL: String
  let size: Int64

  enum CodingKeys: String, CodingKey {
    case name
    case browserDownloadURL = "browser_download_url"
    case size
  }
}

private nonisolated struct GitHubReleaseResponse: Decodable, Sendable {
  let tagName: String
  let htmlURL: String
  let name: String?
  let body: String?
  let publishedAt: String?
  let assets: [GitHubReleaseAsset]?

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
    case name
    case body
    case publishedAt = "published_at"
    case assets
  }
}

/// Native macOS GitHub Releases Auto-Updater for `https://github.com/hungmtuci/Maccy/releases`.
/// Supports silent background version checks, a Sparkle-style macOS update window with release notes,
/// live download progress, automatic Gatekeeper quarantine removal (`xattr -cr`), atomic `.app`
/// replacement, and automatic relaunch.
@Observable
@MainActor
final class SoftwareUpdater {
  static let shared = SoftwareUpdater()

  static let releasesPageURL = URL(string: "https://github.com/hungmtuci/Maccy/releases")!
  private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/hungmtuci/Maccy/releases/latest")!

  var isChecking: Bool = false
  var isInstallingUpdate: Bool = false
  var downloadProgress: Double = 0.0
  var statusMessage: String = ""
  var errorMessage: String?
  var availableReleaseTag: String?

  fileprivate var pendingRelease: GitHubReleaseResponse?
  private var updateWindow: NSWindow?
  private var activeDownloadTask: Task<Void, Never>?

  var automaticallyChecksForUpdates: Bool = Defaults[.automaticallyChecksCustomUpdates] {
    didSet {
      guard automaticallyChecksForUpdates != oldValue else { return }
      Defaults[.automaticallyChecksCustomUpdates] = automaticallyChecksForUpdates
      if automaticallyChecksForUpdates {
        checkSilentlyIfDue()
      }
    }
  }

  init() {
    #if DEBUG
    if History.isRunningUnitTests { return }
    #endif

    if automaticallyChecksForUpdates {
      checkSilentlyIfDue()
    }
  }

  var currentVersionString: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "3.1.0-custom"
  }

  func checkForUpdates() {
    guard !isChecking, !isInstallingUpdate else {
      if updateWindow != nil {
        showUpdateWindow()
      }
      return
    }
    isChecking = true
    errorMessage = nil
    statusMessage = "Đang kiểm tra phiên bản trên GitHub…"
    Task { @MainActor in
      defer { isChecking = false }
      await performUpdateCheck(userInitiated: true)
    }
  }

  func checkSilentlyIfDue() {
    if let lastCheck = Defaults[.lastCustomUpdateCheckAt],
       Date.now.timeIntervalSince(lastCheck) < 43_200 {
      return
    }
    guard !isChecking, !isInstallingUpdate else { return }
    Task { @MainActor in
      isChecking = true
      defer { isChecking = false }
      await performUpdateCheck(userInitiated: false)
    }
  }

  private func performUpdateCheck(userInitiated: Bool) async {
    var request = URLRequest(url: Self.latestReleaseAPIURL)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Maccy-Custom-Updater", forHTTPHeaderField: "User-Agent")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 12

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        statusMessage = "Không thể kết nối GitHub Releases."
        if userInitiated {
          NSWorkspace.shared.open(Self.releasesPageURL)
        }
        return
      }

      let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
      Defaults[.lastCustomUpdateCheckAt] = Date.now

      let localVer = currentVersionString
      let hasNewer = Self.isRemoteVersionNewer(release.tagName, than: localVer)

      if hasNewer {
        pendingRelease = release
        availableReleaseTag = release.tagName
        statusMessage = "Đã có bản cập nhật mới: \(release.tagName)"
        showUpdateWindow()
      } else {
        availableReleaseTag = nil
        statusMessage = "Đang dùng phiên bản mới nhất (\(localVer))."
        if userInitiated {
          presentUpToDateAlert(localVersion: localVer, url: URL(string: release.htmlURL) ?? Self.releasesPageURL)
        }
      }
    } catch {
      statusMessage = "Lỗi kiểm tra cập nhật: \(error.localizedDescription)"
      if userInitiated {
        NSWorkspace.shared.open(Self.releasesPageURL)
      }
    }
  }

  // MARK: - Native macOS Update Window & 1-Click Auto-Installer

  func showUpdateWindow() {
    guard pendingRelease != nil else { return }
    AppState.shared.popup.close()

    if let existing = updateWindow {
      NSApp.activate(ignoringOtherApps: true)
      existing.makeKeyAndOrderFront(nil)
      return
    }

    let hosting = NSHostingController(rootView: GitHubUpdateSheetView(updater: self))
    let win = NSWindow(contentViewController: hosting)
    win.title = "Cập nhật phần mềm Maccy"
    win.styleMask = [.titled, .closable]
    win.setContentSize(NSSize(width: 540, height: 370))
    win.isReleasedWhenClosed = false
    win.center()
    win.level = .floating

    self.updateWindow = win
    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
  }

  func dismissUpdateWindow() {
    if isInstallingUpdate {
      activeDownloadTask?.cancel()
      activeDownloadTask = nil
      isInstallingUpdate = false
    }
    updateWindow?.orderOut(nil)
  }

  func startDownloadAndInstall() {
    guard let release = pendingRelease, !isInstallingUpdate else { return }

    let zipAsset = release.assets?.first {
      $0.name.lowercased().hasSuffix(".zip") && $0.name.lowercased().contains("maccy")
    } ?? release.assets?.first {
      $0.name.lowercased().hasSuffix(".zip")
    }

    guard let asset = zipAsset, let assetURL = URL(string: asset.browserDownloadURL) else {
      if let pageURL = URL(string: release.htmlURL) {
        NSWorkspace.shared.open(pageURL)
      } else {
        NSWorkspace.shared.open(Self.releasesPageURL)
      }
      return
    }

    isInstallingUpdate = true
    errorMessage = nil
    downloadProgress = 0.02
    statusMessage = "Đang kết nối tải gói \(asset.name)…"

    activeDownloadTask = Task { @MainActor in
      let stageRoot = URL(fileURLWithPath: "/tmp/maccy_autoupdate_\(UUID().uuidString)")
      do {
        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
        let zipPath = stageRoot.appendingPathComponent(asset.name)

        var req = URLRequest(url: assetURL)
        req.setValue("Maccy-Custom-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 120

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
          throw NSError(domain: "MaccyUpdater", code: http.statusCode, userInfo: [
            NSLocalizedDescriptionKey: "Máy chủ trả về mã lỗi HTTP \(http.statusCode)."
          ])
        }

        let expectedTotal = response.expectedContentLength > 0 ? response.expectedContentLength : asset.size
        FileManager.default.createFile(atPath: zipPath.path, contents: nil)
        let handle = try FileHandle(forWritingTo: zipPath)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(65_536)

        for try await byte in asyncBytes {
          try Task.checkCancellation()
          buffer.append(byte)
          if buffer.count >= 65_536 {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            updateDownloadProgress(received: received, expected: expectedTotal)
          }
        }
        if !buffer.isEmpty {
          try handle.write(contentsOf: buffer)
          received += Int64(buffer.count)
          buffer.removeAll()
        }
        try handle.close()

        downloadProgress = 0.90
        statusMessage = "Đang giải nén & kiểm tra chữ ký ứng dụng…"

        let unpackedDir = stageRoot.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpackedDir, withIntermediateDirectories: true)

        try await Self.runSubprocess(
          executable: "/usr/bin/ditto",
          arguments: ["-x", "-k", zipPath.path, unpackedDir.path]
        )

        guard let extractedApp = Self.findAppBundle(in: unpackedDir) else {
          throw NSError(domain: "MaccyUpdater", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Không tìm thấy gói Maccy.app hợp lệ bên trong tệp nén."
          ])
        }

        // Remove Gatekeeper quarantine attributes automatically (`xattr -cr`)
        _ = try? await Self.runSubprocess(
          executable: "/usr/bin/xattr",
          arguments: ["-cr", extractedApp.path]
        )

        // Verify valid bundle signature before replacing installed app
        try await Self.runSubprocess(
          executable: "/usr/bin/codesign",
          arguments: ["--verify", "--deep", extractedApp.path]
        )

        downloadProgress = 0.98
        statusMessage = "Đang cập nhật ứng dụng & tự động khởi động lại…"
        try await Task.sleep(for: .milliseconds(250))

        try launchDetachedInstallerAndQuit(
          extractedAppURL: extractedApp,
          stageRootURL: stageRoot
        )
      } catch is CancellationError {
        try? FileManager.default.removeItem(at: stageRoot)
        isInstallingUpdate = false
        downloadProgress = 0
        statusMessage = "Đã huỷ tải bản cập nhật."
      } catch {
        try? FileManager.default.removeItem(at: stageRoot)
        isInstallingUpdate = false
        downloadProgress = 0
        errorMessage = error.localizedDescription
        statusMessage = "Cập nhật thất bại."
      }
    }
  }

  private func updateDownloadProgress(received: Int64, expected: Int64) {
    let mbFormatter = ByteCountFormatter()
    mbFormatter.allowedUnits = [.useMB]
    mbFormatter.countStyle = .file
    let recStr = mbFormatter.string(fromByteCount: received)

    if expected > 0 {
      let ratio = min(max(Double(received) / Double(expected), 0.02), 0.88)
      downloadProgress = ratio
      let expStr = mbFormatter.string(fromByteCount: expected)
      let pct = Int((Double(received) / Double(expected)) * 100)
      statusMessage = "Đang tải về… \(min(pct, 100))% (\(recStr) / \(expStr))"
    } else {
      downloadProgress = 0.5
      statusMessage = "Đang tải về… (\(recStr))"
    }
  }

  private func launchDetachedInstallerAndQuit(extractedAppURL: URL, stageRootURL: URL) throws {
    let currentBundleURL = Bundle.main.bundleURL
    let targetAppPath: String
    if currentBundleURL.pathExtension == "app" && !currentBundleURL.path.hasPrefix("/Volumes/") {
      targetAppPath = currentBundleURL.path
    } else {
      targetAppPath = "/Applications/Maccy.app"
    }

    let currentPID = ProcessInfo.processInfo.processIdentifier
    let scriptURL = stageRootURL.appendingPathComponent("apply_update.sh")
    let parentDir = (targetAppPath as NSString).deletingLastPathComponent
    let isDirectlyWritable = FileManager.default.isWritableFile(atPath: parentDir)

    let scriptContent: String
    if isDirectlyWritable {
      scriptContent = """
      #!/bin/sh
      OLD_PID="\(currentPID)"
      SRC_APP="\(extractedAppURL.path)"
      DST_APP="\(targetAppPath)"
      STAGE_DIR="\(stageRootURL.path)"

      i=0
      while kill -0 "$OLD_PID" 2>/dev/null && [ $i -lt 80 ]; do
        sleep 0.1
        i=$((i + 1))
      done

      rm -rf "$DST_APP"
      /usr/bin/ditto --norsrc "$SRC_APP" "$DST_APP"
      /usr/bin/xattr -cr "$DST_APP" 2>/dev/null || true
      /usr/bin/open "$DST_APP"
      rm -rf "$STAGE_DIR"
      """
    } else {
      let escapedSrc = extractedAppURL.path.replacingOccurrences(of: "'", with: "'\\''")
      let escapedDst = targetAppPath.replacingOccurrences(of: "'", with: "'\\''")
      scriptContent = """
      #!/bin/sh
      OLD_PID="\(currentPID)"
      STAGE_DIR="\(stageRootURL.path)"

      i=0
      while kill -0 "$OLD_PID" 2>/dev/null && [ $i -lt 80 ]; do
        sleep 0.1
        i=$((i + 1))
      done

      /usr/bin/osascript -e "do shell script \\"rm -rf '\(escapedDst)' && /usr/bin/ditto --norsrc '\(escapedSrc)' '\(escapedDst)' && /usr/bin/xattr -cr '\(escapedDst)'\\" with administrator privileges"
      /usr/bin/open "\(targetAppPath)"
      rm -rf "$STAGE_DIR"
      """
    }

    try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let launcher = Process()
    launcher.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
    launcher.arguments = ["/bin/sh", scriptURL.path]
    launcher.standardOutput = FileHandle.nullDevice
    launcher.standardError = FileHandle.nullDevice
    try launcher.run()

    NSApp.terminate(nil)
  }

  private nonisolated static func findAppBundle(in root: URL) -> URL? {
    let direct = root.appendingPathComponent("Maccy.app")
    if FileManager.default.fileExists(atPath: direct.appendingPathComponent("Contents/MacOS/Maccy").path) {
      return direct
    }
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return nil
    }
    for case let url as URL in enumerator where url.pathExtension == "app" {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/Maccy").path) {
        return url
      }
    }
    return nil
  }

  private nonisolated static func runSubprocess(executable: String, arguments: [String]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        do {
          try proc.run()
          let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
          proc.waitUntilExit()
          if proc.terminationStatus == 0 {
            continuation.resume()
          } else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            continuation.resume(throwing: NSError(
              domain: "MaccyUpdater",
              code: Int(proc.terminationStatus),
              userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Lệnh \(executable) thất bại (\(proc.terminationStatus))." : msg]
            ))
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func presentUpToDateAlert(localVersion: String, url: URL) {
    AppState.shared.suppressPopupAutoClose = true
    defer { AppState.shared.suppressPopupAutoClose = false }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Maccy đã ở phiên bản mới nhất"
    alert.informativeText = "Phiên bản hiện tại (\(localVersion)) là bản phát hành mới nhất trên GitHub (hungmtuci/Maccy)."
    alert.addButton(withTitle: "Đóng")
    alert.addButton(withTitle: "Xem trang GitHub")

    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertSecondButtonReturn {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Semantic Version Comparison

  nonisolated static func isRemoteVersionNewer(_ remoteTag: String, than localVersion: String) -> Bool {
    let remoteParts = parseNumericComponents(from: remoteTag)
    let localParts = parseNumericComponents(from: localVersion)
    let count = max(remoteParts.count, localParts.count)
    guard count > 0 else { return false }

    for idx in 0..<count {
      let rVal = idx < remoteParts.count ? remoteParts[idx] : 0
      let lVal = idx < localParts.count ? localParts[idx] : 0
      if rVal != lVal {
        return rVal > lVal
      }
    }
    return false
  }

  private nonisolated static func parseNumericComponents(from version: String) -> [Int] {
    var cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
      cleaned.removeFirst()
    }
    let corePart = cleaned.split(separator: "-", maxSplits: 1).first.map(String.init) ?? cleaned
    return corePart
      .split(separator: ".")
      .compactMap { Int($0) }
  }
}

// MARK: - Native macOS Sparkle-Style Update View

private struct GitHubUpdateSheetView: View {
  @Bindable var updater: SoftwareUpdater

  private var releaseTag: String {
    updater.pendingRelease?.tagName ?? "Mới"
  }

  private var releaseTitle: String {
    if let name = updater.pendingRelease?.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return name
    }
    return "Maccy \(releaseTag)"
  }

  private var releaseNotes: String {
    let raw = (updater.pendingRelease?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? "Cải tiến hiệu năng, độ ổn định và đồng bộ dữ liệu." : raw
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 60, height: 60)

        VStack(alignment: .leading, spacing: 4) {
          Text("Có bản cập nhật mới cho Maccy!")
            .font(.system(size: 15, weight: .bold))

          Text("\(releaseTitle) hiện đã sẵn sàng để tải về. Bạn đang dùng phiên bản \(updater.currentVersionString).")
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Text(" Điểm mới trong phiên bản này:")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      ScrollView {
        Text(releaseNotes)
          .font(.system(size: 12))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10), lineWidth: 1))
      .frame(minHeight: 145)

      if updater.isInstallingUpdate {
        VStack(alignment: .leading, spacing: 5) {
          ProgressView(value: updater.downloadProgress, total: 1.0)
            .progressViewStyle(.linear)
          Text(updater.statusMessage)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
      } else if let err = updater.errorMessage {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text("Lỗi tự động cập nhật: \(err)")
            .font(.system(size: 11.5))
            .foregroundStyle(.red)
            .lineLimit(2)
        }
      }

      HStack(spacing: 10) {
        Button("Xem trên GitHub ↗") {
          if let html = updater.pendingRelease?.htmlURL, let url = URL(string: html) {
            NSWorkspace.shared.open(url)
          } else {
            NSWorkspace.shared.open(SoftwareUpdater.releasesPageURL)
          }
        }
        .buttonStyle(.link)
        .controlSize(.small)

        Spacer()

        Button(updater.isInstallingUpdate ? "Huỷ" : "Để sau") {
          updater.dismissUpdateWindow()
        }
        .keyboardShortcut(.cancelAction)

        Button {
          updater.startDownloadAndInstall()
        } label: {
          Label("Cập nhật & Khởi động lại", systemImage: "arrow.down.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(updater.isInstallingUpdate)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
  }
}
