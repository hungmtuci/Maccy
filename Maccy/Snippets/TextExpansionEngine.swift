import AppKit
import Carbon.HIToolbox
import Defaults
import Foundation

@MainActor
final class TextExpansionEngine {
  static let shared = TextExpansionEngine()

  /// Custom `CGEventField.eventSourceUserData` tag (`"MCYS"`) so synthetic Backspaces,
  /// keystrokes, and `⌘V` pastes emitted by Maccy never re-trigger `TextExpansionEngine`.
  nonisolated static let syntheticEventTag: Int64 = 0x4D43_5953

  private var keyDownMonitor: Any?
  private var mouseMonitor: Any?
  private var appSwitchObserver: NSObjectProtocol?

  private var typingBuffer: String = ""
  private var isExpanding: Bool = false

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
    guard keyDownMonitor == nil else { return }

    keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated {
        self?.handleGlobalKeyDown(event)
      }
    }

    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.typingBuffer = ""
      }
    }

    appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.typingBuffer = ""
      }
    }
  }

  func stop() {
    if let keyDownMonitor {
      NSEvent.removeMonitor(keyDownMonitor)
      self.keyDownMonitor = nil
    }
    if let mouseMonitor {
      NSEvent.removeMonitor(mouseMonitor)
      self.mouseMonitor = nil
    }
    if let appSwitchObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
      self.appSwitchObserver = nil
    }
    typingBuffer = ""
  }

  func resetBuffer() {
    typingBuffer = ""
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
    await Clipboard.shared.performExpansionSteps(
      steps,
      targetApp: targetApp,
      restoreClipboard: Defaults[.restoreClipboardAfterExpansion],
      syntheticTag: Self.syntheticEventTag
    )
  }

  // MARK: - Global Keystroke Listener & Matcher

  private func handleGlobalKeyDown(_ event: NSEvent) {
    guard Defaults[.textExpansionEnabled], !Defaults[.ignoreEvents], !isExpanding else {
      return
    }

    if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag {
      return
    }

    // Security guard: never monitor or expand inside password/secure fields (1Password, sudo, Keychain, Login)
    if IsSecureEventInputEnabled() {
      typingBuffer = ""
      return
    }

    let frontApp = NSWorkspace.shared.frontmostApplication
    let frontBundleId = frontApp?.bundleIdentifier
    if frontBundleId == Bundle.main.bundleIdentifier || Clipboard.shared.isAppIgnored(frontBundleId) {
      typingBuffer = ""
      return
    }

    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if mods.contains(.command) || mods.contains(.control) {
      typingBuffer = ""
      return
    }

    let keyCode = event.keyCode
    if keyCode == 51 { // Backspace
      if !typingBuffer.isEmpty {
        typingBuffer.removeLast()
      }
      return
    }

    if Self.navigationAndResetKeyCodes.contains(keyCode) {
      typingBuffer = ""
      return
    }

    let typedChunk: String
    switch keyCode {
    case 36, 76: // Return / Keypad Enter
      typedChunk = "\n"
    case 48: // Tab
      typedChunk = "\t"
    default:
      guard let chars = event.characters, !chars.isEmpty else { return }
      // Ignore non-printable control characters
      if let scalar = chars.unicodeScalars.first, scalar.value < 0x20 {
        return
      }
      typedChunk = chars
    }

    typingBuffer.append(typedChunk)
    let maxLen = SnippetStore.shared.maxAbbreviationLength + 8
    if typingBuffer.count > maxLen {
      typingBuffer = String(typingBuffer.suffix(maxLen))
    }

    let candidates = SnippetStore.shared.activeExpansionCandidates
    guard !candidates.isEmpty else { return }

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
        executeMatchedExpansion(
          candidate: matchedCandidate,
          typedAbbreviation: typedSlice,
          charsToDelete: typedSlice.count + 1,
          trailingDelimiter: delimiterString,
          targetApp: frontApp
        )
        return
      }
    }

    // 2. Check `.immediate` rules ("Expand on match" ⚡)
    if let (matchedCandidate, typedSlice) = findMatchingCandidate(
      in: typingBuffer,
      candidates: candidates,
      mode: .immediate
    ) {
      executeMatchedExpansion(
        candidate: matchedCandidate,
        typedAbbreviation: typedSlice,
        charsToDelete: typedSlice.count,
        trailingDelimiter: nil,
        targetApp: frontApp
      )
    }
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

  private func executeMatchedExpansion(
    candidate: ActiveExpansionCandidate,
    typedAbbreviation: String,
    charsToDelete: Int,
    trailingDelimiter: String?,
    targetApp: NSRunningApplication?
  ) {
    typingBuffer = ""
    isExpanding = true

    let item = candidate.item
    let currentClipboardString = NSPasteboard.general.string(forType: .string) ?? ""

    // Remove the typed abbreviation (and delimiter if applicable) before pasting expansion
    Clipboard.shared.deleteCharactersBeforeCursor(
      count: charsToDelete,
      syntheticTag: Self.syntheticEventTag
    )

    let fillFields = SnippetTemplateEngine.extractFillInFields(from: item)
    if !fillFields.isEmpty {
      isExpanding = false
      SnippetFillInWindowController.shared.present(
        item: item,
        fields: fillFields,
        targetApp: targetApp,
        typedAbbreviation: typedAbbreviation,
        trailingDelimiter: trailingDelimiter,
        clipboardString: currentClipboardString
      )
      return
    }

    Task { @MainActor in
      defer { isExpanding = false }
      try? await Task.sleep(for: .milliseconds(35))

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
        syntheticTag: Self.syntheticEventTag
      )
    }
  }
}
