import Foundation

extension Data {
  /// Decodes at most `maxBytes` from the start of `Data` as UTF-8, stepping back
  /// over any trailing incomplete multi-byte UTF-8 sequence so it never fails on valid UTF-8.
  nonisolated func utf8PrefixString(maxBytes: Int) -> String? {
    guard !isEmpty, maxBytes > 0 else { return "" }
    if count <= maxBytes {
      return String(data: self, encoding: .utf8)
    }

    let slice = prefix(maxBytes)
    // Try decoding directly or trim up to 3 trailing bytes if a multi-byte scalar was cut in half.
    for trim in 0...3 {
      let len = slice.count - trim
      guard len > 0 else { break }
      if let str = String(data: slice.prefix(len), encoding: .utf8) {
        return str
      }
    }

    return String(decoding: slice, as: UTF8.self)
  }

  /// Fast check whether UTF-8 text data is empty or whitespace-only without allocating a huge String.
  nonisolated var isEffectivelyEmptyUTF8: Bool {
    guard !isEmpty else { return true }
    let checkLimit = Swift.min(count, 4_096)
    for idx in 0..<checkLimit {
      let byte = self[startIndex.advanced(by: idx)]
      // Fast path for ASCII non-whitespace characters
      if byte > 0x20 && byte < 0x7F {
        return false
      }
    }
    if let prefixStr = utf8PrefixString(maxBytes: checkLimit) {
      if !prefixStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return false
      }
    }
    return count <= checkLimit
  }
}

extension String {
  nonisolated func shortened(to maxLength: Int) -> String {
    guard maxLength > 0 else { return "" }
    guard let end = index(startIndex, offsetBy: maxLength, limitedBy: endIndex), end != endIndex else {
      return self
    }

    return String(self[startIndex..<end])
  }

  /// Normalizes Vietnamese text to unaccented lowercase ASCII-friendly form (including đ/Đ -> d)
  /// so searching "dong bo du lieu" matches "Đồng bộ dữ liệu".
  nonisolated var foldingVietnameseDiacritics: String {
    guard !isEmpty else { return "" }
    return self
      .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "vi_VN"))
      .replacingOccurrences(of: "đ", with: "d")
      .replacingOccurrences(of: "Đ", with: "d")
  }

  /// Strips Vietnamese diacritics while preserving uppercase/lowercase letters (e.g. "Nguyễn Văn Đạt" -> "Nguyen Van Dat").
  nonisolated var removingVietnameseDiacriticsPreservingCase: String {
    guard !isEmpty else { return "" }
    return self
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "vi_VN"))
      .replacingOccurrences(of: "đ", with: "d")
      .replacingOccurrences(of: "Đ", with: "D")
  }

  /// Finds `query` in `self`, supporting both exact match and Vietnamese unaccented (tiếng Việt không dấu) match,
  /// returning a valid `Range<String.Index>` on `self` for UI highlighting.
  nonisolated func rangeByVietnameseSearch(
    of query: String,
    options: NSString.CompareOptions,
    precomputedFoldedSelf: String? = nil
  ) -> Range<String.Index>? {
    guard !query.isEmpty, !isEmpty else { return nil }

    // 1. Direct match with original options
    if let directRange = self.range(of: query, options: options) {
      return directRange
    }

    // 2. Diacritic-insensitive match directly on original String (preserves exact String.Index)
    if !options.contains(.regularExpression) {
      let diacriticOptions = options.union([.diacriticInsensitive, .caseInsensitive])
      if let diacriticRange = self.range(of: query, options: diacriticOptions) {
        return diacriticRange
      }
    }

    // 3. Full Vietnamese folding match (handles đ/Đ <-> d and regex on unaccented text)
    let foldedSelf = precomputedFoldedSelf ?? self.foldingVietnameseDiacritics
    let foldedQuery = query.foldingVietnameseDiacritics

    guard let foldedRange = foldedSelf.range(of: foldedQuery, options: options) else {
      return nil
    }

    return mapFoldedRangeToOriginal(foldedRange, in: foldedSelf)
  }

  /// Matches multi-word queries where words are separated by spaces (e.g. "implant khoa 41" matching
  /// "Cấy ghép Implant nha khoa cơ bản - Khóa 41"), returning merged highlight ranges when ALL tokens match.
  nonisolated func multiWordRangesByVietnameseSearch(
    of query: String,
    precomputedFoldedSelf: String? = nil
  ) -> [Range<String.Index>]? {
    let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard tokens.count >= 2, !isEmpty else { return nil }

    let foldedSelf = precomputedFoldedSelf ?? self.foldingVietnameseDiacritics
    var collected: [Range<String.Index>] = []
    collected.reserveCapacity(tokens.count)

    for token in tokens {
      guard let range = self.rangeByVietnameseSearch(
        of: token,
        options: .caseInsensitive,
        precomputedFoldedSelf: foldedSelf
      ) else {
        return nil
      }
      collected.append(range)
    }

    return Self.mergeOverlappingRanges(collected)
  }

  /// Finds up to `maxMatches` occurrences of `query` (or its whitespace-separated tokens) in `self`
  /// using Vietnamese unaccented matching, suitable for highlighting matches in snippets and preview panes.
  nonisolated func allRangesByVietnameseSearch(
    of query: String,
    precomputedFoldedSelf: String? = nil,
    maxMatches: Int = 60
  ) -> [Range<String.Index>] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isEmpty, maxMatches > 0 else { return [] }

    let foldedSelf = precomputedFoldedSelf ?? self.foldingVietnameseDiacritics
    guard !foldedSelf.isEmpty else { return [] }

    let fullFolded = trimmed.foldingVietnameseDiacritics
    var searchTerms: [String] = []
    if !fullFolded.isEmpty, foldedSelf.contains(fullFolded) {
      searchTerms = [fullFolded]
    } else {
      let tokens = trimmed
        .split(whereSeparator: \.isWhitespace)
        .map { String($0).foldingVietnameseDiacritics }
        .filter { !$0.isEmpty }
      searchTerms = Array(Set(tokens))
    }

    guard !searchTerms.isEmpty else { return [] }

    var found: [Range<String.Index>] = []
    for term in searchTerms {
      var searchStart = foldedSelf.startIndex
      while searchStart < foldedSelf.endIndex, found.count < maxMatches {
        guard let foldedRange = foldedSelf.range(
          of: term,
          options: .caseInsensitive,
          range: searchStart..<foldedSelf.endIndex
        ) else {
          break
        }
        if foldedRange.isEmpty { break }
        if let mapped = mapFoldedRangeToOriginal(foldedRange, in: foldedSelf), !mapped.isEmpty {
          found.append(mapped)
        }
        searchStart = foldedRange.upperBound
      }
    }

    return Self.mergeOverlappingRanges(found)
  }

  private nonisolated func mapFoldedRangeToOriginal(
    _ foldedRange: Range<String.Index>,
    in foldedSelf: String
  ) -> Range<String.Index>? {
    let startOffset = foldedSelf.distance(from: foldedSelf.startIndex, to: foldedRange.lowerBound)
    let matchLength = foldedSelf.distance(from: foldedRange.lowerBound, to: foldedRange.upperBound)
    let selfCount = self.count
    guard selfCount > 0 else { return nil }

    let clampedStart = Swift.max(0, Swift.min(startOffset, selfCount))
    let clampedLength = Swift.max(0, Swift.min(matchLength, selfCount - clampedStart))
    let lower = self.index(self.startIndex, offsetBy: clampedStart)
    let upper = self.index(lower, offsetBy: clampedLength)
    return lower..<upper
  }

  nonisolated static func mergeOverlappingRanges(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
    guard ranges.count > 1 else { return ranges }
    let sorted = ranges.sorted {
      $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound
    }
    var merged: [Range<String.Index>] = []
    merged.reserveCapacity(sorted.count)
    for range in sorted {
      if let last = merged.last, range.lowerBound <= last.upperBound {
        let newUpper = Swift.max(last.upperBound, range.upperBound)
        merged[merged.count - 1] = last.lowerBound..<newUpper
      } else {
        merged.append(range)
      }
    }
    return merged
  }
}

extension String.UTF8View {
  nonisolated func shortened(maxParagraphBytes: Int, maxTotalBytes: Int = 32_768) -> SubSequence {
    let paragraphLimit = Swift.max(0, maxParagraphBytes)
    let totalLimit = Swift.max(0, maxTotalBytes)
    var cursor = startIndex
    var paragraphBytes = 0
    var totalBytes = 0

    while cursor != endIndex {
      if totalBytes >= totalLimit {
        var end = cursor
        while end != startIndex && (self[end] & 0xC0 == 0x80) {
          end = index(before: end)
        }
        return self[startIndex..<end]
      }

      if let lineBreakEnd = indexAfterLineBreak(at: cursor) {
        let dist = distance(from: cursor, to: lineBreakEnd)
        totalBytes += dist
        cursor = lineBreakEnd
        paragraphBytes = 0
      } else {
        if paragraphBytes >= paragraphLimit {
          var end = cursor
          // Avoid splitting a Unicode scalar by stepping back over continuation bytes.
          while end != startIndex && (self[end] & 0xC0 == 0x80) {
            end = index(before: end)
          }
          return self[startIndex..<end]
        }
        paragraphBytes += 1
        totalBytes += 1
        formIndex(after: &cursor)
      }
    }

    return self[startIndex..<endIndex]
  }

  private nonisolated func indexAfterLineBreak(at start: Index) -> Index? {
    let next = index(after: start)
    switch self[start] {
    case 0x0A, 0x0B, 0x0C: // LF, vertical tab, form feed
      return next
    case 0x0D: // CR, including CRLF as one line break
      return next != endIndex && self[next] == 0x0A ? index(after: next) : next
    case 0xC2: // U+0085 NEXT LINE
      guard next != endIndex, self[next] == 0x85 else { return nil }
      return index(after: next)
    case 0xE2: // U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR
      guard next != endIndex, self[next] == 0x80 else { return nil }
      let last = index(after: next)
      guard last != endIndex, self[last] == 0xA8 || self[last] == 0xA9 else { return nil }
      return index(after: last)
    default:
      return nil
    }
  }
}
