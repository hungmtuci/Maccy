import AppKit
import KeyboardShortcuts
import SwiftUI

struct PreviewItemView: View {
  private static let largeTextThreshold = 1_000

  @Environment(AppState.self) private var appState
  var item: HistoryItemDecorator

  private func highlightedSmallPreview(text: String, query: String) -> AttributedString {
    var attr = AttributedString(text)
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !text.isEmpty else { return attr }

    let matches = text.allRangesByVietnameseSearch(of: trimmed, maxMatches: 40)
    for range in matches {
      if let lower = AttributedString.Index(range.lowerBound, within: attr),
         let upper = AttributedString.Index(range.upperBound, within: attr) {
        attr[lower..<upper].backgroundColor = .findHighlightColor
        attr[lower..<upper].foregroundColor = .black
      }
    }
    return attr
  }

  @ViewBuilder
  func previewImage(content: () -> some View) -> some View {
    content()
      .aspectRatio(contentMode: .fit)
      .clipShape(.rect(cornerRadius: 5))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if item.hasImage {
        AsyncView<NSImage?, _, _>(id: item.id) {
          return await item.asyncGetPreviewImage()
        } content: { image in
          if let image = image {
            previewImage {
              Image(nsImage: image)
                .resizable()
            }
          } else {
            previewImage {
              ZStack {
                Color.gray.opacity(0.3)
                  .frame(
                    idealWidth: HistoryItemDecorator.previewImageSize.width,
                    idealHeight: HistoryItemDecorator.previewImageSize.height
                  )
                Image(systemName: "photo.badge.exclamationmark")
                  .symbolRenderingMode(.multicolor)
                  .frame(alignment: .center)
              }
            }
          }
        } placeholder: {
          previewImage {
            ZStack {
              Color.gray.opacity(0.3)
                .frame(
                  idealWidth: HistoryItemDecorator.previewImageSize.width,
                  idealHeight: HistoryItemDecorator.previewImageSize.height
                )
              ProgressView()
                .frame(alignment: .center)
            }
          }
        }
      } else {
        if item.previewText.byteCount >= Self.largeTextThreshold {
          LargeTextView(
            text: item.previewText.string,
            highlightQuery: appState.history.searchQuery
          )
            .id("textpreview-\(item.id)")
        } else {
          ScrollView {
            if appState.history.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Text(item.previewText.string)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              Text(highlightedSmallPreview(text: item.previewText.string, query: appState.history.searchQuery))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .frame(maxWidth: .infinity)
        }

        if item.previewText.isTruncated {
          HStack(spacing: 4) {
            Image(systemName: "bolt.shield.fill")
              .foregroundStyle(.orange)
            Text("Nội dung lớn (\(item.formattedDataSize)) — Hiển thị 32 KB đầu để chống treo. Khi Paste vẫn giữ 100% dữ liệu gốc.")
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
      }

      Spacer(minLength: 0)

      Divider()
        .padding(.bottom, 8)

      if let application = item.application {
        HStack(spacing: 3) {
          Text("Application", tableName: "PreviewItemView")
          AppImageView(
            appImage: item.applicationImage,
            size: NSSize(width: 11, height: 11)
          )
          Text(application)
        }
      }

      if item.hasImage, let image = item.item.image {
        HStack(spacing: 3) {
          Text("Dimensions", tableName: "PreviewItemView")
          Text("\(Int(image.pixelSize.width))×\(Int(image.pixelSize.height))")
        }
      }

      HStack(spacing: 3) {
        Text("Size", tableName: "PreviewItemView")
        Text(item.imageSize ?? item.formattedDataSize)
      }

      HStack(spacing: 5) {
        Text("Google Drive:")
        Button {
          CloudSyncManager.shared.toggleSync(for: [item])
        } label: {
          HStack(spacing: 3) {
            Image(systemName: item.isSynced ? "icloud.fill" : "icloud.and.arrow.up")
            Text(item.isSynced ? "Đã đồng bộ (Bấm để huỷ)" : "Chưa đồng bộ (Bấm ⌥S để đồng bộ)")
          }
          .foregroundStyle(item.isSynced ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
      }

      if item.isSynced, let device = item.syncSourceDevice {
        HStack(spacing: 3) {
          Text("Thiết bị đồng bộ:")
          Image(systemName: "laptopcomputer")
          Text(device)
          if let syncDate = item.syncUpdatedAt {
            Text("•")
            Text(syncDate, style: .time)
          }
        }
        .foregroundStyle(.secondary)
      }

      HStack(spacing: 3) {
        Text("FirstCopyTime", tableName: "PreviewItemView")
        Text(item.item.firstCopiedAt, style: .date)
        Text(item.item.firstCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("LastCopyTime", tableName: "PreviewItemView")
        Text(item.item.lastCopiedAt, style: .date)
        Text(item.item.lastCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("NumberOfCopies", tableName: "PreviewItemView")
        Text(String(item.item.numberOfCopies))
      }
    }
    .controlSize(.small)
  }
}
