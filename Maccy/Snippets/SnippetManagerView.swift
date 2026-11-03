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
    hosting.sizingOptions = [.minSize]
    let win = NSWindow(contentViewController: hosting)
    win.title = "Quản lý Gõ tắt"
    win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    win.toolbarStyle = .unified
    win.setContentSize(NSSize(width: 1020, height: 670))
    win.minSize = NSSize(width: 820, height: 540)
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

// MARK: - Native macOS SplitView + Unified Toolbar Snippet Studio

struct SnippetStudioView: View {
  @State private var store = SnippetStore.shared
  @State private var engine = TextExpansionEngine.shared
  @Default(.textExpansionEnabled) private var textExpansionEnabled
  @Default(.ignoreEvents) private var ignoreEvents
  @Default(.cloudSyncEnabled) private var cloudSyncEnabled
  @Default(.cloudSyncFolderPath) private var cloudSyncFolderPath

  @State private var selectedScope: SnippetStudioScope = .all
  @State private var searchInSelectedScopeOnly: Bool = false
  @State private var selectedItemId: UUID?
  @State private var studioSearchQuery: String = ""

  @State private var showLiveTestPopover: Bool = false
  @State private var liveTestInput: String = ""

  @State private var editingCollection: SnippetCollection?
  @State private var isCreatingCollection: Bool = false

  @State private var statusBanner: String?
  @State private var isImportingBusy: Bool = false
  @State private var showLivePreviewBox: Bool = false

  @FocusState private var abbreviationFieldFocused: Bool
  @FocusState private var liveTestFieldFocused: Bool

  private var selectedCollectionId: UUID? {
    if case .collection(let id) = selectedScope {
      return id
    }
    return nil
  }

  private var isSearching: Bool {
    !studioSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var visibleItems: [SnippetItem] {
    store.items(
      for: selectedScope,
      searchQuery: studioSearchQuery,
      searchAllCollectionsWhenQuerying: !searchInSelectedScopeOnly
    )
  }

  private var currentSelectedItem: SnippetItem? {
    guard let id = selectedItemId else { return nil }
    return store.item(for: id)
  }

  private var isEngineReady: Bool {
    textExpansionEnabled && !ignoreEvents && engine.isEventTapActive
  }

  private var subtitleSummary: String {
    let statusText: String
    if !textExpansionEnabled || ignoreEvents {
      statusText = "Đang tạm dừng"
    } else if engine.isEventTapActive {
      statusText = "Đang bắt phím (\(store.activeExpansionItems.count) mục kích hoạt)"
    } else {
      statusText = "Chưa cấp quyền Bàn phím"
    }
    return "\(store.items.count) mục tổng • \(statusText)"
  }

  private var currentScopeShortLabel: String {
    switch selectedScope {
    case .all:
      return "Tất cả"
    case .activeTriggers:
      return "Đang kích hoạt"
    case .collection(let id):
      let name = store.collection(for: id)?.name ?? "Bộ đang chọn"
      return "Bộ \"\(name)\""
    }
  }

  var body: some View {
    NavigationSplitView {
      collectionsSidebar
        .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 295)
    } detail: {
      VStack(spacing: 0) {
        permissionAndDiagnosticsBanner

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
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 7)
          .background(Color.accentColor.opacity(0.09))
          Divider()
        }

        VSplitView {
          VStack(spacing: 0) {
            if isSearching && selectedScope != .all {
              searchScopeBar
              Divider()
            }
            snippetsNativeTablePane
          }
          .frame(minHeight: 175, idealHeight: 255)

          snippetInspectorPane
            .frame(minHeight: 255)
        }
      }
    }
    .navigationTitle("Quản lý Gõ tắt")
    .navigationSubtitle(subtitleSummary)
    .searchable(
      text: $studioSearchQuery,
      placement: .toolbar,
      prompt: "Tìm từ gõ tắt, tên, nội dung trên toàn bộ danh sách…"
    )
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        expansionStatusToolbarControl

        Button {
          createNewSnippet()
        } label: {
          Label("Thêm Gõ tắt", systemImage: "plus")
        }
        .help("Tạo mục Gõ tắt mới")

        Button {
          showLiveTestPopover.toggle()
        } label: {
          Label("Gõ thử", systemImage: "keyboard")
        }
        .help("Mở ô gõ thử nghiệm trực tiếp ngay trong cửa sổ này")
        .popover(isPresented: $showLiveTestPopover, arrowEdge: .bottom) {
          liveTestPopoverContent
        }

        importExportToolbarMenu
      }
    }
    .onAppear {
      engine.refreshStatusAndEnsureEventTap()
      if let req = SnippetManagerWindowController.shared.requestedSelectedItemId,
         let found = store.item(for: req) {
        selectedScope = .collection(found.collectionId)
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
    .onChange(of: studioSearchQuery) { _, _ in
      let current = visibleItems
      if let sel = selectedItemId, current.contains(where: { $0.id == sel }) {
        return
      }
      selectedItemId = current.first?.id
    }
    .onChange(of: liveTestFieldFocused) { _, focused in
      engine.isStudioTestFieldFocused = focused
    }
    .onChange(of: showLiveTestPopover) { _, shown in
      if shown {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
          liveTestFieldFocused = true
        }
      } else {
        engine.isStudioTestFieldFocused = false
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .snippetStudioSelectRequested)) { note in
      if let id = note.object as? UUID, let found = store.item(for: id) {
        selectedScope = .collection(found.collectionId)
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
        selectedScope = .collection(created.id)
      }
    }
  }

  private var searchScopeBar: some View {
    let allCount = store.items(for: .all, searchQuery: studioSearchQuery, searchAllCollectionsWhenQuerying: false).count
    let scopedCount = store.items(for: selectedScope, searchQuery: studioSearchQuery, searchAllCollectionsWhenQuerying: false).count

    return HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Text("Phạm vi tìm:")
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)

      scopePillButton(title: "Tất cả (\(allCount))", isSelected: !searchInSelectedScopeOnly) {
        searchInSelectedScopeOnly = false
        selectedItemId = visibleItems.first?.id
      }

      scopePillButton(title: "\(currentScopeShortLabel) (\(scopedCount))", isSelected: searchInSelectedScopeOnly) {
        searchInSelectedScopeOnly = true
        selectedItemId = visibleItems.first?.id
      }

      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .background(Color.primary.opacity(0.03))
  }

  private func scopePillButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(
          Capsule()
            .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Unified macOS Toolbar Items

  private var expansionStatusToolbarControl: some View {
    HStack(spacing: 6) {
      Toggle(isOn: $textExpansionEnabled) {
        HStack(spacing: 5) {
          Circle()
            .fill(isEngineReady ? Color.green : (textExpansionEnabled ? Color.orange : Color.secondary.opacity(0.5)))
            .frame(width: 7.5, height: 7.5)
          Text(textExpansionEnabled ? "Tự động" : "Đã tắt")
            .font(.system(size: 12, weight: .medium))
        }
      }
      .toggleStyle(.switch)
      .controlSize(.small)
      .help("Bật hoặc tạm dừng tự động bung Gõ tắt trên toàn hệ thống")

      if textExpansionEnabled && !isEngineReady {
        Button {
          if ignoreEvents {
            ignoreEvents = false
          } else {
            engine.requestOrRepairAccessibilityPermission(resetStaleTCC: true)
          }
        } label: {
          Text("Cấp quyền")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.orange)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }

  private var importExportToolbarMenu: some View {
    Menu {
      Section("Nhập dữ liệu") {
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
          Label("Nhập từ tệp (.alfredsnippets, .json, .csv)…", systemImage: "square.and.arrow.down")
        }

        Menu {
          ForEach(SnippetStarterPackID.allCases) { pack in
            Button(pack.title) {
              let summary = store.importPayload(SnippetImporter.starterPackPayload(for: pack))
              statusBanner = "Đã cài gói \"\(summary.sourceDescription)\" (+\(summary.snippetsImported) mục mới)."
            }
          }
        } label: {
          Label("Cài đặt Gói mẫu có sẵn", systemImage: "shippingbox")
        }
      }

      Section("Làm sạch & Đồng nhất") {
        Button {
          let result = store.deduplicateAndSanitizeNow()
          if result.didMutate {
            statusBanner = "Đã gộp \(result.mergedCollectionsCount) bộ trùng và xoá \(result.removedDuplicateItemsCount) mục trùng lặp."
          } else {
            statusBanner = "Danh sách đã đồng nhất, không có Bộ hay Gõ tắt nào bị trùng lặp."
          }
        } label: {
          Label("Gộp Bộ trùng & Dọn trùng lặp", systemImage: "sparkles")
        }
      }

      Section("Sao lưu & Đồng bộ") {
        if cloudSyncEnabled {
          Button {
            Task { @MainActor in
              await store.syncWithGoogleDrive()
              statusBanner = store.lastSnippetSyncMessage.isEmpty
                ? "Không tìm thấy thư mục Google Drive trên máy này."
                : store.lastSnippetSyncMessage
            }
          } label: {
            Label("Đồng bộ Google Drive ngay", systemImage: "arrow.triangle.2.circlepath.icloud")
          }
        }

        Button {
          runExportJSONDialog()
        } label: {
          Label("Xuất toàn bộ ra tệp JSON…", systemImage: "square.and.arrow.up")
        }

        Button {
          runExportCSVDialog()
        } label: {
          Label("Xuất bảng ra tệp CSV (Excel)…", systemImage: "tablecells")
        }
      }
    } label: {
      Label(isImportingBusy ? "Đang nhập…" : "Nhập / Xuất", systemImage: "ellipsis.circle")
    }
    .disabled(isImportingBusy)
    .help("Nhập từ Typinator, Alfred, dọn trùng lặp hoặc xuất sao lưu")
  }

  private var liveTestPopoverContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: "keyboard.fill")
          .foregroundStyle(Color.accentColor)
        Text("Ô gõ thử nghiệm trực tiếp")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        if !liveTestInput.isEmpty {
          Button("Xoá") {
            liveTestInput = ""
            engine.resetBuffer()
          }
          .controlSize(.small)
          .buttonStyle(.link)
        }
      }

      TextField("Gõ thử từ gõ tắt (VD: 009, \\bcc…) ngay tại đây", text: $liveTestInput)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13))
        .focused($liveTestFieldFocused)
        .frame(width: 340)

      if !isEngineReady {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text("Cần bật quyền Bàn phím trước khi gõ thử.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Cấp quyền") {
            showLiveTestPopover = false
            engine.requestOrRepairAccessibilityPermission(resetStaleTCC: true)
          }
          .controlSize(.mini)
          .buttonStyle(.borderedProminent)
          .tint(.orange)
        }
      } else if !engine.lastExpandedSummary.isEmpty {
        HStack(spacing: 5) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.caption)
          Text("Gần nhất: \(engine.lastExpandedSummary)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } else {
        Text("Mẹo: Với mục chọn chế độ \"Sau khoảng trắng\", hãy gõ thêm dấu cách sau từ gõ tắt.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
  }

  // MARK: - Conditional Permission & Diagnostic Callout

  @ViewBuilder
  private var permissionAndDiagnosticsBanner: some View {
    if textExpansionEnabled && ignoreEvents {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: "pause.circle.fill")
            .foregroundStyle(.orange)
          Text("Maccy đang bật chế độ Tạm dừng ghi sự kiện toàn cục (Ignore Events).")
            .font(.system(size: 12, weight: .medium))
          Spacer()
          Button("Tiếp tục hoạt động") {
            ignoreEvents = false
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        Divider()
      }
    } else if textExpansionEnabled && !engine.isEventTapActive {
      VStack(spacing: 0) {
        HStack(alignment: .center, spacing: 12) {
          Image(systemName: "hand.raised.circle.fill")
            .font(.system(size: 20))
            .foregroundStyle(.orange)

          VStack(alignment: .leading, spacing: 2) {
            Text("Cần cấp quyền Trợ năng (Accessibility) để tự động bung Gõ tắt")
              .font(.system(size: 12.5, weight: .semibold))
            Text("Khi cập nhật phiên bản mới, chữ ký cũ trong System Settings không còn hiệu lực. Bấm nút bên phải để làm mới rồi bật công tắc Maccy.")
              .font(.system(size: 11.5))
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 8)

          Button {
            engine.requestOrRepairAccessibilityPermission(resetStaleTCC: true)
          } label: {
            Label("Làm mới & Cấp quyền", systemImage: "bolt.shield.fill")
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
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        Divider()
      }
    } else if textExpansionEnabled && engine.isSecureInputLocked {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: "lock.shield")
            .foregroundStyle(.secondary)
          Text("macOS đang bật Secure Keyboard Input (do ô mật khẩu / Terminal / 1Password), gõ tắt sẽ tự tạm ẩn trong ô bảo mật đó.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.07))
        Divider()
      }
    }
  }

  // MARK: - Left Sidebar (Native macOS Translucent Sidebar)

  private var collectionsSidebar: some View {
    VStack(spacing: 0) {
      List(selection: Binding(
        get: { selectedScope },
        set: { newScope in
          selectedScope = newScope
          if newScope == .all {
            searchInSelectedScopeOnly = false
          }
          selectedItemId = store.items(
            for: newScope,
            searchQuery: studioSearchQuery,
            searchAllCollectionsWhenQuerying: !searchInSelectedScopeOnly
          ).first?.id
        }
      )) {
        Section("Tổng quan") {
          HStack(spacing: 8) {
            Image(systemName: "tray.full")
              .foregroundStyle(Color.accentColor)
              .frame(width: 16)
            Text("Tất cả Mục")
              .fontWeight(.medium)
            Spacer()
            Text("\(store.items.count)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .tag(SnippetStudioScope.all)

          HStack(spacing: 8) {
            Image(systemName: "bolt.circle.fill")
              .foregroundStyle(isEngineReady ? Color.green : Color.orange)
              .frame(width: 16)
            Text("Đang kích hoạt gõ phím")
              .fontWeight(.medium)
            Spacer()
            Text("\(store.activeExpansionItems.count)")
              .font(.caption.monospacedDigit().weight(.semibold))
              .foregroundStyle(isEngineReady ? Color.green : Color.secondary)
          }
          .tag(SnippetStudioScope.activeTriggers)
          .help("Danh sách chính xác các từ gõ tắt đang tự động bắt phím trên toàn hệ thống")
        }

        Section("Bộ Gõ tắt") {
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
              .controlSize(.small)

              Image(systemName: col.icon)
                .font(.system(size: 12))
                .foregroundStyle(col.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 15)

              Text(col.name)
                .lineLimit(1)
                .foregroundStyle(col.isEnabled ? Color.primary : Color.secondary)

              if !col.keywordPrefix.isEmpty {
                Text(col.keywordPrefix)
                  .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 4)
                  .padding(.vertical, 1)
                  .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.primary.opacity(0.08)))
              }

              Spacer(minLength: 2)

              Text("\(store.itemCount(in: col.id))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .tag(SnippetStudioScope.collection(col.id))
            .contextMenu {
              Button("Thêm Gõ tắt vào Bộ này") {
                selectedScope = .collection(col.id)
                createNewSnippet(in: col.id)
              }
              Button("Đổi tên & Tiền tố Bộ…") {
                editingCollection = col
              }
              Divider()
              Button("Xoá Bộ này", role: .destructive) {
                if selectedCollectionId == col.id {
                  selectedScope = .all
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

      HStack(spacing: 12) {
        Button {
          isCreatingCollection = true
        } label: {
          Label("Bộ mới", systemImage: "folder.badge.plus")
            .font(.system(size: 11.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Tạo Bộ Gõ tắt mới")

        Spacer()

        if let colId = selectedCollectionId, let col = store.collection(for: colId) {
          Button {
            editingCollection = col
          } label: {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 11.5))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Chỉnh sửa tên & tiền tố Bộ đang chọn")

          Button {
            selectedScope = .all
            store.deleteCollection(colId)
          } label: {
            Image(systemName: "trash")
              .font(.system(size: 11.5))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Xoá Bộ đang chọn")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  }

  // MARK: - Top-Right Native macOS NSTableView (`SwiftUI.Table`)

  private var snippetsNativeTablePane: some View {
    Table(visibleItems, selection: $selectedItemId) {
      TableColumn("Từ gõ tắt") { snippet in
        let col = store.collection(for: snippet.collectionId)
        let effAbbr = snippet.effectiveAbbreviation(in: col)
        let isLive = store.isActivelyExpanding(snippet)
        if effAbbr.isEmpty {
          Text("—")
            .foregroundStyle(.tertiary)
        } else {
          Text(effAbbr)
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(isLive ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isLive ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.06))
            )
            .lineLimit(1)
        }
      }
      .width(min: 80, ideal: 105, max: 165)

      TableColumn("Tên gợi nhớ") { snippet in
        let colEnabled = store.collection(for: snippet.collectionId)?.isEnabled ?? true
        Text(snippet.displayTitle)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle((snippet.isEnabled && colEnabled) ? Color.primary : Color.secondary)
          .lineLimit(1)
      }
      .width(min: 130, ideal: 185, max: 290)

      TableColumn("Bộ Gõ tắt") { snippet in
        if let col = store.collection(for: snippet.collectionId) {
          HStack(spacing: 4) {
            if !col.isEnabled {
              Image(systemName: "pause.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Text(col.name)
              .font(.system(size: 11.5))
              .foregroundStyle(col.isEnabled ? Color.secondary : Color.secondary.opacity(0.6))
              .lineLimit(1)
          }
        } else {
          Text("—")
            .foregroundStyle(.tertiary)
        }
      }
      .width(min: 95, ideal: 125, max: 170)

      TableColumn("Nội dung mở rộng") { snippet in
        let previewLine = store.singleLinePreview(for: snippet)
        Text(previewLine.isEmpty ? "(Trống)" : previewLine)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      TableColumn("Trạng thái") { snippet in
        let col = store.collection(for: snippet.collectionId)
        let effAbbr = snippet.effectiveAbbreviation(in: col)
        let status = statusBadgeInfo(for: snippet, collection: col, effectiveAbbreviation: effAbbr)
        HStack(spacing: 4) {
          Image(systemName: status.symbol)
            .font(.system(size: 10))
            .foregroundStyle(status.color)
          Text(status.label)
            .font(.system(size: 11))
            .foregroundStyle(status.isMuted ? Color.secondary.opacity(0.75) : Color.secondary)
            .lineLimit(1)
        }
      }
      .width(min: 95, ideal: 112, max: 135)
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
    .contextMenu(forSelectionType: SnippetItem.ID.self) { ids in
      if let targetId = ids.first, let snippet = store.item(for: targetId) {
        Button {
          if let dup = store.duplicateItem(snippet.id) {
            selectedItemId = dup.id
          }
        } label: {
          Label("Nhân bản Gõ tắt", systemImage: "plus.square.on.square")
        }

        Button {
          var copy = snippet
          copy.isEnabled.toggle()
          store.updateItem(copy)
        } label: {
          Label(
            snippet.isEnabled ? "Tạm tắt mục này" : "Bật lại mục này",
            systemImage: snippet.isEnabled ? "pause.circle" : "play.circle"
          )
        }

        Divider()

        Button(role: .destructive) {
          deleteSnippetAndAdvanceSelection(snippet.id)
        } label: {
          Label("Xoá Gõ tắt", systemImage: "trash")
        }
      }
    }
  }

  private func statusBadgeInfo(
    for snippet: SnippetItem,
    collection: SnippetCollection?,
    effectiveAbbreviation: String
  ) -> (symbol: String, label: String, color: Color, isMuted: Bool) {
    if collection?.isEnabled == false {
      return ("pause.circle", "Bộ đang tắt", .secondary, true)
    }
    if !snippet.isEnabled {
      return ("pause.circle", "Đã tạm tắt", .secondary, true)
    }
    if snippet.triggerMode == .manualOnly || effectiveAbbreviation.isEmpty {
      return ("hand.tap", "Thủ công", .secondary, false)
    }
    switch snippet.triggerMode {
    case .immediate:
      return ("bolt.fill", "Tức thì", Color.accentColor, false)
    case .afterDelimiter:
      return ("space", "Sau dấu cách", Color.green, false)
    case .manualOnly:
      return ("hand.tap", "Thủ công", .secondary, false)
    }
  }

  // MARK: - Bottom-Right Native macOS Inspector & Content Editor

  @ViewBuilder
  private var snippetInspectorPane: some View {
    if let selected = currentSelectedItem {
      let parentCol = store.collection(for: selected.collectionId)
      let effectiveAbbr = selected.effectiveAbbreviation(in: parentCol)

      VStack(alignment: .leading, spacing: 10) {
        // Row 1: Primary Identity Fields + Item Actions
        HStack(alignment: .bottom, spacing: 10) {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
              Text("Từ gõ tắt")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              if effectiveAbbr != selected.abbreviation && !effectiveAbbr.isEmpty {
                Text("(\(effectiveAbbr))")
                  .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                  .foregroundStyle(Color.accentColor)
              }
            }
            TextField(
              "VD: 009, \\bcc, ;reply",
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
            .frame(minWidth: 165, maxWidth: 215)
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Tên gợi nhớ")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            TextField(
              "Mô tả ngắn gọn (dùng khi tìm nhanh ⇧⌘S)…",
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

          VStack(alignment: .leading, spacing: 4) {
            Text("Bộ Gõ tắt")
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
            .frame(width: 165)
          }

          HStack(spacing: 8) {
            Toggle(
              "Đang bật",
              isOn: Binding(
                get: { selected.isEnabled },
                set: { val in
                  var copy = selected
                  copy.isEnabled = val
                  store.updateItem(copy)
                }
              )
            )
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()
              .frame(height: 18)

            Button {
              if let dup = store.duplicateItem(selected.id) {
                selectedItemId = dup.id
              }
            } label: {
              Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .help("Nhân bản Gõ tắt này")

            Button(role: .destructive) {
              deleteSnippetAndAdvanceSelection(selected.id)
            } label: {
              Image(systemName: "trash")
                .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Xoá Gõ tắt này")
          }
          .padding(.bottom, 3)
        }

        // Row 2: Grouped macOS Behavior & Macro Strip
        HStack(spacing: 10) {
          Picker(
            "Loại:",
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
          .frame(maxWidth: 215)

          Picker(
            "Mở rộng:",
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
          .frame(maxWidth: 235)

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
          .frame(maxWidth: 195)

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
          .help("Chỉ bung khi từ gõ tắt đứng độc lập (không dính liền sau chữ cái/số khác)")

          Spacer(minLength: 4)

          insertMacroMenu(for: selected)

          Toggle(isOn: $showLivePreviewBox) {
            Image(systemName: "eye")
          }
          .toggleStyle(.button)
          .controlSize(.small)
          .help("Ẩn/hiện khung xem trước kết quả mở rộng")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.04))
        )

        // Row 3: Main Body Editor
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
          .scrollContentBackground(.hidden)
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color(nsColor: .textBackgroundColor))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(Color.primary.opacity(0.12), lineWidth: 1)
          )
        }

        let shouldAutoPreview = selected.content.contains("{{")
          || selected.content.contains("{date")
          || selected.content.contains("{YYYY}")
          || selected.content.contains("%Y")
        if showLivePreviewBox || shouldAutoPreview {
          let previewStr = SnippetTemplateEngine.renderLivePreview(
            for: selected,
            fillInValues: [:],
            optionalToggles: [:],
            clipboardString: NSPasteboard.general.string(forType: .string) ?? ""
          )
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
              .foregroundStyle(Color.accentColor)
              .font(.caption)
              .padding(.top, 2)
            Text("Xem trước: ")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.secondary)
            + Text(previewStr.isEmpty ? "(Trống)" : previewStr)
              .font(.system(size: 12, weight: .medium))
          }
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(Color.accentColor.opacity(0.08))
          )
        }
      }
      .padding(14)
      .background(Color(nsColor: .windowBackgroundColor))
    } else {
      ContentUnavailableView {
        Label("Chưa chọn Gõ tắt", systemImage: "bolt.horizontal.circle")
      } description: {
        Text("Chọn một mục ở bảng phía trên hoặc nhấn nút + trên thanh công cụ để tạo Gõ tắt mới.")
      } actions: {
        Button("Tạo Gõ tắt mới") {
          createNewSnippet()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func insertMacroMenu(for selected: SnippetItem) -> some View {
    Menu {
      Menu("Biểu mẫu nhập liệu (Fill-in)") {
        Button("Ô nhập 1 dòng — {{input:Tên=}}") {
          appendToken("{{input:Tên người nhận=}}", to: selected)
        }
        Button("Ô nhập nhiều dòng — {{textarea:Ghi chú}}") {
          appendToken("{{textarea:Nội dung chi tiết=}}", to: selected)
        }
        Button("Danh sách chọn — {{select:Nhãn|*Mục 1|Mục 2}}") {
          appendToken("{{select:Danh xưng|*Anh|Chị|Thầy|Cô}}", to: selected)
        }
        Button("Đoạn văn tuỳ chọn — {{optional:...}}") {
          appendToken("{{optional:Đính kèm tài liệu=1}}Đính kèm tài liệu chi tiết.{{/optional}}", to: selected)
        }
      }

      Menu("Ngày & Giờ tự động") {
        Button("Ngày viết liền (yyyyMMdd — VD: 20261103)") {
          appendToken("{{date:yyyyMMdd}}", to: selected)
        }
        Button("Ngày giờ viết liền (yyyyMMdd_HHmm)") {
          appendToken("{{date:yyyyMMdd_HHmm}}", to: selected)
        }
        Button("Ngày hôm nay (dd/MM/yyyy)") {
          appendToken("{{date:dd/MM/yyyy}}", to: selected)
        }
        Button("Ngày chuẩn ISO (yyyy-MM-dd)") {
          appendToken("{{isodate}}", to: selected)
        }
        Button("Ngày & Giờ hiện tại (dd/MM/yyyy HH:mm)") {
          appendToken("{{datetime}}", to: selected)
        }
        Button("Giờ hiện tại (HH:mm:ss)") {
          appendToken("{{time:HH:mm:ss}}", to: selected)
        }
        Divider()
        Button("+3 Ngày làm việc (bỏ T7, CN)") {
          appendToken("{{date +3bd:dd/MM/yyyy}}", to: selected)
        }
        Button("+5 Ngày làm việc (bỏ T7, CN)") {
          appendToken("{{date +5bd:dd/MM/yyyy}}", to: selected)
        }
        Button("-1 Ngày hôm qua (yyyyMMdd)") {
          appendToken("{{date -1d:yyyyMMdd}}", to: selected)
        }
        Button("+7 Ngày lịch (dd/MM/yyyy)") {
          appendToken("{{date +7d:dd/MM/yyyy}}", to: selected)
        }
        Button("-1 Tháng trước (MM/yyyy)") {
          appendToken("{{date -1M:MM/yyyy}}", to: selected)
        }
      }

      Menu("Phím bấm, Con trỏ & Clipboard") {
        Button("Đặt vị trí con trỏ tại đây — {{cursor}}") {
          appendToken("{{cursor}}", to: selected)
        }
        Button("Dán nội dung Clipboard — {{clipboard}}") {
          appendToken("{{clipboard}}", to: selected)
        }
        Divider()
        Button("Nhấn phím Tab — {{tab}}") {
          appendToken("{{tab}}", to: selected)
        }
        Button("Nhấn phím Enter — {{enter}}") {
          appendToken("{{enter}}", to: selected)
        }
        Button("Nhấn phím Esc — {{esc}}") {
          appendToken("{{esc}}", to: selected)
        }
        Button("Chờ 200ms — {{delay:200}}") {
          appendToken("{{delay:200}}", to: selected)
        }
        Divider()
        Button("Mã UUID ngẫu nhiên — {{uuid}}") {
          appendToken("{{uuid}}", to: selected)
        }
      }

      Menu("Chạy lệnh Script nội tuyến") {
        Button("Shell Script — {{shell:...}}") {
          appendToken("{{shell:whoami}}", to: selected)
        }
        Button("AppleScript — {{applescript:...}}") {
          appendToken("{{applescript:return (system attribute \"USER\")}}", to: selected)
        }
        Button("JavaScript (JXA) — {{jxa:...}}") {
          appendToken("{{jxa:new Date().toLocaleDateString('vi-VN')}}", to: selected)
        }
      }
    } label: {
      Label("Chèn biến {…}", systemImage: "curlybraces")
    }
    .controlSize(.small)
  }

  private func imageEditorBody(for selected: SnippetItem) -> some View {
    VStack(spacing: 10) {
      if let data = selected.imagePNGData, let img = NSImage(data: data) {
        Image(nsImage: img)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 165)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      } else {
        Label("Chưa có hình ảnh cho Gõ tắt này", systemImage: "photo")
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
        Button("Dán ảnh từ Clipboard") {
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
    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))
  }

  // MARK: - Item & Import/Export Helpers

  private func createNewSnippet(in collectionId: UUID? = nil) {
    let targetCol = collectionId
      ?? selectedCollectionId
      ?? store.collections.first(where: \.isEnabled)?.id
      ?? store.collections.first?.id
    let created = store.createItem(
      in: targetCol,
      name: "",
      abbreviation: "",
      content: ""
    )
    if selectedScope == .activeTriggers {
      selectedScope = .collection(created.collectionId)
    }
    selectedItemId = created.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      abbreviationFieldFocused = true
    }
  }

  private func deleteSnippetAndAdvanceSelection(_ id: UUID) {
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

  private func appendToken(_ token: String, to item: SnippetItem) {
    var copy = item
    copy.content += token
    store.updateItem(copy)
  }

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
    alert.informativeText = "Dữ liệu từ Typinator đã được nhập sang Maccy. Bạn có muốn Maccy gửi lệnh tạm dừng (Pause Expansions) sang Typinator để hai ứng dụng không cùng bung một từ gõ tắt cùng lúc không?"
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

// MARK: - Native macOS Form Sheets for Collections

private struct CollectionEditSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State var collection: SnippetCollection
  let onSave: (SnippetCollection) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Thiết lập Bộ Gõ tắt")
        .font(.headline)

      Form {
        TextField("Tên Bộ:", text: $collection.name)
        TextField("Tiền tố chung (VD: ; hoặc \\):", text: $collection.keywordPrefix)
          .font(.system(.body, design: .monospaced))
        TextField("Hậu tố chung (tuỳ chọn):", text: $collection.keywordSuffix)
          .font(.system(.body, design: .monospaced))
        Toggle("Bật tự động bung Gõ tắt cho Bộ này", isOn: $collection.isEnabled)
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Huỷ") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Lưu") {
          onSave(collection)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
    .frame(width: 420, height: 290)
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

      Form {
        TextField("Tên Bộ:", text: $name, prompt: Text("VD: Nghiên cứu, Email mẫu…"))
        TextField("Tiền tố chung:", text: $prefix, prompt: Text("VD: ; hoặc \\"))
          .font(.system(.body, design: .monospaced))
        TextField("Hậu tố chung:", text: $suffix, prompt: Text("Tuỳ chọn"))
          .font(.system(.body, design: .monospaced))
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Huỷ") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Tạo Bộ") {
          onCreate(name, prefix, suffix)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
    .frame(width: 420, height: 265)
  }
}

// MARK: - Settings Tab ("Gõ tắt")

struct SnippetsSettingsPane: View {
  @Default(.textExpansionEnabled) private var textExpansionEnabled
  @Default(.restoreClipboardAfterExpansion) private var restoreClipboardAfterExpansion
  @Default(.expandPlaySound) private var expandPlaySound

  @State private var store = SnippetStore.shared
  @State private var engine = TextExpansionEngine.shared
  @State private var quickImportStatus: String = ""

  var body: some View {
    Settings.Container(contentWidth: 460) {
      Settings.Section(title: "Gõ tắt tự động", bottomDivider: true) {
        Toggle("Bật tự động bung Gõ tắt (Text Expansion) trên mọi ứng dụng", isOn: $textExpansionEnabled)
        Toggle("Giữ nguyên Clipboard gốc sau khi bung Gõ tắt", isOn: $restoreClipboardAfterExpansion)
        Toggle("Phát âm thanh nhẹ khi bung Gõ tắt", isOn: $expandPlaySound)

        HStack(spacing: 8) {
          Circle()
            .fill(engine.isEventTapActive ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
          Text(engine.isEventTapActive ? "Trạng thái quyền Bàn phím: Đang hoạt động" : "Trạng thái quyền Bàn phím: Chưa cấp quyền")
            .font(.caption.weight(.medium))
            .foregroundStyle(engine.isEventTapActive ? Color.secondary : Color.orange)

          if !engine.isEventTapActive {
            Button("Làm mới & Cấp quyền") {
              engine.requestOrRepairAccessibilityPermission(resetStaleTCC: true)
            }
            .controlSize(.mini)
          }
        }
        .padding(.top, 2)
      }

      Settings.Section(title: "Phím tắt mở nhanh", bottomDivider: true) {
        HStack {
          Text("Mở bảng tìm & chèn Gõ tắt:")
          KeyboardShortcuts.Recorder(for: .snippetsPopup)
        }
        Text("Hỗ trợ tìm Tiếng Việt không dấu theo tên gợi nhớ, từ khoá và nội dung.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Settings.Section(title: "Quản lý & Nhập dữ liệu") {
        HStack(spacing: 10) {
          Button("Mở Quản lý Gõ tắt (Snippet Studio)…") {
            SnippetManagerWindowController.shared.show()
          }
          .buttonStyle(.borderedProminent)

          Text("\(store.collections.count) bộ • \(store.items.count) mục")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          if SnippetImporter.isTypinatorInstalled {
            Button("Nhập từ Typinator…") {
              SnippetManagerWindowController.shared.showAndImportTypinator()
            }
          }

          if SnippetImporter.isAlfredInstalled {
            Button("Nhập từ Alfred Snippets") {
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
