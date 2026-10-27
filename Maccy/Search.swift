import AppKit
import Defaults
import Fuse

class Search {
  enum Mode: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
    case exact
    case fuzzy
    case regexp
    case mixed

    var id: Self { self }

    var description: String {
      switch self {
      case .exact:
        return NSLocalizedString("Exact", tableName: "GeneralSettings", comment: "")
      case .fuzzy:
        return NSLocalizedString("Fuzzy", tableName: "GeneralSettings", comment: "")
      case .regexp:
        return NSLocalizedString("Regex", tableName: "GeneralSettings", comment: "")
      case .mixed:
        return NSLocalizedString("Mixed", tableName: "GeneralSettings", comment: "")
      }
    }
  }

  struct SearchResult: Equatable {
    var score: Double?
    var object: Searchable
    var ranges: [Range<String.Index>] = []
    var matchedInBody: Bool = false
  }

  typealias Searchable = HistoryItemDecorator

  private let fuse = Fuse(threshold: 0.7) // threshold found by trial-and-error
  private let fuzzySearchLimit = 5_000

  func search(string: String, within: [Searchable]) -> [SearchResult] {
    guard !string.isEmpty else {
      return within.map { SearchResult(object: $0) }
    }

    switch Defaults[.searchMode] {
    case .mixed:
      return mixedSearch(string: string, within: within)
    case .regexp:
      return simpleSearch(string: string, within: within, options: .regularExpression)
    case .fuzzy:
      return fuzzySearch(string: string, within: within)
    default:
      return simpleSearch(string: string, within: within, options: .caseInsensitive)
    }
  }

  private func fuzzySearch(string: String, within: [Searchable]) -> [SearchResult] {
    let pattern = fuse.createPattern(from: string)
    let foldedQuery = string.foldingVietnameseDiacritics
    let foldedPattern = foldedQuery != string ? fuse.createPattern(from: foldedQuery) : pattern
    let searchResults: [SearchResult] = within.compactMap { item in
      fuzzySearch(
        for: pattern,
        foldedPattern: foldedPattern,
        rawQuery: string,
        in: item.title,
        foldedSearchString: item.foldedTitle,
        of: item
      )
    }
    let sortedResults = searchResults.sorted(by: { ($0.score ?? 0) < ($1.score ?? 0) })
    return sortedResults
  }

  private func fuzzySearch(
    for pattern: Fuse.Pattern?,
    foldedPattern: Fuse.Pattern?,
    rawQuery: String,
    in searchString: String,
    foldedSearchString: String,
    of item: Searchable
  ) -> SearchResult? {
    var searchString = searchString
    if searchString.count > fuzzySearchLimit {
      // shortcut to avoid slow search
      let stopIndex = searchString.index(searchString.startIndex, offsetBy: fuzzySearchLimit)
      searchString = "\(searchString[...stopIndex])"
    }

    var foldedTarget = foldedSearchString
    if foldedTarget.count > fuzzySearchLimit {
      let stopIndex = foldedTarget.index(foldedTarget.startIndex, offsetBy: fuzzySearchLimit)
      foldedTarget = "\(foldedTarget[...stopIndex])"
    }

    let directMatch = fuse.search(pattern, in: searchString)
    let foldedMatch = directMatch ?? fuse.search(foldedPattern ?? pattern, in: foldedTarget)

    if let fuzzyResult = foldedMatch {
      let maxChars = searchString.count
      return SearchResult(
        score: fuzzyResult.score,
        object: item,
        ranges: fuzzyResult.ranges.compactMap {
          guard maxChars > 0 else { return nil }
          let startOffset = Swift.max(0, Swift.min($0.lowerBound, maxChars))
          let endOffset = Swift.max(startOffset, Swift.min($0.upperBound + 1, maxChars))
          let startIndex = searchString.startIndex
          let lowerBound = searchString.index(startIndex, offsetBy: startOffset)
          let upperBound = searchString.index(startIndex, offsetBy: endOffset)

          return lowerBound..<upperBound
        }
      )
    }

    // Deep 64 KB body fallback for long items in Fuzzy mode (ranked below title matches)
    if item.item.totalByteCount > searchString.utf8.count,
       bodyMatches(query: rawQuery, in: item, options: .caseInsensitive) {
      return SearchResult(score: 0.68, object: item, ranges: [], matchedInBody: true)
    }

    return nil
  }

  private func simpleSearch(
    string: String,
    within: [Searchable],
    options: NSString.CompareOptions
  ) -> [SearchResult] {
    return within.compactMap { simpleSearch(for: string, in: $0.title, of: $0, options: options) }
  }

  private func simpleSearch(
    for string: String,
    in searchString: String,
    of item: Searchable,
    options: NSString.CompareOptions
  ) -> SearchResult? {
    if let range = searchString.rangeByVietnameseSearch(
      of: string,
      options: options,
      precomputedFoldedSelf: item.foldedTitle
    ) {
      return SearchResult(object: item, ranges: [range])
    }

    // Multi-word non-contiguous token search in title (e.g. "implant khoa 41" -> "Cấy ghép Implant ... Khóa 41")
    if !options.contains(.regularExpression),
       let tokenRanges = searchString.multiWordRangesByVietnameseSearch(
         of: string,
         precomputedFoldedSelf: item.foldedTitle
       ) {
      return SearchResult(object: item, ranges: tokenRanges)
    }

    // Deep full-text search fallback for large items (> title length, up to 64 KB) without blocking UI
    if item.item.totalByteCount > searchString.utf8.count,
       bodyMatches(query: string, in: item, options: options) {
      return SearchResult(object: item, ranges: [], matchedInBody: true)
    }

    return nil
  }

  private func bodyMatches(
    query: String,
    in item: Searchable,
    options: NSString.CompareOptions
  ) -> Bool {
    let foldedQuery = query.foldingVietnameseDiacritics
    guard !foldedQuery.isEmpty else { return false }

    let body = item.foldedSearchableBodyText
    guard !body.isEmpty else { return false }

    if body.range(of: foldedQuery, options: options) != nil {
      return true
    }

    if !options.contains(.regularExpression) {
      let tokens = foldedQuery.split(whereSeparator: \.isWhitespace)
      if tokens.count >= 2 {
        return tokens.allSatisfy { token in
          body.range(of: String(token), options: .caseInsensitive) != nil
        }
      }
    }

    return false
  }

  private func mixedSearch(string: String, within: [Searchable]) -> [SearchResult] {
    var results = simpleSearch(string: string, within: within, options: .caseInsensitive)
    guard results.isEmpty else {
      return results
    }

    results = simpleSearch(string: string, within: within, options: .regularExpression)
    guard results.isEmpty else {
      return results
    }

    results = fuzzySearch(string: string, within: within)
    guard results.isEmpty else {
      return results
    }

    return []
  }
}
