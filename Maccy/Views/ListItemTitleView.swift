import SwiftUI

struct ListItemTitleView<Title: View>: View {
  var attributedTitle: AttributedString?
  var matchedSnippet: AttributedString? = nil
  var isSelected: Bool = false
  @ViewBuilder var title: () -> Title

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let attributedTitle {
        Text(attributedTitle)
          .accessibilityIdentifier("copy-history-item")
          .lineLimit(1)
          .truncationMode(.middle)
      } else {
        title()
          .accessibilityIdentifier("copy-history-item")
          .lineLimit(1)
          .truncationMode(.middle)
          // Workaround for macOS 26 to avoid flipped text
          // https://github.com/p0deje/Maccy/issues/1113
          .drawingGroup()
      }

      if let matchedSnippet {
        HStack(spacing: 4) {
          Image(systemName: "text.magnifyingglass")
            .font(.system(size: 9, weight: .medium))
          Text(matchedSnippet)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .foregroundStyle(isSelected ? Color.white.opacity(0.88) : Color.secondary)
      }
    }
    .padding(.vertical, matchedSnippet != nil ? 3 : 0)
  }
}
