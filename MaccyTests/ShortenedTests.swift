import Testing
@testable import Maccy

@MainActor
struct ShortenedTests {
  @Test("Shortened returns at most max length")
  func shortenedReturnsAtMostMaxLength() {
    #expect("abcdef".shortened(to: 3) == "abc")
  }

  @Test("Shortened is a no-op within the limit", arguments: ["abc", ""])
  func shortenedNoOpWhenWithinLimit(input: String) {
    #expect(input.shortened(to: 3) == input)
  }

  @Test("Shortened with a large cap is a no-op")
  func shortenedLargeCapIsNoOp() {
    #expect("abcdefghij".shortened(to: 1_000) == "abcdefghij")
  }

  @Test("Shortened result never exceeds max length", arguments: 0...8)
  func shortenedResultNeverExceedsMaxLength(length: Int) {
    let input = "abcdef"
    let result = input.shortened(to: length)
    #expect(result.count <= length)
    #expect(result.count == min(length, input.count))
  }

  @Test("Vietnamese diacritic stripping preserves case")
  func vietnameseDiacriticsPreservingCase() {
    #expect("Nguyễn Văn Đạt - Đồng Bộ Dữ Liệu".removingVietnameseDiacriticsPreservingCase == "Nguyen Van Dat - Dong Bo Du Lieu")
  }

  @Test("Vietnamese multi-word unaccented token search")
  func vietnameseMultiWordSearch() {
    let text = "Cấy ghép Implant nha khoa cơ bản - Khóa 41"
    let ranges = text.multiWordRangesByVietnameseSearch(of: "implant khoa 41")
    #expect(ranges != nil)
    #expect((ranges?.count ?? 0) >= 2)
    #expect(text.multiWordRangesByVietnameseSearch(of: "implant khoa 99") == nil)
  }

  @Test("Microsoft Edge rich titled hyperlink extraction and tracking removal")
  func edgeRichLinkCleaning() throws {
    let rawTypes: Set<NSPasteboard.PasteboardType> = [.microsoftTitledHyperlink, .html, .string]
    let html = "<a href=\"https://github.com/hungmtuci/Maccy?utm_source=edge&amp;fbclid=12345&amp;tab=readme\">hungmtuci/Maccy: Lightweight clipboard manager</a>"
    let clean = Clipboard.extractCleanURLFromTitledHyperlink(
      rawTypes: rawTypes,
      stringData: "hungmtuci/Maccy: Lightweight clipboard manager".data(using: .utf8),
      urlData: nil,
      htmlData: html.data(using: .utf8),
      titledHyperlinkData: html.data(using: .utf8)
    )
    #expect(clean == "https://github.com/hungmtuci/Maccy?utm_source=edge&fbclid=12345&tab=readme")

    let url = try #require(URL(string: clean!))
    let stripped = Clipboard.stripTrackingParameters(from: url)
    #expect(stripped.absoluteString == "https://github.com/hungmtuci/Maccy?tab=readme")
  }

  @Test("Custom fork semantic version comparison")
  func customForkVersionComparison() {
    #expect(SoftwareUpdater.isRemoteVersionNewer("v2.8.0-custom", than: "2.7.0-custom") == true)
    #expect(SoftwareUpdater.isRemoteVersionNewer("v2.7.0-custom", than: "2.7.0-custom") == false)
    #expect(SoftwareUpdater.isRemoteVersionNewer("v2.6.0-custom", than: "2.7.0-custom") == false)
  }
}
