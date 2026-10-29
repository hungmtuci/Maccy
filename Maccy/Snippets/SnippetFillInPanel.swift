import AppKit
import Defaults
import SwiftUI

@MainActor
final class SnippetFillInWindowController {
  static let shared = SnippetFillInWindowController()

  private var panel: NSPanel?

  func present(
    item: SnippetItem,
    fields: [SnippetFillInField],
    targetApp: NSRunningApplication?,
    typedAbbreviation: String? = nil,
    trailingDelimiter: String? = nil,
    clipboardString: String
  ) {
    close()

    let panelWidth: CGFloat = 500
    let panelHeight: CGFloat = min(max(340, CGFloat(190 + fields.count * 64)), 620)
    let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

    let newPanel = NSPanel(
      contentRect: rect,
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    newPanel.title = "Điền thông tin Gõ tắt — \(item.displayTitle)"
    newPanel.level = .floating
    newPanel.isFloatingPanel = true
    newPanel.hidesOnDeactivate = false
    newPanel.isReleasedWhenClosed = false
    newPanel.center()

    let view = SnippetFillInFormView(
      item: item,
      fields: fields,
      clipboardString: clipboardString,
      onCancel: { [weak self] in
        self?.close()
        targetApp?.activate()
      },
      onConfirm: { [weak self] values, toggles in
        self?.close()
        Task { @MainActor in
          await TextExpansionEngine.shared.completeFillInExpansion(
            item: item,
            targetApp: targetApp,
            typedAbbreviation: typedAbbreviation,
            trailingDelimiter: trailingDelimiter,
            fillInValues: values,
            optionalToggles: toggles,
            clipboardString: clipboardString
          )
        }
      }
    )

    newPanel.contentView = NSHostingView(rootView: view)
    self.panel = newPanel

    NSApp.activate(ignoringOtherApps: true)
    newPanel.makeKeyAndOrderFront(nil)
  }

  func close() {
    panel?.orderOut(nil)
    panel?.close()
    panel = nil
  }
}

private struct SnippetFillInFormView: View {
  let item: SnippetItem
  let fields: [SnippetFillInField]
  let clipboardString: String
  let onCancel: () -> Void
  let onConfirm: ([String: String], [String: Bool]) -> Void

  @State private var textValues: [String: String] = [:]
  @State private var optionalToggles: [String: Bool] = [:]
  @FocusState private var focusedFieldKey: String?

  init(
    item: SnippetItem,
    fields: [SnippetFillInField],
    clipboardString: String,
    onCancel: @escaping () -> Void,
    onConfirm: @escaping ([String: String], [String: Bool]) -> Void
  ) {
    self.item = item
    self.fields = fields
    self.clipboardString = clipboardString
    self.onCancel = onCancel
    self.onConfirm = onConfirm

    var initialTexts: [String: String] = [:]
    var initialToggles: [String: Bool] = [:]
    for field in fields {
      switch field.kind {
      case .singleLine(let defVal), .multiLine(let defVal):
        initialTexts[field.key] = defVal
      case .dropdown(let options, let defaultIndex):
        let safeIdx = options.indices.contains(defaultIndex) ? defaultIndex : 0
        initialTexts[field.key] = options.isEmpty ? "" : options[safeIdx]
      case .optionalSection(let defaultIncluded, _):
        initialToggles[field.key] = defaultIncluded
      }
    }
    _textValues = State(initialValue: initialTexts)
    _optionalToggles = State(initialValue: initialToggles)
  }

  private var livePreviewText: String {
    SnippetTemplateEngine.renderLivePreview(
      for: item,
      fillInValues: textValues,
      optionalToggles: optionalToggles,
      clipboardString: clipboardString
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "rectangle.and.pencil.and.ellipsis")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(Color.accentColor)
        Text(item.displayTitle)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        if !item.abbreviation.isEmpty {
          Text(item.abbreviation)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15)))
        }
      }

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(fields) { field in
            fieldRow(for: field)
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Xem trước nội dung sẽ chèn:")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(livePreviewText)
              .font(.system(size: 12))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(8)
              .background(
                RoundedRectangle(cornerRadius: 6)
                  .fill(Color(nsColor: .textBackgroundColor).opacity(0.85))
              )
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
              )
          }
          .padding(.top, 4)
        }
        .padding(.vertical, 2)
      }

      Divider()

      HStack {
        Text("Nhấn ⌘↩ để chèn nhanh • Esc để huỷ")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Huỷ (Esc)") {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)

        Button("Chèn vào ứng dụng") {
          onConfirm(textValues, optionalToggles)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: [.command])
      }
    }
    .padding(16)
    .onAppear {
      if let firstInput = fields.first(where: {
        if case .singleLine = $0.kind { return true }
        if case .multiLine = $0.kind { return true }
        return false
      }) {
        focusedFieldKey = firstInput.key
      }
    }
  }

  @ViewBuilder
  private func fieldRow(for field: SnippetFillInField) -> some View {
    switch field.kind {
    case .singleLine:
      VStack(alignment: .leading, spacing: 4) {
        Text(field.label)
          .font(.subheadline.weight(.medium))
        TextField(
          field.label,
          text: Binding(
            get: { textValues[field.key] ?? "" },
            set: { textValues[field.key] = $0 }
          )
        )
        .textFieldStyle(.roundedBorder)
        .focused($focusedFieldKey, equals: field.key)
        .onSubmit {
          onConfirm(textValues, optionalToggles)
        }
      }

    case .multiLine:
      VStack(alignment: .leading, spacing: 4) {
        Text(field.label)
          .font(.subheadline.weight(.medium))
        TextEditor(
          text: Binding(
            get: { textValues[field.key] ?? "" },
            set: { textValues[field.key] = $0 }
          )
        )
        .font(.system(size: 13))
        .frame(minHeight: 64, maxHeight: 110)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .focused($focusedFieldKey, equals: field.key)
      }

    case .dropdown(let options, _):
      HStack {
        Text(field.label)
          .font(.subheadline.weight(.medium))
        Spacer()
        Picker(
          "",
          selection: Binding(
            get: { textValues[field.key] ?? (options.first ?? "") },
            set: { textValues[field.key] = $0 }
          )
        ) {
          ForEach(options, id: \.self) { opt in
            Text(opt).tag(opt)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
      }

    case .optionalSection:
      Toggle(
        isOn: Binding(
          get: { optionalToggles[field.key] ?? false },
          set: { optionalToggles[field.key] = $0 }
        )
      ) {
        Text("Bao gồm phần: \(field.label)")
          .font(.subheadline.weight(.medium))
      }
    }
  }
}
