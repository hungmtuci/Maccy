import AppKit
import Defaults
import Foundation
import Observation

private nonisolated struct GitHubReleaseResponse: Decodable, Sendable {
  let tagName: String
  let htmlURL: String
  let name: String?
  let body: String?

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
    case name
    case body
  }
}

/// Safe custom fork updater checking `https://github.com/hungmtuci/Maccy/releases`
/// instead of upstream Sparkle (`p0deje/Maccy`) so custom features (Google Drive sync,
/// Vietnamese unaccented search, ⌘⇧C plain-text paste) are never overwritten by upstream builds.
@Observable
@MainActor
class SoftwareUpdater {
  static let releasesPageURL = URL(string: "https://github.com/hungmtuci/Maccy/releases")!
  private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/hungmtuci/Maccy/releases/latest")!

  var isChecking = false
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
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "3.0.0-custom"
  }

  func checkForUpdates() {
    guard !isChecking else { return }
    isChecking = true
    Task { @MainActor in
      defer { isChecking = false }
      await performUpdateCheck(userInitiated: true)
    }
  }

  private func checkSilentlyIfDue() {
    if let lastCheck = Defaults[.lastCustomUpdateCheckAt],
       Date.now.timeIntervalSince(lastCheck) < 86_400 {
      return
    }
    Task { @MainActor in
      await performUpdateCheck(userInitiated: false)
    }
  }

  private func performUpdateCheck(userInitiated: Bool) async {
    var request = URLRequest(url: Self.latestReleaseAPIURL)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Maccy-Custom-Updater", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 10

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        if userInitiated {
          NSWorkspace.shared.open(Self.releasesPageURL)
        }
        return
      }

      let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
      Defaults[.lastCustomUpdateCheckAt] = Date.now

      let localVer = currentVersionString
      let hasNewer = Self.isRemoteVersionNewer(release.tagName, than: localVer)
      let targetURL = URL(string: release.htmlURL) ?? Self.releasesPageURL

      if hasNewer {
        presentUpdateAvailableAlert(release: release, localVersion: localVer, url: targetURL)
      } else if userInitiated {
        presentUpToDateAlert(localVersion: localVer, url: targetURL)
      }
    } catch {
      if userInitiated {
        NSWorkspace.shared.open(Self.releasesPageURL)
      }
    }
  }

  private func presentUpdateAvailableAlert(release: GitHubReleaseResponse, localVersion: String, url: URL) {
    AppState.shared.suppressPopupAutoClose = true
    defer { AppState.shared.suppressPopupAutoClose = false }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Có bản cập nhật mới: \(release.tagName)"
    let notesPreview = (release.body ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .shortened(to: 350)
    alert.informativeText = notesPreview.isEmpty
      ? "Phiên bản hiện tại: \(localVersion).\nTải bản Maccy Custom mới nhất từ GitHub (hungmtuci/Maccy)."
      : "Phiên bản hiện tại: \(localVersion)\n\n\(notesPreview)"
    alert.addButton(withTitle: "Mở trang tải về (GitHub)")
    alert.addButton(withTitle: "Để sau")

    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(url)
    }
  }

  private func presentUpToDateAlert(localVersion: String, url: URL) {
    AppState.shared.suppressPopupAutoClose = true
    defer { AppState.shared.suppressPopupAutoClose = false }

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Bạn đang dùng bản mới nhất (\(localVersion))"
    alert.informativeText = "Maccy Custom Edition (hungmtuci/Maccy) hiện đã ở phiên bản mới nhất."
    alert.addButton(withTitle: "Đóng")
    alert.addButton(withTitle: "Xem trên GitHub")

    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertSecondButtonReturn {
      NSWorkspace.shared.open(url)
    }
  }

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
