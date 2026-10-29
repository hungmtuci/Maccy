import AppKit
import Defaults
import KeyboardShortcuts
import Settings
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SnippetManagerWindowController {
  static let shared = SnippetManagerWindowController()

  private var window: NSWindow?
  fileprivate var requestedSelectedItemId: UUID?
  fileprivate var triggerTypinatorImportOnOpen: Bool = false

  func show(selecting itemId: UUID? = nil) {
    requestedSelectedItemId = itemId

    if let existingWindow = window {
      NSApp.activate(ignoringOtherApps: true)
      existingWindow.makeKeyAndOrderFront(nil)
      NotificationCenter.default.post(name: .snippetStudioSelectRequested, object: itemId)
      return
    }

    let rootView = SnippetStudioView()
    let hosting = NSHostingController(rootView: rootView)
    let win = NSWindow(contentViewController: hosting)
    win.title = "Trình quản lý Gõ tắt & Biểu mẫu động (Maccy Snippet Studio)"
    win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    win.setContentSize(NSSize(width: 980, height: 660))
    win.minSize = NSSize(width: 780, height: 520)
    win.isReleasedWhenClosed = false
    win.center()

    self.window = win
    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
  }

  func showAndImportTypinator() {
    triggerTypinatorImportOnOpen = true
    show()
    NotificationCenter.default.post(name: .snippetStudioImportTypinatorRequested, object: nil)
  }

  func showAndCreateFromClipboardItem(_ historyItem: HistoryItem) {
    let suggestedName = historyItem.title
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .shortened(to: 60)

    let created = SnippetStore.shared.createSnippet(
      from: historyItem,
      name: suggestedName,
      abbreviation: ""
    )
    show(selecting: created.id)
  }
}

private extension Notification.Name {
  static let snippetStudioSelectRequested = Notification.Name("MaccySnippetStudioSelectRequested")
  static let snippetStudioImportTypinatorRequested = Notification.Name("MaccySnippetStudioImportTypinatorRequested")
}

// MARK: - 3-Pane Snippet Studio Window View

struct SnippetStudioView: View {
  @State private var store = SnippetStore.shared
  @State private var engine = TextExpansionEngine.shared
  @Default(.textExpansionEnabled) private var textExpansionEnabled
  @Default(.ignoreEvents) private var ignoreEvents

  @State private var selectedCollectionId: UUID?
  @State private var selectedItemId: UUID?
  @State private var studioSearchQuery: String = ""
  @State private var liveTestInput: String = ""

  @State private var editingCollection: SnippetCollection?
  @State private var isCreatingCollection: Bool = false
  @State private var newCollectionName: String = ""
  @State private var newCollectionPrefix: String = ""

  @State private var statusBanner: String?
  @State private var isImportingBusy: Bool = false
  @State private var showLivePreviewBox: Bool = false

  @FocusState private var abbreviationFieldFocused: Bool
  @FocusState private var liveTestFieldFocused: Bool

  private var visibleItems: [SnippetItem] {
    store.items(in: selectedCollectionId, searchQuery: studioSearchQuery)
  }

  private var currentSelectedItem: SnippetItem? {
    guard let id = selectedItemId else { return nil }
    return store.item(for: id)
  }

  var body: some View {
    VStack(spacing: 0) {
      studioTopBar

      permissionAndDiagnosticsBar

      liveTestSandboxBar

      if let banner = statusBanner {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text(banner)
            .font(.system(size: 12, weight: .medium))
          Spacer()
          Button {
            statusBanner = nil
          } label: {
            Image(systemName: "xmark")
              .font(.caption)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
      }

      Divider()

      HSplitView {
        collectionsSidebar
          .frame(minWidth: 215, idealWidth: 240, maxWidth: 310)

        VSplitView {
          snippetsTablePane
            .frame(minHeight: 165, idealHeight: 235)

          snippetEditorPane
            .frame(minHeight: 250)
        }
      }
    }
    .onAppear {
      engine.refreshStatusAndEnsureEventTap()
      if let req = SnippetManagerWindowController.shared.requestedSelectedItemId,
         let found = store.item(for: req) {
        selectedCollectionId = found.collectionId
        selectedItemId = found.id
        SnippetManagerWindowController.shared.requestedSelectedItemId = nil
        if found.abbreviation.isEmpty {
          abbreviationFieldFocused = true
        }
      } else {
        selectedItemId = visibleItems.first?.id
      }

      if SnippetManagerWindowController.shared.triggerTypinatorImportOnOpen {
        SnippetManagerWindowController.shared.triggerTypinatorImportOnOpen = false
        runTypinatorImport()
      }
    }
    .onDisappear {
      engine.isStudioTestFieldFocused = false
    }
    .onChange(of: liveTestFieldFocused) { _, focused in
      engine.isStudioTestFieldFocused = focused
    }
    .onReceive(NotificationCenter.default.publisher(for: .snippetStudioSelectRequested)) { note in
      if let id = note.object as? UUID, let found = store.item(for: id) {
        selectedCollectionId = found.collectionId
        selectedItemId = found.id
        if found.abbreviation.isEmpty {
          abbreviationFieldFocused = true
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .snippetStudioImportTypinatorRequested)) { _ in
      SnippetManagerWindowController.shared.triggerTypinatorImportOnOpen = false
      runTypinatorImport()
    }
    .sheet(item: $editingCollection) { col in
      CollectionEditSheet(collection: col) { updated in
        store.updateCollection(updated)
      }
    }
    .sheet(isPresented: $isCreatingCollection) {
      NewCollectionSheet { name, prefix, suffix in
        let created = store.createCollection(name: name, keywordPrefix: prefix, keywordSuffix: suffix)
        selectedCollectionId = created.id
      }
    }
  }

  // MARK: - Top Toolbar

  private var studioTopBar: some View {
    let isReady = textExpansionEnabled && !ignoreEvents && engine.isEventTapActive
    return HStack(spacing: 10) {
      Toggle(isOn: $textExpansionEnabled) {
        HStack(spacing: 5) {
          Image(systemName: isReady ? "bolt.circle.fill" : (textExpansionEnabled ? "exclamationmark.triangle.fill" : "pause.circle"))
            .foregroundStyle(isReady ? .green : (textExpansionEnabled ? .orange : .secondary))
          Text(textExpansionEnabled ? "Gõ tắt tự động: Đang bật" : "Gõ tắt tự động: Tạm dừng")
            .font(.system(size: 12.5, weight: .semibold))
        }
      }
      .toggleStyle(.switch)
      .controlSize(.small)

      if textExpansionEnabled {
        if isReady {
          HStack(spacing: 4) {
            Circle()
              .fill(Color.green)
              .frame(width: 7, height: 7)
            Text("Đang bắt phím")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.green)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Capsule().fill(Color.green.opacity(0.13)))
        } else {
          Button {
            if ignoreEvents {
              ignoreEvents = false
            } else {
              engine.requestOrRepairAccessibilityPermission(resetStaleTCC: true)
            }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 10.5))
              Text(ignoreEvents ? "Đang tắt sự kiện (Bấm bật lại)" : "Thiếu quyền Bàn phím (Bấm cấp quyền)")
                .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(Color.orange))
          }
          .buttonStyle(.plain)
        }
      }

      Spacer()

      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Tìm tên, từ gõ tắt, nội dung (hỗ trợ Tiếng Việt không dấu)…", text: $studioSearchQuery)
          .textFieldStyle(.plain)
          .frame(minWidth: 240, maxWidth: 320)
        if !studioSearchQuery.isEmpty {
          Button {
            studioSearchQuery = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))

      Menu {
        Button {
          runTypinatorImport()
        } label: {
          Label("Nhập trực tiếp từ Typinator…", systemImage: "bolt.horizontal.circle")
        }

        Button {
          runAlfredImport()
        } label: {
          Label("Nhập trực tiếp từ Alfred Snippets…", systemImage: "sparkles.rectangle.stack")
        }

        Button {
          runFileImportDialog()
        } label: {
          Label("Nhập từ tệp (.alfredsnippets, .json, .csv, .tsv)…", systemImage: "square.and.arrow.down")
        }

        Divider()

        Menu("Cài đặt Gói mẫu có sẵn") {
          ForEach(SnippetStarterPackID.allCases) { pack in
            Button(pack.title) {
              let summary = store.importPayload(SnippetImporter.starterPackPayload(for: pack))
              statusBanner = "Đã cài gói \"\(summary.sourceDescription)\" (+\(summary.snippetsImported) mục mới)."
            }
          }
        }

        Divider()

        Button {
          runExportJSONDialog()
        } label: {
          Label("Xuất toàn bộ ra tệp JSON…", systemImage: "square.and.arrow.up")
        }

        Button {
          runExportCSVDialog()
        } label: {
          Label("Xuất toàn bộ ra tệp CSV (Excel)…", systemImage: "tablecells")
        }
      } label: {
        Label(isImportingBusy ? "Đang nhập…" : "Nhập / Xuất", systemImage: "arrow.up.arrow.down.circle")
      }
      .disabled(isImportingBusy)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var permissionAndDiagnosticsBar: some View {
    if textExpansionEnabled && ignoreEvents {
      HStack(spacing: 10) {
        Image(systemName: "pause.circle.fill")
          .foregroundStyle(.orange)
        Text("Maccy đang bật chế độ Tạm dừng bắt sự kiện toàn cục (Ignore Events), nên Gõ tắt tự động tạm nghỉ.")
          .font(.system(size: 12, weight: .medium))
        Spacer()
        Button("Bật lại ngay") {
          ignoreEvents = false
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(Color.orange.opacity(0.14))
    } else if textExpansionEnabled && !engine.isEventTapActive {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 16))
          .foregroundStyle(.orange)

        VStack(alignment: .leading, spacing: 2) {
          Text("Chưa kích hoạt được quyền Bàn phím (Accessibility) — Gõ tắt tự động đang bị macOS chặn!")
            .font(.system(size: 12.5, weight: .bold))
          Text("Mỗi khi chép đè bản Maccy mới vào /Applications, quyền cũ trong System Settings bị hết hạn chữ ký (dù nút công tắc vẫn hiện bật). Bấm nút bên phải để làm mới 1-chạm rồi bật lại công tắc Maccy.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 8)

        Button {
          engine.requestOrRepairAccessibilityPermission(resetStaleTCC: true)
        } label: {
          Label("Làm mới & Cấp quyền Bàn phím", systemImage: "bolt.shield.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .controlSize(.small)

        Button("Mở Cài đặt") {
          engine.openAccessibilitySettingsPane()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(Color.orange.opacity(0.15))
    } else if textExpansionEnabled && engine.isSecureInputLocked {
      HStack(spacing: 8) {
        Image(systemName: "lock.fill")
          .foregroundStyle(.yellow)
        Text("Một ứng dụng đang bật Secure Keyboard Input (ô mật khẩu / Terminal / 1Password), có thể tạm chặn gõ tắt trong cửa sổ bảo mật đó.")
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 5)
      .background(Color.yellow.opacity(0.10))
    }
  }

  private var liveTestSandboxBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "keyboard")
        .foregroundStyle(Color.accentColor)
      Text("Ô gõ thử trực tiếp:")
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.secondary)

      TextField("Bấm vào đây rồi gõ thử từ gõ tắt (VD: 009) để kiểm tra ngay…", text: $liveTestInput)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12.5))
        .focused($liveTestFieldFocused)
        .frame(maxWidth: 420)

      if !liveTestInput.isEmpty {
        Button("Xoá ô thử") {
          liveTestInput = ""
          engine.resetBuffer()
        }
        .controlSize(.mini)
        .buttonStyle(.borderless)
      }

      Spacer()

      if !engine.lastExpandedSummary.isEmpty {
        HStack(spacing: 4) {
          Image(systemName: "checkmark.seal.fill")
            .foregroundStyle(.green)
            .font(.system(size: 11))
          Text("Vừa bung: \(engine.lastExpandedSummary)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
  }

  // MARK: - Left Sidebar (Collections / Sets)

  private var collectionsSidebar: some View {
    VStack(spacing: 0) {
      List(selection: Binding(
        get: { selectedCollectionId ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")! },
        set: { newVal in
          let allSentinel = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
          selectedCollectionId = (newVal == allSentinel) ? nil : newVal
          selectedItemId = store.items(in: selectedCollectionId, searchQuery: studioSearchQuery).first?.id
        }
      )) {
        HStack {
          Image(systemName: "tray.full.fill")
            .foregroundStyle(Color.accentColor)
          Text("Tất cả Gõ tắt")
            .fontWeight(.medium)
          Spacer()
          Text("\(store.items.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .tag(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)

        Section("Bộ Gõ tắt (Kéo để đổi ưu tiên)") {
          ForEach(store.collections) { col in
            HStack(spacing: 6) {
              Toggle(
                "",
                isOn: Binding(
                  get: { col.isEnabled },
                  set: { store.setCollectionEnabled(col.id, isEnabled: $0) }
                )
              )
              .labelsHidden()
              .toggleStyle(.checkbox)

              Image(systemName: col.icon)
                .font(.system(size: 12))
                .foregroundStyle(col.isEnabled ? Color.accentColor : Color.secondary)

              Text(col.name)
                .lineLimit(1)
                .foregroundStyle(col.isEnabled ? Color.primary : Color.secondary)

              if !col.keywordPrefix.isEmpty {
                Text(col.keywordPrefix)
                  .font(.system(size: 9.5, design: .monospaced))
                  .padding(.horizontal, 4)
                  .padding(.vertical, 1)
                  .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.16)))
              }

              Spacer(minLength: 2)

              Text("\(store.itemCount(in: col.id))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .tag(col.id)
            .contextMenu {
              Button("Tạo Gõ tắt mới trong bộ này") {
                selectedCollectionId = col.id
                let created = store.createItem(in: col.id, name: "Gõ tắt mới")
                selectedItemId = created.id
                abbreviationFieldFocused = true
              }
              Button("Chỉnh sửa tên & tiền tố Bộ…") {
                editingCollection = col
              }
              Divider()
              Button("Xoá Bộ này", role: .destructive) {
                if selectedCollectionId == col.id {
                  selectedCollectionId = nil
                }
                store.deleteCollection(col.id)
              }
            }
          }
          .onMove { source, destination in
            store.moveCollections(fromOffsets: source, toOffset: destination)
          }
        }
      }
      .listStyle(.sidebar)

      Divider()

      HStack(spacing: 8) {
        Button {
          isCreatingCollection = true
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Thêm Bộ Gõ tắt mới")

        Button {
          if let colId = selectedCollectionId {
            selectedCollectionId = nil
            store.deleteCollection(colId)
          }
        } label: {
          Image(systemName: "minus")
        }
        .buttonStyle(.borderless)
        .disabled(selectedCollectionId == nil)
        .help("Xoá Bộ đang chọn")

        Button {
          if let colId = selectedCollectionId, let col = store.collection(for: colId) {
            editingCollection = col
          }
        } label: {
          Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .disabled(selectedCollectionId == nil)
        .help("Thiết lập Tiền tố (Prefix) / Hậu tố cho Bộ")

        Spacer()
        Text("\(store.activeExpansionCandidates.count) đang bật")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
  }

  // MARK: - Top-Right Snippets Table

  private var snippetsTablePane: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Từ gõ tắt")
          .frame(width: 115, alignment: .leading)
        Text("Tên gợi nhớ")
          .frame(width: 185, alignment: .leading)
        Text("Nội dung mở rộng")
          .frame(maxWidth: .infinity, alignment: .leading)
        Text("Chế độ")
          .frame(width: 68, alignment: .trailing)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      .background(Color(nsColor: .controlBackgroundColor))

      Divider()

      List(visibleItems, selection: $selectedItemId) { snippet in
        let col = store.collection(for: snippet.collectionId)
        let effAbbr = snippet.effectiveAbbreviation(in: col)
        let previewLine = snippet.content
          .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .shortened(to: 120)

        HStack(spacing: 8) {
          Text(effAbbr.isEmpty ? "—" : effAbbr)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(effAbbr.isEmpty ? Color.secondary : Color.accentColor)
            .lineLimit(1)
            .frame(width: 115, alignment: .leading)

          Text(snippet.displayTitle)
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .frame(width: 185, alignment: .leading)

          Text(previewLine)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

          HStack(spacing: 4) {
            Text(snippet.caseMode.shortSymbol)
              .font(.system(size: 10, weight: .medium, design: .monospaced))
              .foregroundStyle(.secondary)
            Image(systemName: snippet.triggerMode.badgeSymbol)
              .font(.system(size: 10.5))
              .foregroundStyle(snippet.triggerMode == .immediate ? Color.blue : Color.secondary)
          }
          .frame(width: 68, alignment: .trailing)
        }
        .opacity(snippet.isEnabled ? 1.0 : 0.45)
        .tag(snippet.id)
        .contextMenu {
          Button("Nhân bản Gõ tắt") {
            if let dup = store.duplicateItem(snippet.id) {
              selectedItemId = dup.id
            }
          }
          Button(snippet.isEnabled ? "Tạm tắt Gõ tắt này" : "Bật lại Gõ tắt này") {
            var copy = snippet
            copy.isEnabled.toggle()
            store.updateItem(copy)
          }
          Divider()
          Button("Xoá Gõ tắt", role: .destructive) {
            if selectedItemId == snippet.id {
              selectedItemId = nil
            }
            store.deleteItem(snippet.id)
          }
        }
      }
      .listStyle(.inset(alternatesRowBackgrounds: true))

      Divider()

      HStack(spacing: 10) {
        Button {
          let created = store.createItem(
            in: selectedCollectionId ?? store.collections.first?.id,
            name: "",
            abbreviation: "",
            content: ""
          )
          selectedItemId = created.id
          abbreviationFieldFocused = true
        } label: {
          Label("Thêm Gõ tắt", systemImage: "plus")
        }
        .controlSize(.small)

        Button {
          if let id = selectedItemId, let dup = store.duplicateItem(id) {
            selectedItemId = dup.id
          }
        } label: {
          Image(systemName: "plus.square.on.square")
        }
        .controlSize(.small)
        .disabled(selectedItemId == nil)
        .help("Nhân bản mục đang chọn")

        Button {
          if let id = selectedItemId {
            let list = visibleItems
            let currentIdx = list.firstIndex(where: { $0.id == id }) ?? 0
            store.deleteItem(id)
            let updatedList = visibleItems
            if updatedList.indices.contains(currentIdx) {
              selectedItemId = updatedList[currentIdx].id
            } else {
              selectedItemId = updatedList.last?.id
            }
          }
        } label: {
          Image(systemName: "trash")
        }
        .controlSize(.small)
        .disabled(selectedItemId == nil)
        .help("Xoá mục đang chọn")

        Spacer()

        Text("\(visibleItems.count) mục hiển thị")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
  }

  // MARK: - Bottom-Right Full Snippet Editor

  @ViewBuilder
  private var snippetEditorPane: some View {
    if let selected = currentSelectedItem {
      VStack(alignment: .leading, spacing: 8) {
        // Row 1: Abbreviation + Name + Collection + Enabled toggle
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Từ gõ tắt (Abbreviation)")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            TextField(
              "VD: \\bcc, ;reply (để trống nếu chỉ dùng ⌘⇧S)",
              text: Binding(
                get: { selected.abbreviation },
                set: { val in
                  var copy = selected
                  copy.abbreviation = val
                  if !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && copy.triggerMode == .manualOnly {
                    copy.triggerMode = .immediate
                  }
                  store.updateItem(copy)
                }
              )
            )
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .focused($abbreviationFieldFocused)
            .frame(minWidth: 180, maxWidth: 230)
          }

          VStack(alignment: .leading, spacing: 3) {
            Text("Tên gợi nhớ (hiển thị khi tìm ⌘⇧S)")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            TextField(
              "VD: Bộ công cụ thu thập dữ liệu, Mẫu Email phản hồi…",
              text: Binding(
                get: { selected.name },
                set: { val in
                  var copy = selected
                  copy.name = val
                  store.updateItem(copy)
                }
              )
            )
            .textFieldStyle(.roundedBorder)
          }

          VStack(alignment: .leading, spacing: 3) {
            Text("Thuộc Bộ")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Picker(
              "",
              selection: Binding(
                get: { selected.collectionId },
                set: { newColId in
                  var copy = selected
                  copy.collectionId = newColId
                  store.updateItem(copy)
                }
              )
            ) {
              ForEach(store.collections) { col in
                Text(col.name).tag(col.id)
              }
            }
            .labelsHidden()
            .frame(width: 170)
          }

          Toggle(
            "Bật",
            isOn: Binding(
              get: { selected.isEnabled },
              set: { val in
                var copy = selected
                copy.isEnabled = val
                store.updateItem(copy)
              }
            )
          )
          .padding(.top, 14)
        }

        // Row 2: Content Mode, Trigger Mode, Case Handling, Whole Word
        HStack(spacing: 10) {
          Picker(
            "Định dạng:",
            selection: Binding(
              get: { selected.contentMode },
              set: { mode in
                var copy = selected
                copy.contentMode = mode
                store.updateItem(copy)
              }
            )
          ) {
            ForEach(SnippetContentMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .controlSize(.small)
          .frame(maxWidth: 245)

          Picker(
            "Kích hoạt:",
            selection: Binding(
              get: { selected.triggerMode },
              set: { trig in
                var copy = selected
                copy.triggerMode = trig
                store.updateItem(copy)
              }
            )
          ) {
            ForEach(SnippetTriggerMode.allCases) { trig in
              Text(trig.title).tag(trig)
            }
          }
          .controlSize(.small)
          .frame(maxWidth: 255)

          Picker(
            "",
            selection: Binding(
              get: { selected.caseMode },
              set: { cm in
                var copy = selected
                copy.caseMode = cm
                store.updateItem(copy)
              }
            )
          ) {
            ForEach(SnippetCaseMode.allCases) { cm in
              Text(cm.title).tag(cm)
            }
          }
          .labelsHidden()
          .controlSize(.small)
          .frame(maxWidth: 215)

          Toggle(
            "Nguyên từ",
            isOn: Binding(
              get: { selected.wholeWord },
              set: { ww in
                var copy = selected
                copy.wholeWord = ww
                store.updateItem(copy)
              }
            )
          )
          .controlSize(.small)
          .help("Chỉ bung gõ tắt khi đứng độc lập (không dính liền sau chữ cái khác)")
        }

        // Row 3: Macro Insertion Toolbar `{...}`
        macroToolbar(for: selected)

        // Row 4: Body Editor (Text / Script / Image)
        if selected.contentMode == .image {
          imageEditorBody(for: selected)
        } else {
          TextEditor(
            text: Binding(
              get: { selected.content },
              set: { newBody in
                var copy = selected
                copy.content = newBody
                store.updateItem(copy)
              }
            )
          )
          .font(
            selected.contentMode == .plainText || selected.contentMode == .richText
              ? .system(size: 13.5)
              : .system(size: 12.5, design: .monospaced)
          )
          .padding(6)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
          .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        }

        if showLivePreviewBox {
          let previewStr = SnippetTemplateEngine.renderLivePreview(
            for: selected,
            fillInValues: [:],
            optionalToggles: [:],
            clipboardString: NSPasteboard.general.string(forType: .string) ?? ""
          )
          VStack(alignment: .leading, spacing: 3) {
            Text("Xem trước kết quả mở rộng (▏ là vị trí con trỏ sau khi chèn):")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(previewStr)
              .font(.system(size: 12))
              .lineLimit(4)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(6)
              .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.08)))
          }
        }
      }
      .padding(12)
    } else {
      VStack(spacing: 8) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 28))
          .foregroundStyle(.secondary)
        Text("Chọn một Gõ tắt ở bảng trên hoặc bấm \"Thêm Gõ tắt\" để bắt đầu")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func macroToolbar(for selected: SnippetItem) -> some View {
    HStack(spacing: 6) {
      Menu("{...} Biểu mẫu Fill-in") {
        Button("Ô nhập 1 dòng — {{input:Tên=Mặc định}}") {
          appendToken("{{input:Tên người nhận=}}", to: selected)
        }
        Button("Ô nhập nhiều dòng — {{textarea:Ghi chú}}") {
          appendToken("{{textarea:Nội dung chi tiết=}}", to: selected)
        }
        Button("Menu chọn (Dropdown) — {{select:Nhãn|*Mục 1|Mục 2}}") {
          appendToken("{{select:Danh xưng|*Anh|Chị|Thầy|Cô}}", to: selected)
        }
        Button("Đoạn văn tuỳ chọn bật/tắt — {{optional:...}}") {
          appendToken("{{optional:Đính kèm tài liệu=1}}Đính kèm tài liệu chi tiết.{{/optional}}", to: selected)
        }
      }
      .controlSize(.small)

      Menu("📅 Ngày & Giờ động") {
        Button("Ngày hôm nay (dd/MM/yyyy) — {{date:dd/MM/yyyy}}") {
          appendToken("{{date:dd/MM/yyyy}}", to: selected)
        }
        Button("Ngày chuẩn ISO (yyyy-MM-dd) — {{isodate}}") {
          appendToken("{{isodate}}", to: selected)
        }
        Button("Ngày & Giờ hiện tại — {{datetime}}") {
          appendToken("{{datetime}}", to: selected)
        }
        Divider()
        Button("+3 Ngày làm việc (bỏ T7, CN) — {{date +3bd:dd/MM/yyyy}}") {
          appendToken("{{date +3bd:dd/MM/yyyy}}", to: selected)
        }
        Button("+5 Ngày làm việc (bỏ T7, CN) — {{date +5bd:dd/MM/yyyy}}") {
          appendToken("{{date +5bd:dd/MM/yyyy}}", to: selected)
        }
        Button("+7 Ngày lịch — {{date +7d:dd/MM/yyyy}}") {
          appendToken("{{date +7d:dd/MM/yyyy}}", to: selected)
        }
        Button("-1 Tháng trước — {{date -1M:MM/yyyy}}") {
          appendToken("{{date -1M:MM/yyyy}}", to: selected)
        }
      }
      .controlSize(.small)

      Menu("⌨️ Phím & Con trỏ") {
        Button("Đặt con trỏ tại đây — {{cursor}}") {
          appendToken("{{cursor}}", to: selected)
        }
        Button("Nội dung Clipboard hiện tại — {{clipboard}}") {
          appendToken("{{clipboard}}", to: selected)
        }
        Divider()
        Button("Giả lập phím Tab (nhảy ô biểu mẫu) — {{tab}}") {
          appendToken("{{tab}}", to: selected)
        }
        Button("Giả lập phím Enter — {{enter}}") {
          appendToken("{{enter}}", to: selected)
        }
        Button("Giả lập phím Esc — {{esc}}") {
          appendToken("{{esc}}", to: selected)
        }
        Button("Tạm dừng 200ms giữa các bước — {{delay:200}}") {
          appendToken("{{delay:200}}", to: selected)
        }
        Divider()
        Button("Mã ngẫu nhiên UUID — {{uuid}}") {
          appendToken("{{uuid}}", to: selected)
        }
      }
      .controlSize(.small)

      Menu("⚡️ Chèn Script") {
        Button("Lệnh Shell nội tuyến — {{shell:...}}") {
          appendToken("{{shell:whoami}}", to: selected)
        }
        Button("AppleScript nội tuyến — {{applescript:...}}") {
          appendToken("{{applescript:return (system attribute \"USER\")}}", to: selected)
        }
        Button("JavaScript (JXA) nội tuyến — {{jxa:...}}") {
          appendToken("{{jxa:new Date().toLocaleDateString('vi-VN')}}", to: selected)
        }
      }
      .controlSize(.small)

      Spacer()

      Toggle("Xem trước", isOn: $showLivePreviewBox)
        .toggleStyle(.button)
        .controlSize(.small)
    }
  }

  private func imageEditorBody(for selected: SnippetItem) -> some View {
    VStack(spacing: 10) {
      if let data = selected.imagePNGData, let img = NSImage(data: data) {
        Image(nsImage: img)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 170)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      } else {
        Text("Chưa có hình ảnh cho Gõ tắt này")
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 10) {
        Button("Chọn tệp ảnh…") {
          let panel = NSOpenPanel()
          panel.allowedContentTypes = [.image]
          panel.allowsMultipleSelection = false
          if panel.runModal() == .OK,
             let url = panel.url,
             let img = NSImage(contentsOf: url),
             let tiff = img.tiffRepresentation,
             let rep = NSBitmapImageRep(data: tiff),
             let png = rep.representation(using: .png, properties: [:]) {
            var copy = selected
            copy.imagePNGData = png
            store.updateItem(copy)
          }
        }
        Button("Lấy ảnh từ Clipboard hiện tại") {
          if let img = NSImage(pasteboard: .general),
             let tiff = img.tiffRepresentation,
             let rep = NSBitmapImageRep(data: tiff),
             let png = rep.representation(using: .png, properties: [:]) {
            var copy = selected
            copy.imagePNGData = png
            store.updateItem(copy)
          }
        }
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
  }

  private func appendToken(_ token: String, to item: SnippetItem) {
    var copy = item
    copy.content += token
    store.updateItem(copy)
  }

  // MARK: - Import / Export Actions

  private func runAlfredImport() {
    do {
      let payload = try SnippetImporter.loadFromInstalledAlfred()
      let summary = store.importPayload(payload)
      statusBanner = "Đã nhập từ Alfred: \(summary.collectionsImported) bộ mới, +\(summary.snippetsImported) gõ tắt mới (cập nhật \(summary.snippetsUpdated) mục)."
      if selectedItemId == nil {
        selectedItemId = visibleItems.first?.id
      }
    } catch {
      presentErrorAlert(title: "Không thể nhập từ Alfred", message: error.localizedDescription)
    }
  }

  private func runTypinatorImport() {
    isImportingBusy = true
    Task { @MainActor in
      defer { isImportingBusy = false }
      do {
        let payload = try await SnippetImporter.loadFromInstalledTypinator()
        let summary = store.importPayload(payload)
        statusBanner = "Đã nhập từ Typinator: \(summary.collectionsImported) bộ mới, +\(summary.snippetsImported) gõ tắt mới (cập nhật \(summary.snippetsUpdated) mục)."
        if selectedItemId == nil {
          selectedItemId = visibleItems.first?.id
        }
        promptPauseTypinatorIfNeeded()
      } catch {
        presentErrorAlert(title: "Không thể nhập từ Typinator", message: error.localizedDescription)
      }
    }
  }

  private func promptPauseTypinatorIfNeeded() {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Tạm dừng gõ tắt của Typinator để tránh nhân đôi?"
    alert.informativeText = "Dữ liệu từ Typinator đã được nhập sang Maccy. Bạn có muốn Maccy gửi lệnh tạm dừng (Pause Expansions) sang Typinator để hai ứng dụng không cùng bung một từ gõ tắt (như \\bcc) cùng lúc không?"
    alert.addButton(withTitle: "Tạm dừng Typinator ngay")
    alert.addButton(withTitle: "Để sau")
    if alert.runModal() == .alertFirstButtonReturn {
      Task {
        _ = await SnippetImporter.pauseTypinatorExpansions()
      }
    }
  }

  private func runFileImportDialog() {
    let panel = NSOpenPanel()
    panel.title = "Chọn tệp hoặc thư mục Gõ tắt (.alfredsnippets, .alfredpreferences, .json, .csv, .tsv)"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      do {
        let payload = try SnippetImporter.loadFromFile(url: url)
        let summary = store.importPayload(payload)
        statusBanner = "Đã nhập từ \(summary.sourceDescription): +\(summary.snippetsImported) mục mới (cập nhật \(summary.snippetsUpdated) mục)."
      } catch {
        presentErrorAlert(title: "Lỗi nhập tệp Gõ tắt", message: error.localizedDescription)
      }
    }
  }

  private func runExportJSONDialog() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "maccy-snippets-backup.json"
    panel.allowedContentTypes = [.json]
    if panel.runModal() == .OK, let url = panel.url {
      if let data = try? SnippetImporter.exportToJSONData(collections: store.collections, items: store.items) {
        try? data.write(to: url, options: [.atomic])
        statusBanner = "Đã xuất \(store.items.count) gõ tắt ra \(url.lastPathComponent)."
      }
    }
  }

  private func runExportCSVDialog() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "maccy-snippets.csv"
    panel.allowedContentTypes = [.commaSeparatedText]
    if panel.runModal() == .OK, let url = panel.url {
      let csv = SnippetImporter.exportToCSVString(collections: store.collections, items: store.items)
      try? csv.data(using: .utf8)?.write(to: url, options: [.atomic])
      statusBanner = "Đã xuất \(store.items.count) gõ tắt ra \(url.lastPathComponent)."
    }
  }

  private func presentErrorAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.runModal()
  }
}

// MARK: - Collection Edit & Create Sheets

private struct CollectionEditSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State var collection: SnippetCollection
  let onSave: (SnippetCollection) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Thiết lập Bộ Gõ tắt")
        .font(.headline)

      VStack(alignment: .leading, spacing: 4) {
        Text("Tên Bộ:")
          .font(.caption.weight(.semibold))
        TextField("Tên bộ gõ tắt", text: $collection.name)
          .textFieldStyle(.roundedBorder)
      }

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Tiền tố chung (Prefix):")
            .font(.caption.weight(.semibold))
          TextField("VD: ; hoặc \\", text: $collection.keywordPrefix)
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Hậu tố chung (Suffix):")
            .font(.caption.weight(.semibold))
          TextField("Tuỳ chọn", text: $collection.keywordSuffix)
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        }
      }

      Toggle("Kích hoạt tự động gõ tắt cho Bộ này", isOn: $collection.isEnabled)

      HStack {
        Spacer()
        Button("Huỷ") { dismiss() }
        Button("Lưu thay đổi") {
          onSave(collection)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(18)
    .frame(width: 400)
  }
}

private struct NewCollectionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name: String = ""
  @State private var prefix: String = ""
  @State private var suffix: String = ""
  let onCreate: (String, String, String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Tạo Bộ Gõ tắt mới")
        .font(.headline)

      VStack(alignment: .leading, spacing: 4) {
        Text("Tên Bộ:")
          .font(.caption.weight(.semibold))
        TextField("VD: Nghiên cứu khoa học, Cá nhân…", text: $name)
          .textFieldStyle(.roundedBorder)
      }

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Tiền tố chung (Prefix):")
            .font(.caption.weight(.semibold))
          TextField("VD: ; hoặc \\", text: $prefix)
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Hậu tố chung (Suffix):")
            .font(.caption.weight(.semibold))
          TextField("Tuỳ chọn", text: $suffix)
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        }
      }

      HStack {
        Spacer()
        Button("Huỷ") { dismiss() }
        Button("Tạo Bộ") {
          onCreate(name, prefix, suffix)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(18)
    .frame(width: 390)
  }
}

// MARK: - Settings Tab ("Gõ tắt")

struct SnippetsSettingsPane: View {
  @Default(.textExpansionEnabled) private var textExpansionEnabled
  @Default(.restoreClipboardAfterExpansion) private var restoreClipboardAfterExpansion
  @Default(.expandPlaySound) private var expandPlaySound

  @State private var store = SnippetStore.shared
  @State private var quickImportStatus: String = ""

  var body: some View {
    Settings.Container(contentWidth: 460) {
      Settings.Section(title: "Gõ tắt tự động", bottomDivider: true) {
        Toggle("Bật tự động bung Gõ tắt (Text Expansion) trên mọi ứng dụng", isOn: $textExpansionEnabled)
        Toggle("Giữ nguyên Clipboard gốc sau khi bung Gõ tắt", isOn: $restoreClipboardAfterExpansion)
        Toggle("Phát âm thanh nhẹ khi bung Gõ tắt", isOn: $expandPlaySound)

        Text("Tự động tạm dừng an toàn khi con trỏ ở trong ô mật khẩu (Secure Input) và trong các ứng dụng nằm ở danh sách Bỏ qua (Ignore).")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Settings.Section(title: "Phím tắt mở nhanh", bottomDivider: true) {
        HStack {
          Text("Mở bảng tìm & chèn Gõ tắt:")
          KeyboardShortcuts.Recorder(for: .snippetsPopup)
        }
        Text("Hỗ trợ tìm Tiếng Việt không dấu theo tên gợi nhớ, từ khoá và nội dung (tương tự Alfred Snippets Viewer).")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Settings.Section(title: "Dữ liệu & Công cụ") {
        HStack(spacing: 10) {
          Button("Mở Trình quản lý Gõ tắt (Snippet Studio)…") {
            SnippetManagerWindowController.shared.show()
          }
          .buttonStyle(.borderedProminent)

          Text("\(store.collections.count) bộ • \(store.items.count) mục")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          if SnippetImporter.isTypinatorInstalled {
            Button("⚡ Nhập từ Typinator…") {
              SnippetManagerWindowController.shared.showAndImportTypinator()
            }
          }

          if SnippetImporter.isAlfredInstalled {
            Button("🎩 Nhập từ Alfred Snippets") {
              if let payload = try? SnippetImporter.loadFromInstalledAlfred() {
                let s = store.importPayload(payload)
                quickImportStatus = "Đã nhập từ Alfred: +\(s.snippetsImported) mới (cập nhật \(s.snippetsUpdated))."
              }
            }
          }
        }
        .padding(.top, 2)

        if !quickImportStatus.isEmpty {
          Text(quickImportStatus)
            .font(.caption)
            .foregroundStyle(.green)
        }
      }
    }
  }
}
