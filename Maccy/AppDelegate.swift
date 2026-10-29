import Defaults
import KeyboardShortcuts
#if canImport(Sparkle)
import Sparkle
#endif
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  nonisolated static let isTesting = CommandLine.arguments.contains("enable-testing")
  var panel: FloatingPanel<ContentView>!

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem.button?.image = Defaults[.menuIcon].image
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.target = self
    return statusItem
  }()

  // Base accessibility label for the status item; kept separate from the optional
  // dynamic `title` (recent copy text) so VoiceOver always announces something
  // meaningful even when that preference is off or the app is disabled.
  private func updateStatusItemAccessibilityLabel() {
    var accessibilityLabel = NSLocalizedString("status_item_accessibility_label", comment: "")
    if isStatusItemDisabled {
      accessibilityLabel += " — \(NSLocalizedString("status_item_disabled_accessibility_suffix", comment: ""))"
    }
    statusItem.button?.setAccessibilityLabel(accessibilityLabel)
  }

  private var isStatusItemDisabled: Bool {
    Defaults[.ignoreEvents] || Defaults[.enabledPasteboardTypes].isEmpty
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    #if DEBUG
    if Self.isTesting {
      #if canImport(Sparkle)
      SPUUpdater(hostBundle: Bundle.main,
                 applicationBundle: Bundle.main,
                 userDriver: SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil),
                 delegate: nil)
      .automaticallyChecksForUpdates = false
      #endif
      // Start from a clean slate for the isolated testing preferences.
      UserDefaults.standard.removePersistentDomain(forName: Defaults.Keys.testingSuiteName)
    }
    #endif

    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self

    Clipboard.shared.onNewCopy { History.shared.add($0) }
    Clipboard.shared.start()

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = value.image
      }
    }

    synchronizeMenuIconText()
    Task {
      for await value in Defaults.updates(.showRecentCopyInMenuBar) {
        if value {
          statusItem.button?.title = AppState.shared.menuIconText
        } else {
          statusItem.button?.title = ""
        }
      }
    }

    updateStatusItemAccessibilityLabel()

    Task {
      for await _ in Defaults.updates(.ignoreEvents) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }

    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    ensureStandardEditMenu()
    migrateUserDefaults()
    disableUnusedGlobalHotkeys()

    KeyboardShortcuts.onKeyDown(for: .pasteLatestPlainText) {
      Clipboard.shared.pasteLatestPlainText()
    }

    if !Self.isTesting {
      _ = SnippetStore.shared
      _ = SoftwareUpdater.shared
      TextExpansionEngine.shared.start()
    }

    panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
      identifier: Bundle.main.bundleIdentifier ?? "org.p0deje.Maccy",
      statusBarButton: statusItem.button,
      onClose: { AppState.shared.popup.reset() }
    ) {
      ContentView()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel?.toggle(height: AppState.shared.popup.height)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    if Defaults[.clearOnQuit] {
      AppState.shared.history.clear()
    }
  }

  private func ensureMigration(key: String, _ action: () -> Void) {
    if Defaults[.migrations][key] != true {
      action()
      Defaults[.migrations][key] = true
    }
  }

  @MainActor
  private func migrateUserDefaults() {
    ensureMigration(key: "2024-07-01-version-2") {
      // Start 2.x from scratch.
      Defaults.reset(.migrations)

      // Inverse hide* configuration keys.
      Defaults[.showFooter] = !UserDefaults.standard.bool(forKey: "hideFooter")
      Defaults[.showSearch] = !UserDefaults.standard.bool(forKey: "hideSearch")
      Defaults[.showTitle] = !UserDefaults.standard.bool(forKey: "hideTitle")
      UserDefaults.standard.removeObject(forKey: "hideFooter")
      UserDefaults.standard.removeObject(forKey: "hideSearch")
      UserDefaults.standard.removeObject(forKey: "hideTitle")
    }

    ensureMigration(key: "2025-07-04-add-jpeg-heic") {
      var types = Defaults[.enabledPasteboardTypes]
      if !types.isDisjoint(with: StorageType.images.types) {
        types.formUnion(StorageType.images.types)
      }
      Defaults[.enabledPasteboardTypes] = types
    }

    ensureMigration(key: "2026-08-12-cleanup-orphaned-history-item-contents") {
      _ = try? Storage.shared.cleanupOrphanedContents()
    }

    ensureMigration(key: "2026-08-31-sanitize-history-item-titles") {
      _ = try? Storage.shared.sanitizeTitles()
    }

    ensureMigration(key: "2026-09-15-remove-unpersistable-contents") {
      _ = try? Storage.shared.removeUnpersistableContents()
    }

    ensureMigration(key: "2026-10-21-default-popup-cmd-shift-v") {
      KeyboardShortcuts.Name.popup.shortcut = KeyboardShortcuts.Shortcut(.v, modifiers: [.command, .shift])
    }

    ensureMigration(key: "2026-10-25-default-cmd-shift-c-plain-text") {
      UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_popupLegacy")
      if KeyboardShortcuts.Name.popup.shortcut == KeyboardShortcuts.Shortcut(.c, modifiers: [.command, .shift]) {
        KeyboardShortcuts.Name.popup.shortcut = KeyboardShortcuts.Shortcut(.v, modifiers: [.command, .shift])
      }
      KeyboardShortcuts.Name.pasteLatestPlainText.shortcut = KeyboardShortcuts.Shortcut(.c, modifiers: [.command, .shift])
    }

    ensureMigration(key: "2026-10-29-default-snippets-cmd-shift-s") {
      if KeyboardShortcuts.Name.snippetsPopup.shortcut == nil {
        KeyboardShortcuts.Name.snippetsPopup.shortcut = KeyboardShortcuts.Shortcut(.s, modifiers: [.command, .shift])
      }
    }

    // The following defaults are not used in Maccy 2.x
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  @objc
  private func performStatusItemClick() {
    let currentEvent = NSApp.currentEvent
    let modifierFlags = (currentEvent?.modifierFlags ?? [])
      .union(NSEvent.modifierFlags)
      .intersection(.deviceIndependentFlagsMask)

    if currentEvent?.type == .rightMouseUp || modifierFlags.contains(.control) {
      let contextMenu = buildStatusBarContextMenu()
      statusItem.menu = contextMenu
      statusItem.button?.performClick(nil)
      statusItem.menu = nil
      return
    }

    if modifierFlags.contains(.option) {
      Defaults[.ignoreEvents].toggle()

      if modifierFlags.contains(.shift) {
        Defaults[.ignoreOnlyNextEvent] = Defaults[.ignoreEvents]
      }

      return
    }

    panel.toggle(height: AppState.shared.popup.height, at: .statusItem)
  }

  @MainActor
  private func buildStatusBarContextMenu() -> NSMenu {
    let menu = NSMenu(title: "Maccy")
    let symConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)

    func makeItem(
      _ title: String,
      symbol: String? = nil,
      key: String = "",
      modifiers: NSEvent.ModifierFlags = [.command],
      state: NSControl.StateValue = .off,
      action: Selector
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = self
      item.state = state
      if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
        item.image = img.withSymbolConfiguration(symConfig)
      }
      return item
    }

    menu.addItem(makeItem(
      "Lịch sử Clipboard",
      symbol: "list.clipboard",
      key: "v",
      modifiers: [.command, .shift],
      action: #selector(menuOpenClipboardPopup)
    ))
    menu.addItem(makeItem(
      "Tìm nhanh Gõ tắt",
      symbol: "bolt.horizontal",
      key: "s",
      modifiers: [.command, .shift],
      action: #selector(menuOpenSnippetsPopup)
    ))
    menu.addItem(makeItem(
      "Dán văn bản thuần gần nhất",
      symbol: "doc.plaintext",
      key: "c",
      modifiers: [.command, .shift],
      action: #selector(menuPasteLatestPlainText)
    ))

    menu.addItem(.separator())

    menu.addItem(makeItem(
      "Quản lý Gõ tắt (Snippet Studio)…",
      symbol: "square.split.2x1",
      key: "m",
      modifiers: [.command],
      action: #selector(menuOpenSnippetStudio)
    ))

    if Defaults[.cloudSyncEnabled] && !Defaults[.cloudSyncFolderPath].isEmpty {
      menu.addItem(makeItem(
        "Đồng bộ Google Drive ngay",
        symbol: "arrow.triangle.2.circlepath.icloud",
        action: #selector(menuSyncGoogleDriveNow)
      ))
    }

    menu.addItem(.separator())

    menu.addItem(makeItem(
      "Tự động bung Gõ tắt",
      symbol: "bolt",
      state: Defaults[.textExpansionEnabled] ? .on : .off,
      action: #selector(menuToggleTextExpansion)
    ))
    menu.addItem(makeItem(
      "Tạm dừng ghi Clipboard",
      symbol: "pause.circle",
      state: Defaults[.ignoreEvents] ? .on : .off,
      action: #selector(menuToggleIgnoreEvents)
    ))
    menu.addItem(makeItem(
      "Dọn dẹp lịch sử chưa ghim",
      symbol: "trash",
      action: #selector(menuClearUnpinnedHistory)
    ))

    menu.addItem(.separator())

    menu.addItem(makeItem(
      "Cài đặt…",
      symbol: "gearshape",
      key: ",",
      modifiers: [.command],
      action: #selector(menuOpenSettings)
    ))

    let updateTitle: String
    if let newTag = SoftwareUpdater.shared.availableReleaseTag {
      updateTitle = "Cập nhật phiên bản mới (\(newTag))…"
    } else {
      updateTitle = "Kiểm tra cập nhật (GitHub)…"
    }
    menu.addItem(makeItem(
      updateTitle,
      symbol: SoftwareUpdater.shared.availableReleaseTag != nil ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath",
      action: #selector(menuCheckForUpdates)
    ))

    menu.addItem(makeItem(
      "Giới thiệu về Maccy",
      symbol: "info.circle",
      action: #selector(menuOpenAbout)
    ))

    menu.addItem(.separator())

    menu.addItem(makeItem(
      "Thoát Maccy",
      symbol: "power",
      key: "q",
      modifiers: [.command],
      action: #selector(menuQuitApp)
    ))

    return menu
  }

  @objc @MainActor private func menuOpenClipboardPopup() {
    AppState.shared.popupMode = .clipboard
    panel?.open(height: AppState.shared.popup.height, at: .statusItem)
  }

  @objc @MainActor private func menuOpenSnippetsPopup() {
    AppState.shared.popupMode = .snippets
    SnippetStore.shared.ensureValidPopupSelection()
    panel?.open(height: AppState.shared.popup.height, at: .statusItem)
  }

  @objc @MainActor private func menuPasteLatestPlainText() {
    Clipboard.shared.pasteLatestPlainText()
  }

  @objc @MainActor private func menuOpenSnippetStudio() {
    AppState.shared.popup.close()
    SnippetManagerWindowController.shared.show()
  }

  @objc @MainActor private func menuSyncGoogleDriveNow() {
    Task { @MainActor in
      await CloudSyncManager.shared.syncNow()
      await SnippetStore.shared.syncWithGoogleDrive()
    }
  }

  @objc @MainActor private func menuToggleTextExpansion() {
    Defaults[.textExpansionEnabled].toggle()
  }

  @objc @MainActor private func menuToggleIgnoreEvents() {
    Defaults[.ignoreEvents].toggle()
  }

  @objc @MainActor private func menuClearUnpinnedHistory() {
    AppState.shared.history.clear()
  }

  @objc @MainActor private func menuOpenSettings() {
    AppState.shared.popup.close()
    AppState.shared.openPreferences()
  }

  @objc @MainActor private func menuCheckForUpdates() {
    AppState.shared.popup.close()
    SoftwareUpdater.shared.checkForUpdates()
  }

  @objc @MainActor private func menuOpenAbout() {
    AppState.shared.popup.close()
    AppState.shared.openAbout()
  }

  @objc private func menuQuitApp() {
    AppState.shared.quit()
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      DispatchQueue.main.async {
        if Defaults[.showRecentCopyInMenuBar] {
          self.statusItem.button?.title = AppState.shared.menuIconText
        }
        self.synchronizeMenuIconText()
      }
    }
  }

  private func disableUnusedGlobalHotkeys() {
    let names: [KeyboardShortcuts.Name] = [.delete, .pin, .togglePreview, .sync]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: .main
    ) { notification in
      guard let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
            names.contains(name) else { return }
      MainActor.assumeIsolated {
        KeyboardShortcuts.disable(name)
      }
    }
  }

  private func ensureStandardEditMenu() {
    let mainMenu = NSMenu()

    // 1. Application Menu ("Maccy")
    let appMenuItem = NSMenuItem(title: "Maccy", action: nil, keyEquivalent: "")
    let appMenu = NSMenu(title: "Maccy")
    let aboutItem = appMenu.addItem(withTitle: "Giới thiệu về Maccy", action: #selector(menuOpenAbout), keyEquivalent: "")
    aboutItem.target = self
    let updateItem = appMenu.addItem(withTitle: "Kiểm tra cập nhật (GitHub)…", action: #selector(menuCheckForUpdates), keyEquivalent: "")
    updateItem.target = self
    appMenu.addItem(.separator())
    let settingsItem = appMenu.addItem(withTitle: "Cài đặt…", action: #selector(menuOpenSettings), keyEquivalent: ",")
    settingsItem.target = self
    let studioItem = appMenu.addItem(withTitle: "Quản lý Gõ tắt…", action: #selector(menuOpenSnippetStudio), keyEquivalent: "m")
    studioItem.target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Ẩn Maccy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    let quitItem = appMenu.addItem(withTitle: "Thoát Maccy", action: #selector(menuQuitApp), keyEquivalent: "q")
    quitItem.target = self
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // 2. File Menu ("Tệp")
    let fileMenuItem = NSMenuItem(title: "Tệp", action: nil, keyEquivalent: "")
    let fileMenu = NSMenu(title: "Tệp")
    fileMenu.addItem(withTitle: "Đóng cửa sổ", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    // 3. Edit Menu ("Chỉnh sửa")
    let editMenuItem = NSMenuItem(title: "Chỉnh sửa", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Chỉnh sửa")
    editMenu.addItem(withTitle: "Hoàn tác", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "Làm lại", action: Selector(("redo:")), keyEquivalent: "Z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cắt", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Sao chép", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Chọn tất cả", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    // 4. Window Menu ("Cửa sổ")
    let windowMenuItem = NSMenuItem(title: "Cửa sổ", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "Cửa sổ")
    windowMenu.addItem(withTitle: "Thu nhỏ", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "")
    windowMenu.addItem(withTitle: "Thu phóng", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "Đưa tất cả lên trước", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    NSApp.mainMenu = mainMenu
    NSApp.windowsMenu = windowMenu
  }
}
