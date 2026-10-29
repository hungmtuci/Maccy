import SwiftUI
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import Settings

struct GeneralSettingsPane: View {
  private let notificationsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(Bundle.main.bundleIdentifier ?? "")"
  )

  @Default(.searchMode) private var searchMode

  @State private var copyModifier = HistoryItemAction.copy.modifierFlags.description
  @State private var pasteModifier = HistoryItemAction.paste.modifierFlags.description
  @State private var pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description

  @State private var updater = SoftwareUpdater.shared

  var body: some View {
    Settings.Container(contentWidth: 460) {
      Settings.Section(title: "", bottomDivider: true) {
        LaunchAtLogin.Toggle {
          Text("LaunchAtLogin", tableName: "GeneralSettings")
        }
        Toggle(isOn: $updater.automaticallyChecksForUpdates) {
          Text("CheckForUpdates", tableName: "GeneralSettings")
        }
        HStack(spacing: 10) {
          Button {
            updater.checkForUpdates()
          } label: {
            if let newTag = updater.availableReleaseTag {
              Label("Cập nhật ngay (\(newTag))", systemImage: "arrow.down.circle.fill")
            } else {
              Text("CheckNow", tableName: "GeneralSettings")
            }
          }
          .disabled(updater.isChecking || updater.isInstallingUpdate)

          if updater.isChecking {
            ProgressView()
              .controlSize(.small)
          }

          Text("v\(updater.currentVersionString)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

          Spacer()

          Link("GitHub Releases ↗", destination: SoftwareUpdater.releasesPageURL)
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
      }

      Settings.Section(label: { Text("Open", tableName: "GeneralSettings") }) {
        KeyboardShortcuts.Recorder(for: .popup, onChange: { newShortcut in
          if newShortcut == nil {
            // No shortcut is recorded. Remove keys monitor
            AppState.shared.popup.deinitEventsMonitor()
          } else {
            // User is using shortcut. Ensure keys monitor is initialized
            AppState.shared.popup.initEventsMonitor()
          }
        })
          .help(Text("OpenTooltip", tableName: "GeneralSettings"))
          .accessibilityLabel(Text("Open", tableName: "GeneralSettings"))
      }

      Settings.Section(label: { Text("Dán Plain Text:") }) {
        KeyboardShortcuts.Recorder(for: .pasteLatestPlainText)
          .help("Dán ngay nội dung copy gần nhất dưới dạng văn bản thuần không định dạng (Mặc định: ⇧⌘C)")
          .accessibilityLabel(Text("Dán Plain Text gần nhất"))
      }

      Settings.Section(label: { Text("Pin", tableName: "GeneralSettings") }) {
        KeyboardShortcuts.Recorder(for: .pin)
          .help(Text("PinTooltip", tableName: "GeneralSettings"))
          .accessibilityLabel(Text("Pin", tableName: "GeneralSettings"))
      }
      Settings.Section(label: { Text("Delete", tableName: "GeneralSettings") }
      ) {
        KeyboardShortcuts.Recorder(for: .delete)
          .help(Text("DeleteTooltip", tableName: "GeneralSettings"))
          .accessibilityLabel(Text("Delete", tableName: "GeneralSettings"))
      }
      Settings.Section(
        bottomDivider: true,
        label: { Text("ShowPreview", tableName: "GeneralSettings") }
      ) {
        KeyboardShortcuts.Recorder(for: .togglePreview)
          .help(Text("ShowPreviewTooltip", tableName: "GeneralSettings"))
          .accessibilityLabel(Text("ShowPreview", tableName: "GeneralSettings"))
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Search", tableName: "GeneralSettings") }
      ) {
        Picker("", selection: $searchMode) {
          ForEach(Search.Mode.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .accessibilityLabel(Text("Search", tableName: "GeneralSettings"))
        .frame(width: 180, alignment: .leading)
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Behavior", tableName: "GeneralSettings") }
      ) {
        Defaults.Toggle(key: .pasteByDefault) {
          Text("PasteAutomatically", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .fixedSize()

        Defaults.Toggle(key: .removeFormattingByDefault) {
          Text("PasteWithoutFormatting", tableName: "GeneralSettings")
        }
        .onChange(refreshModifiers)
        .fixedSize()

        Defaults.Toggle(key: .cleanRichURLsFromBrowsers) {
          Text("Tự làm sạch Rich Link khi copy URL (Microsoft Edge / Trình duyệt)")
        }
        .help("Khi sao chép thanh địa chỉ từ Microsoft Edge (org.microsoft.titled-hyperlink), tự động lưu đường dẫn URL thuần thay vì tiêu đề liên kết HTML.")
        .fixedSize()

        Text(String(
          format: NSLocalizedString("Modifiers", tableName: "GeneralSettings", comment: ""),
          copyModifier, pasteModifier, pasteWithoutFormatting
        ))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.gray)
        .controlSize(.small)
      }

      Settings.Section(title: "") {
        if let notificationsURL = notificationsURL {
          Link(destination: notificationsURL, label: {
            Text("NotificationsAndSounds", tableName: "GeneralSettings")
          })
        }
      }
    }
  }

  private func refreshModifiers(_ sender: Sendable) {
    copyModifier = HistoryItemAction.copy.modifierFlags.description
    pasteModifier = HistoryItemAction.paste.modifierFlags.description
    pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description
  }
}
