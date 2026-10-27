import AppKit
import Observation
import SwiftUI

struct LargeTextView: NSViewRepresentable {
  @Environment(\.isEnabled) private var isEnabled

  private let previewText: String?
  private let highlightQuery: String
  private let editorState: EditorState?
  private let isEditableOverwrite: Bool
  private var accessibilityLabel: String?
  private var onCancel: (() -> Void)?

  private var isEditable: Bool { isEditableOverwrite && editorState != nil }

  init(text: String, highlightQuery: String = "", accessibilityLabel: String? = nil) {
    self.isEditableOverwrite = false
    self.previewText = text
    self.highlightQuery = highlightQuery
    self.editorState = nil
    self.accessibilityLabel = accessibilityLabel
  }

  init(
    editorState: EditorState,
    isEditable: Bool = true,
    accessibilityLabel: String? = nil,
    onCancel: (() -> Void)? = nil
  ) {
    self.isEditableOverwrite = isEditable
    self.previewText = nil
    self.highlightQuery = ""
    self.editorState = editorState
    self.accessibilityLabel = accessibilityLabel
    self.onCancel = onCancel
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let resolvedColor: NSColor = isEnabled ? .labelColor : .disabledControlTextColor
    let scrollView = Self.makeScrollView(
      text: editorState?.text ?? previewText ?? "",
      isEditable: isEditable,
      accessibilityLabel: accessibilityLabel,
      textColor: resolvedColor
    )
    if let textView = scrollView.documentView as? NSTextView {
      textView.delegate = context.coordinator
      editorState?.textView = textView
      if !isEditable, !highlightQuery.isEmpty {
        Self.applySearchHighlight(query: highlightQuery, to: textView, baseTextColor: resolvedColor)
      }
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let previousEditorState = context.coordinator.parent.editorState
    context.coordinator.parent = self
    guard let textView = scrollView.documentView as? NSTextView else { return }

    let resolvedColor: NSColor = isEnabled ? .labelColor : .disabledControlTextColor
    textView.isEditable = isEditable
    textView.isSelectable = isEditable
    textView.allowsUndo = isEditable
    textView.textColor = resolvedColor
    textView.setAccessibilityLabel(accessibilityLabel)

    if previousEditorState !== editorState {
      previousEditorState?.detach()
      textView.string = editorState?.text ?? previewText ?? ""
      editorState?.textView = textView
    }

    // The native text view owns editable content until it is saved. SwiftUI
    // updates must not copy the text or replace its storage after each edit.
    guard !isEditable else { return }
    let textChanged = context.coordinator.lastPreviewText != previewText
    let queryChanged = context.coordinator.lastHighlightQuery != highlightQuery
    guard textChanged || queryChanged else { return }

    if textChanged {
      context.coordinator.lastPreviewText = previewText
      textView.string = previewText ?? ""
    }
    context.coordinator.lastHighlightQuery = highlightQuery
    Self.applySearchHighlight(query: highlightQuery, to: textView, baseTextColor: resolvedColor)
  }

  private static func applySearchHighlight(
    query: String,
    to textView: NSTextView,
    baseTextColor: NSColor
  ) {
    guard let storage = textView.textStorage else { return }
    let text = textView.string
    let fullLength = (text as NSString).length
    guard fullLength > 0 else { return }

    let fullRange = NSRange(location: 0, length: fullLength)
    let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    storage.beginEditing()
    storage.setAttributes(
      [.font: font, .foregroundColor: baseTextColor],
      range: fullRange
    )

    var firstMatchNSRange: NSRange?
    if !trimmedQuery.isEmpty {
      let matches = text.allRangesByVietnameseSearch(of: trimmedQuery, maxMatches: 60)
      for matchRange in matches {
        let nsRange = NSRange(matchRange, in: text)
        guard nsRange.length > 0, NSMaxRange(nsRange) <= fullLength else { continue }
        if firstMatchNSRange == nil {
          firstMatchNSRange = nsRange
        }
        storage.addAttributes(
          [
            .backgroundColor: NSColor.findHighlightColor,
            .foregroundColor: NSColor.black
          ],
          range: nsRange
        )
      }
    }
    storage.endEditing()

    if let firstMatchNSRange {
      DispatchQueue.main.async {
        textView.scrollRangeToVisible(firstMatchNSRange)
      }
    }
  }

  static func dismantleNSView(
    _ scrollView: NSScrollView,
    coordinator: Coordinator
  ) {
    coordinator.parent.editorState?.detach()
    (scrollView.documentView as? NSTextView)?.delegate = nil
  }

  static func makeScrollView(
    text: String,
    isEditable: Bool = false,
    accessibilityLabel: String? = nil,
    textColor: NSColor = .labelColor
  ) -> NSScrollView {
    let textView = NSTextView(usingTextLayoutManager: true)
    textView.isEditable = isEditable
    textView.isSelectable = isEditable
    textView.allowsUndo = isEditable
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.isRichText = false
    textView.drawsBackground = false
    textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    textView.textColor = textColor
    textView.textContainerInset = .zero
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.string = text

    let scrollView = NSScrollView()
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    return scrollView
  }

  @Observable
  final class EditorState: NSObject {
    private(set) var hasChanges = false

    @ObservationIgnored private var storedText: String
    @ObservationIgnored fileprivate weak var textView: NSTextView?
    fileprivate let undoManager = UndoManager()

    var text: String { textView?.string ?? storedText }

    init(text: String) {
      self.storedText = text
      super.init()

      for name in [
        Notification.Name.NSUndoManagerDidUndoChange,
        .NSUndoManagerDidRedoChange,
      ] {
        NotificationCenter.default.addObserver(
          self,
          selector: #selector(undoHistoryDidChange(_:)),
          name: name,
          object: undoManager
        )
      }
    }

    isolated deinit {
      NotificationCenter.default.removeObserver(self)
    }

    fileprivate func markChanged() {
      hasChanges = true
    }

    fileprivate func detach() {
      storedText = text
      textView = nil
    }

    @objc private func undoHistoryDidChange(_ notification: Notification) {
      hasChanges = undoManager.canUndo
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: LargeTextView
    var lastPreviewText: String?
    var lastHighlightQuery: String

    init(_ parent: LargeTextView) {
      self.parent = parent
      self.lastPreviewText = parent.previewText
      self.lastHighlightQuery = parent.highlightQuery
    }

    func textDidChange(_ notification: Notification) {
      parent.editorState?.markChanged()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
      parent.editorState?.undoManager
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector)
      -> Bool
    {
      guard parent.isEditable, !textView.hasMarkedText() else { return false }

      if commandSelector == #selector(NSResponder.cancelOperation(_:)),
        let onCancel = parent.onCancel
      {
        onCancel()
        return true
      }

      return false
    }
  }
}
