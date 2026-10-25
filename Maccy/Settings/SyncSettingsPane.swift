import AppKit
import Defaults
import KeyboardShortcuts
import Settings
import SwiftUI

struct SyncSettingsPane: View {
  @Default(.cloudSyncEnabled) private var cloudSyncEnabled
  @Default(.cloudSyncFolderPath) private var cloudSyncFolderPath
  @Default(.autoSyncPinnedItems) private var autoSyncPinnedItems
  @Default(.cloudSyncEncryptionEnabled) private var cloudSyncEncryptionEnabled
  @Default(.cloudSyncPassphrase) private var cloudSyncPassphrase
  @Default(.warnBeforeSyncingSecrets) private var warnBeforeSyncingSecrets

  @State private var cloudSync = CloudSyncManager.shared

  var body: some View {
    Settings.Container(contentWidth: 460) {
      Settings.Section(
        bottomDivider: true,
        label: { Text("Đồng bộ:") }
      ) {
        Defaults.Toggle(key: .cloudSyncEnabled) {
          Text("Bật đồng bộ qua Google Drive")
        }

        Defaults.Toggle(key: .autoSyncPinnedItems) {
          Text("Tự động đồng bộ tất cả các mục đã Ghim (Pinned)")
        }
        .disabled(!cloudSyncEnabled)

        Text("Các mục được đánh dấu đồng bộ (hoặc đã ghim) sẽ tự động đồng bộ hai chiều giữa các máy Mac thông qua thư mục Google Drive.")
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(.gray)
          .controlSize(.small)
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Thư mục Drive:") }
      ) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            Image(systemName: cloudSyncFolderPath.isEmpty ? "folder.badge.questionmark" : "externaldrive.fill.badge.icloud")
              .foregroundStyle(cloudSyncFolderPath.isEmpty ? .orange : .blue)
            Text(cloudSyncFolderPath.isEmpty ? "Chưa chọn thư mục Google Drive" : cloudSyncFolderPath)
              .font(.system(size: 11, design: .monospaced))
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          .padding(6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(Color.secondary.opacity(0.1))
          )

          HStack(spacing: 8) {
            Button("Chọn thư mục…") {
              cloudSync.chooseSyncFolderWithPanel()
            }

            Button("Tự động tìm Drive") {
              if cloudSync.autoDetectGoogleDriveIfNeeded(forceUpdate: true) == nil {
                cloudSync.chooseSyncFolderWithPanel()
              } else {
                Task { await cloudSync.syncNow() }
              }
            }

            if !cloudSyncFolderPath.isEmpty {
              Button("Mở trong Finder") {
                cloudSync.openSyncFolderInFinder()
              }
            }
          }
          .controlSize(.small)
        }
        .disabled(!cloudSyncEnabled)
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Bảo mật:") }
      ) {
        VStack(alignment: .leading, spacing: 6) {
          Defaults.Toggle(key: .cloudSyncEncryptionEnabled) {
            Text("Mã hoá đầu-cuối (AES-256 GCM) trên Google Drive")
          }
          .disabled(!cloudSyncEnabled)

          if cloudSyncEncryptionEnabled {
            HStack(spacing: 8) {
              SecureField("Nhập mật khẩu mã hoá dùng chung giữa các máy Mac…", text: $cloudSyncPassphrase)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

              if !cloudSyncPassphrase.isEmpty {
                Image(systemName: "lock.shield.fill")
                  .foregroundStyle(.green)
                  .help("Đã kích hoạt mã hoá AES-256 GCM")
              }
            }
          }

          Defaults.Toggle(key: .warnBeforeSyncingSecrets) {
            Text("Cảnh báo khi đồng bộ API Key / Private Key chưa mã hoá")
          }
          .disabled(!cloudSyncEnabled)

          Text("Dữ liệu lớn được tự động nén LZFSE và tách file riêng trong thư mục blobs/ để tránh xung đột khi nhiều máy cùng đồng bộ.")
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.gray)
            .controlSize(.small)
        }
      }

      Settings.Section(
        bottomDivider: true,
        label: { Text("Phím tắt:") }
      ) {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            KeyboardShortcuts.Recorder(for: .sync)
            Text("Đánh dấu / Bỏ đánh dấu đồng bộ (Mặc định: ⌥S)")
              .controlSize(.small)
              .foregroundStyle(.gray)
          }
          Text("Mẹo: Giữ ⌘ + Click hoặc ⇧ + ↑/↓ để chọn nhiều mục cùng lúc rồi nhấn ⌥S để đồng bộ hàng loạt. Nhấn ⌥⌘S để lọc chỉ xem các mục đã đồng bộ.")
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.gray)
            .controlSize(.small)
        }
      }

      Settings.Section(
        label: { Text("Trạng thái:") }
      ) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 12) {
            Label("\(cloudSync.syncedCount) mục đang đồng bộ", systemImage: "icloud.fill")
              .foregroundStyle(.blue)

            if let lastSync = cloudSync.lastSyncDate {
              Text("Cập nhật: \(lastSync.formatted(date: .abbreviated, time: .standard))")
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
          }

          if let error = cloudSync.lastSyncError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .controlSize(.small)
          }

          HStack(spacing: 10) {
            Button {
              Task {
                await cloudSync.syncNow()
              }
            } label: {
              HStack(spacing: 5) {
                if cloudSync.isSyncing {
                  ProgressView()
                    .controlSize(.small)
                } else {
                  Image(systemName: "arrow.triangle.2.circlepath.icloud")
                }
                Text("Đồng bộ ngay")
              }
            }
            .disabled(!cloudSyncEnabled || cloudSync.isSyncing)
          }
        }
      }
    }
  }
}
