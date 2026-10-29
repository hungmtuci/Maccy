import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
@preconcurrency import CoreGraphics
import Defaults
import Foundation
import Observation

@Observable
@MainActor
final class TextExpansionEngine {
  static let shared = TextExpansionEngine()

  /// Custom `CGEventField.eventSourceUserData` tag (`"MCYS"`) so synthetic Backspaces,
  /// keystrokes, and `⌘V` pastes emitted by Maccy never re-trigger `TextExpansionEngine`.
  nonisolated static let syntheticEventTag: Int64 = 0x4D43_5953

  // Observable live health state for Snippet Studio & Snippet Popup UI
  private(set) var isAccessibilityGranted: Bool = false
  private(set) var isInputMonitoringGranted: Bool = false
  private(set) var isEventTapActive: Bool = false
  private(set) var isSecureInputLocked: Bool = false
  private(set) var lastExpandedSummary: String = ""
  private(set) var lastExpandedAt: Date?

  /// Set to `true` only when the user focuses the dedicated "Ô gõ thử nghiệm" inside Snippet Studio,
  /// allowing live in-window testing while blocking expansion in snippet editor fields.
  var isStudioTestFieldFocused: Bool = false {
    didSet {
      if isStudioTestFieldFocused != oldValue {
        typingBuffer = ""
      }
    }
  }

  @ObservationIgnored private var eventTap: CFMachPort?
  @ObservationIgnored private var runLoopSource: CFRunLoopSource?
  @ObservationIgnored private var healthTimer: Timer?
  @ObservationIgnored private var appSwitchObserver: NSObjectProtocol?
  @ObservationIgnored private var defaultsTask: Task<Void, Never>?

  @ObservationIgnored private var typingBuffer: String = ""
  @ObservationIgnored private var isExpanding: Bool = false

  private static let delimiterCharacters: Set<Character> = [
    " ", "\t", "\n", "\r",
    ".", ",", ";", ":", "!", "?",
    "(", ")", "[", "]", "{", "}",
    "\"", "'", "/"
  ]

  private static let navigationAndResetKeyCodes: Set<UInt16> = [
    53,  // Escape
    115, // Home
    116, // PageUp
    117, // Forward Delete
    119, // End
    121, // PageDown
    123, // Left Arrow
    124, // Right Arrow
    125, // Down Arrow
    126  // Up Arrow
  ]

  func start() {
    refreshStatusAndEnsureEventTap()

    if appSwitchObserver == nil {
      appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.typingBuffer = ""
          self?.refreshStatusAndEnsureEventTap()
        }
      }
    }

    if healthTimer == nil {
      let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
        if Thread.isMainThread {
          MainActor.assumeIsolated {
            self?.refreshStatusAndEnsureEventTap()
          }
        } else {
          DispatchQueue.main.async { [weak self] in
            self?.refreshStatusAndEnsureEventTap()
          }
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      healthTimer = timer
    }

    if defaultsTask == nil {
      defaultsTask = Task { @MainActor [weak self] in
        for await enabled in Defaults.updates(.textExpansionEnabled, initial: false) {
          guard let self else { break }
          self.typingBuffer = ""
          if enabled {
            self.refreshStatusAndEnsureEventTap()
            if !self.isEventTapActive {
              Accessibility.check()
            }
          } else {
            self.tearDownEventTap()
            self.refreshPermissionFlags()
          }
        }
      }
    }
  }

  func stop() {
    healthTimer?.invalidate()
    healthTimer = nil
    defaultsTask?.cancel()
    defaultsTask = nil
    if let appSwitchObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
      self.appSwitchObserver = nil
    }
    tearDownEventTap()
    typingBuffer = ""
  }

  func resetBuffer() {
    typingBuffer = ""
  }

  // MARK: - Live Permission Health & 1-Click Stale-TCC Repair

  func refreshPermissionFlags() {
    let ax = AXIsProcessTrusted()
    let listen = CGPreflightListenEventAccess()
    let secure = IsSecureEventInputEnabled()
    if isAccessibilityGranted != ax { isAccessibilityGranted = ax }
    if isInputMonitoringGranted != listen { isInputMonitoringGranted = listen }
    if isSecureInputLocked != secure { isSecureInputLocked = secure }
  }

  func refreshStatusAndEnsureEventTap() {
    refreshPermissionFlags()

    guard Defaults[.textExpansionEnabled] else {
      if eventTap != nil {
        tearDownEventTap()
      }
      return
    }

    if let existingTap = eventTap {
      if !isAccessibilityGranted && !isInputMonitoringGranted {
        tearDownEventTap()
        return
      }
      if !CGEvent.tapIsEnabled(tap: existingTap) {
        CGEvent.tapEnable(tap: existingTap, enable: true)
      }
      let enabledNow = CGEvent.tapIsEnabled(tap: existingTap)
      if isEventTapActive != enabledNow {
        isEventTapActive = enabledNow
      }
      return
    }

    installEventTapIfPermitted()
  }

  /// Clears stale ad-hoc CDHash entries in macOS TCC for `org.p0deje.Maccy` (which happen whenever
  /// `/Applications/Maccy.app` is overwritten by a new custom build while System Settings still
  /// visually shows the toggle as ON), then triggers a fresh system prompt and opens Privacy Settings.
  func requestOrRepairAccessibilityPermission(resetStaleTCC: Bool = true) {
    let bundleId = Bundle.main.bundleIdentifier ?? "org.p0deje.Maccy"
    tearDownEventTap()

    DispatchQueue.global(qos: .userInitiated).async {
      if resetStaleTCC && !AXIsProcessTrusted() {
        for service in ["Accessibility", "ListenEvent"] {
          let proc = Process()
          proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
          proc.arguments = ["reset", service, bundleId]
          proc.standardOutput = FileHandle.nullDevice
          proc.standardError = FileHandle.nullDevice
          try? proc.run()
          proc.waitUntilExit()
        }
      }

      DispatchQueue.main.async {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if AXIsProcessTrusted() && !CGPreflightListenEventAccess() {
          _ = CGRequestListenEventAccess()
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
          }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
          NSWorkspace.shared.open(url)
        }

        self.refreshStatusAndEnsureEventTap()
      }
    }
  }

  func openAccessibilitySettingsPane() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }

  private func installEventTapIfPermitted() {
    guard eventTap == nil else { return }

    let mask: CGEventMask =
      (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.leftMouseDown.rawValue)
      | (1 << CGEventType.rightMouseDown.rawValue)
      | (1 << CGEventType.otherMouseDown.rawValue)

    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    let callback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
      guard let userInfo else {
        return Unmanaged.passUnretained(cgEvent)
      }
      let engine = Unmanaged<TextExpansionEngine>.fromOpaque(userInfo).takeUnretainedValue()
      if Thread.isMainThread {
        let swallow = MainActor.assumeIsolated {
          engine.shouldSwallowCGEvent(type: type, cgEvent: cgEvent)
        }
        return swallow ? nil : Unmanaged.passUnretained(cgEvent)
      }
      return Unmanaged.passUnretained(cgEvent)
    }

    // Prefer `.cgAnnotatedSessionEventTap` so `eventTargetUnixProcessID` identifies the exact
    // target app (including non-activating panels like Spotlight / Google Quick Search / Raycast).
    let createdTap = CGEvent.tapCreate(
      tap: .cgAnnotatedSessionEventTap,
      place: .tailAppendEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: callback,
      userInfo: selfPtr
    ) ?? CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .tailAppendEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: callback,
      userInfo: selfPtr
    )

    guard let tap = createdTap,
          let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      if isEventTapActive {
        isEventTapActive = false
      }
      return
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    self.eventTap = tap
    self.runLoopSource = source
    self.isEventTapActive = CGEvent.tapIsEnabled(tap: tap)
  }

  private func tearDownEventTap() {
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
      self.eventTap = nil
    }
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      self.runLoopSource = nil
    }
    if isEventTapActive {
      isEventTapActive = false
    }
  }

  // MARK: - Manual Expansion from ⌘⇧S Snippet Viewer or Studio

  func expandManually(_ item: SnippetItem, targetApp: NSRunningApplication?) {
    let clipboardString = NSPasteboard.general.string(forType: .string) ?? ""
    let fields = SnippetTemplateEngine.extractFillInFields(from: item)

    if !fields.isEmpty {
      SnippetFillInWindowController.shared.present(
        item: item,
        fields: fields,
        targetApp: targetApp,
        typedAbbreviation: nil,
        trailingDelimiter: nil,
        clipboardString: clipboardString
      )
      return
    }

    Task { @MainActor in
      isExpanding = true
      defer { isExpanding = false }

      let steps = await SnippetTemplateEngine.renderActionSteps(
        for: item,
        typedAbbreviation: nil,
        trailingDelimiter: nil,
        clipboardString: clipboardString
      )
      if Defaults[.expandPlaySound] {
        NSSound.write?.play()
      }
      SnippetStore.shared.recordUsage(for: item.id)
      lastExpandedSummary = item.displayTitle
      lastExpandedAt = Date.now
      await Clipboard.shared.performExpansionSteps(
        steps,
        targetApp: targetApp,
        restoreClipboard: Defaults[.restoreClipboardAfterExpansion],
        syntheticTag: Self.syntheticEventTag
      )
    }
  }

  func completeFillInExpansion(
    item: SnippetItem,
    targetApp: NSRunningApplication?,
    typedAbbreviation: String?,
    trailingDelimiter: String?,
    fillInValues: [String: String],
    optionalToggles: [String: Bool],
    clipboardString: String
  ) async {
    isExpanding = true
    defer { isExpanding = false }

    let steps = await SnippetTemplateEngine.renderActionSteps(
      for: item,
      typedAbbreviation: typedAbbreviation,
      trailingDelimiter: trailingDelimiter,
      fillInValues: fillInValues,
      optionalToggles: optionalToggles,
      clipboardString: clipboardString
    )
    if Defaults[.expandPlaySound] {
      NSSound.write?.play()
    }
    SnippetStore.shared.recordUsage(for: item.id)
    lastExpandedSummary = "\(typedAbbreviation ?? item.abbreviation) → \(item.displayTitle)"
    lastExpandedAt = Date.now
    await Clipboard.shared.performExpansionSteps(
      steps,
      targetApp: targetApp,
      restoreClipboard: Defaults[.restoreClipboardAfterExpansion],
      syntheticTag: Self.syntheticEventTag
    )
  }

  // MARK: - CoreGraphics Real-Time Keystroke Interceptor & Matcher

  private func shouldSwallowCGEvent(
    type: CGEventType,
    cgEvent: CGEvent
  ) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if Defaults[.textExpansionEnabled], let tap = eventTap {
        CGEvent.tapEnable(tap: tap, enable: true)
        isEventTapActive = CGEvent.tapIsEnabled(tap: tap)
      }
      return false
    }

    if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
      typingBuffer = ""
      return false
    }

    guard type == .keyDown else {
      return false
    }

    if cgEvent.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag {
      return false
    }

    guard Defaults[.textExpansionEnabled], !Defaults[.ignoreEvents], !isExpanding else {
      return false
    }

    let myPID = ProcessInfo.processInfo.processIdentifier
    let rawTargetPID = pid_t(cgEvent.getIntegerValueField(.eventTargetUnixProcessID))
    let targetApp: NSRunningApplication?
    let isTargetingMaccy: Bool

    if rawTargetPID > 0 {
      isTargetingMaccy = (rawTargetPID == myPID)
      targetApp = isTargetingMaccy
        ? NSRunningApplication.current
        : NSRunningApplication(processIdentifier: rawTargetPID)
    } else {
      let front = NSWorkspace.shared.frontmostApplication
      isTargetingMaccy = (front?.processIdentifier == myPID) && (NSApp.keyWindow != nil)
      targetApp = front
    }

    // Never expand inside Maccy's own windows EXCEPT the dedicated live test box in Snippet Studio
    if isTargetingMaccy && !isStudioTestFieldFocused {
      typingBuffer = ""
      return false
    }

    if !isTargetingMaccy, Clipboard.shared.isAppIgnored(targetApp?.bundleIdentifier) {
      typingBuffer = ""
      return false
    }

    // Security guard: skip real password fields (`AXSecureTextField`) without false-positively
    // breaking when background apps leave global `IsSecureEventInputEnabled()` stuck on.
    if Self.isFocusedElementPasswordField() {
      typingBuffer = ""
      return false
    }

    let flags = cgEvent.flags
    if flags.contains(.maskCommand) || flags.contains(.maskControl) {
      typingBuffer = ""
      return false
    }

    let keyCode = UInt16(cgEvent.getIntegerValueField(.keyboardEventKeycode))
    if keyCode == 51 { // Backspace
      if !typingBuffer.isEmpty {
        typingBuffer.removeLast()
      }
      return false
    }

    if Self.navigationAndResetKeyCodes.contains(keyCode) {
      typingBuffer = ""
      return false
    }

    let typedChunk: String
    switch keyCode {
    case 36, 76: // Return / Keypad Enter
      typedChunk = "\n"
    case 48: // Tab
      typedChunk = "\t"
    default:
      var length: Int = 0
      var utf16 = [UniChar](repeating: 0, count: 16)
      cgEvent.keyboardGetUnicodeString(
        maxStringLength: utf16.count,
        actualStringLength: &length,
        unicodeString: &utf16
      )
      guard length > 0 else {
        return false
      }
      let decoded = String(utf16CodeUnits: utf16, count: length)
      guard !decoded.isEmpty else {
        return false
      }
      if let scalar = decoded.unicodeScalars.first, scalar.value < 0x20 {
        return false
      }
      typedChunk = decoded
    }

    typingBuffer.append(typedChunk)
    let maxLen = SnippetStore.shared.maxAbbreviationLength + 8
    if typingBuffer.count > maxLen {
      typingBuffer = String(typingBuffer.suffix(maxLen))
    }

    let candidates = SnippetStore.shared.activeExpansionCandidates
    guard !candidates.isEmpty else {
      return false
    }

    // 1. Check `.afterDelimiter` rules if the user just typed a delimiter character
    if let lastChar = typingBuffer.last, Self.delimiterCharacters.contains(lastChar) {
      let bufferBeforeDelimiter = String(typingBuffer.dropLast())
      if !bufferBeforeDelimiter.isEmpty,
         let (matchedCandidate, typedSlice) = findMatchingCandidate(
           in: bufferBeforeDelimiter,
           candidates: candidates,
           mode: .afterDelimiter
         ) {
        let delimiterString = (lastChar == "\r") ? "\n" : String(lastChar)
        let alreadyInsertedCount = max(0, typedSlice.count - max(0, typedChunk.count - 1))
        let extraAutocompleteDelete = (alreadyInsertedCount > 0 && Self.hasNonEmptySelectedTextInFocusedElement()) ? 1 : 0
        scheduleSwallowedExpansion(
          candidate: matchedCandidate,
          typedAbbreviation: typedSlice,
          backspacesToDelete: alreadyInsertedCount + extraAutocompleteDelete,
          trailingDelimiter: delimiterString,
          targetApp: targetApp,
          useDirectResponderForMaccy: isTargetingMaccy
        )
        // Swallow the delimiter keystroke; `trailingDelimiter` will be pasted atomically with the expansion
        return true
      }
    }

    // 2. Check `.immediate` rules ("Expand on match" ⚡)
    if let (matchedCandidate, typedSlice) = findMatchingCandidate(
      in: typingBuffer,
      candidates: candidates,
      mode: .immediate
    ) {
      let alreadyInsertedCount = max(0, typedSlice.count - typedChunk.count)
      let extraAutocompleteDelete = (alreadyInsertedCount > 0 && Self.hasNonEmptySelectedTextInFocusedElement()) ? 1 : 0
      scheduleSwallowedExpansion(
        candidate: matchedCandidate,
        typedAbbreviation: typedSlice,
        backspacesToDelete: alreadyInsertedCount + extraAutocompleteDelete,
        trailingDelimiter: nil,
        targetApp: targetApp,
        useDirectResponderForMaccy: isTargetingMaccy
      )
      // Swallow the final triggering keystroke so it never flickers or triggers browser omnibox submit
      return true
    }

    return false
  }

  private func findMatchingCandidate(
    in buffer: String,
    candidates: [ActiveExpansionCandidate],
    mode: SnippetTriggerMode
  ) -> (ActiveExpansionCandidate, String)? {
    guard !buffer.isEmpty else { return nil }
    let lowerBuffer = buffer.lowercased()

    for candidate in candidates where candidate.item.triggerMode == mode {
      let abbr = candidate.effectiveAbbreviation
      let abbrCount = abbr.count
      guard buffer.count >= abbrCount else { continue }

      let matchesSuffix: Bool
      switch candidate.item.caseMode {
      case .caseSensitive:
        matchesSuffix = buffer.hasSuffix(abbr)
      case .ignoreCase, .propagateCase:
        matchesSuffix = lowerBuffer.hasSuffix(candidate.lowercasedAbbreviation)
      }
      guard matchesSuffix else { continue }

      let matchStartIdx = buffer.index(buffer.endIndex, offsetBy: -abbrCount)
      if candidate.item.wholeWord && matchStartIdx > buffer.startIndex {
        let prevChar = buffer[buffer.index(before: matchStartIdx)]
        if prevChar.isLetter || prevChar.isNumber || prevChar == "_" {
          continue
        }
      }

      let typedSlice = String(buffer[matchStartIdx..<buffer.endIndex])
      return (candidate, typedSlice)
    }

    return nil
  }

  private func scheduleSwallowedExpansion(
    candidate: ActiveExpansionCandidate,
    typedAbbreviation: String,
    backspacesToDelete: Int,
    trailingDelimiter: String?,
    targetApp: NSRunningApplication?,
    useDirectResponderForMaccy: Bool
  ) {
    typingBuffer = ""
    isExpanding = true

    let item = candidate.item
    lastExpandedSummary = "\(typedAbbreviation) → \(item.displayTitle)"
    lastExpandedAt = Date.now

    Task { @MainActor in
      // Allow CGEventTapCallBack to return `nil` cleanly to WindowServer first
      try? await Task.sleep(for: .milliseconds(8))

      let currentClipboardString = NSPasteboard.general.string(forType: .string) ?? ""

      if backspacesToDelete > 0 {
        Clipboard.shared.deleteCharactersBeforeCursor(
          count: backspacesToDelete,
          syntheticTag: Self.syntheticEventTag,
          useDirectResponderForMaccy: useDirectResponderForMaccy
        )
      }

      let fillFields = SnippetTemplateEngine.extractFillInFields(from: item)
      if !fillFields.isEmpty {
        isExpanding = false
        SnippetFillInWindowController.shared.present(
          item: item,
          fields: fillFields,
          targetApp: useDirectResponderForMaccy ? NSRunningApplication.current : targetApp,
          typedAbbreviation: typedAbbreviation,
          trailingDelimiter: trailingDelimiter,
          clipboardString: currentClipboardString
        )
        return
      }

      defer { isExpanding = false }
      if backspacesToDelete > 0 {
        try? await Task.sleep(for: .milliseconds(40))
      }

      let steps = await SnippetTemplateEngine.renderActionSteps(
        for: item,
        typedAbbreviation: typedAbbreviation,
        trailingDelimiter: trailingDelimiter,
        clipboardString: currentClipboardString
      )
      if Defaults[.expandPlaySound] {
        NSSound.write?.play()
      }
      SnippetStore.shared.recordUsage(for: item.id)
      await Clipboard.shared.performExpansionSteps(
        steps,
        targetApp: nil,
        restoreClipboard: Defaults[.restoreClipboardAfterExpansion],
        syntheticTag: Self.syntheticEventTag,
        useDirectResponderForMaccy: useDirectResponderForMaccy
      )
    }
  }

  // MARK: - Accessibility Element Inspection Helpers

  private static func focusedAXElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
    guard err == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
      return nil
    }
    return unsafeDowncast(focusedRef, to: AXUIElement.self)
  }

  private static func isFocusedElementPasswordField() -> Bool {
    guard let elem = focusedAXElement() else { return false }
    var roleRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef) == .success,
       let role = roleRef as? String,
       role == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField" {
      return true
    }
    var subroleRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(elem, kAXSubroleAttribute as CFString, &subroleRef) == .success,
       let subrole = subroleRef as? String,
       subrole == (kAXSecureTextFieldSubrole as String) || subrole == "AXSecureTextField" {
      return true
    }
    return false
  }

  private static func hasNonEmptySelectedTextInFocusedElement() -> Bool {
    guard let elem = focusedAXElement() else { return false }
    var selectedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(elem, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
          let selectedStr = selectedRef as? String else {
      return false
    }
    return !selectedStr.isEmpty
  }
}
