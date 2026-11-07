import AppKit
import Foundation

nonisolated enum SnippetTemplateEngine {
  private static let vietnameseLocale = Locale(identifier: "vi_VN")
  private static let optionalSectionRegex = try? NSRegularExpression(
    pattern: "\\{\\{optional:([^\\}]+)\\}\\}([\\s\\S]*?)\\{\\{/optional\\}\\}"
  )
  private static let inlineControlRegex = try? NSRegularExpression(
    pattern: "\\{\\{(input|textarea|select):([^\\}]+)\\}\\}"
  )
  private static let legacyFillPartRegex = try? NSRegularExpression(
    pattern: "%fillpart:(?:name=)?([^:%]+)(?::default=([^%]+))?%([\\s\\S]*?)%fillpartend%",
    options: [.caseInsensitive]
  )
  private static let legacyFillTextRegex = try? NSRegularExpression(
    pattern: "%fill(text|area):(?:name=)?([^:%]+)(?::default=([^:%]*))?(?::width=[0-9]+)?%",
    options: [.caseInsensitive]
  )
  private static let legacyFillPopupRegex = try? NSRegularExpression(
    pattern: "%fillpopup:(?:name=)?([^:%]+):([^%]+)%",
    options: [.caseInsensitive]
  )
  private static let randomMacroRegex = try? NSRegularExpression(
    pattern: "\\{\\{random:([0-9]+)-([0-9]+)\\}\\}"
  )
  private static let dateMacroRegex = try? NSRegularExpression(
    pattern: "\\{\\{?(date|time|datetime|isodate|compactdate)(?:\\s*([+-]\\d+\\s*(?:bd|BD|d|D|w|W|M|m|y|Y|h|H)))?(?::([^\\}]+))?\\}?\\}"
  )
  private static let directDateFormatRegex = try? NSRegularExpression(
    pattern: "\\{\\{([yYmMdDHhsS][yYmMdDHhsS\\-/_.: ]{3,30})\\}\\}"
  )
  private static let inlineScriptRegex = try? NSRegularExpression(
    pattern: "\\{\\{(shell|applescript|jxa):([\\s\\S]*?)\\}\\}"
  )
  private static let keystrokeTokenRegex = try? NSRegularExpression(
    pattern: "\\{\\{(tab|enter|return|esc|escape|up|down|left|right|delay:\\d+)\\}\\}",
    options: [.caseInsensitive]
  )

  /// Extracts interactive Fill-in fields (both `{{input:...}}` and TextExpander `%fill...%` syntax).
  static func extractFillInFields(from item: SnippetItem) -> [SnippetFillInField] {
    guard item.contentMode == .plainText || item.contentMode == .richText || item.contentMode == .html else {
      return []
    }
    let normalized = normalizeLegacyFillIns(in: item.content)
    var fields: [SnippetFillInField] = []
    var seenKeys = Set<String>()

    // 1. Optional sections: {{optional:Label}}...{{/optional}} or {{optional:Label=1}}...{{/optional}}
    if let optRegex = optionalSectionRegex {
      let nsRange = NSRange(normalized.startIndex..., in: normalized)
      for match in optRegex.matches(in: normalized, range: nsRange) {
        guard match.numberOfRanges >= 3,
              let headerRange = Range(match.range(at: 1), in: normalized),
              let bodyRange = Range(match.range(at: 2), in: normalized) else { continue }
        let rawHeader = String(normalized[headerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyTemplate = String(normalized[bodyRange])
        let (label, defaultFlag) = splitLabelAndDefault(rawHeader)
        let key = "opt:\(label)"
        guard !seenKeys.contains(key) else { continue }
        seenKeys.insert(key)
        let defaultOn = ["1", "true", "yes", "on"].contains(defaultFlag.lowercased())
        fields.append(
          SnippetFillInField(
            key: key,
            label: label,
            kind: .optionalSection(defaultIncluded: defaultOn, bodyTemplate: bodyTemplate)
          )
        )
      }
    }

    // 2. Inline controls: {{input:...}}, {{textarea:...}}, {{select:Label|Opt1|Opt2}}
    if let inlineRegex = inlineControlRegex {
      let nsRange = NSRange(normalized.startIndex..., in: normalized)
      for match in inlineRegex.matches(in: normalized, range: nsRange) {
        guard match.numberOfRanges >= 3,
              let typeRange = Range(match.range(at: 1), in: normalized),
              let specRange = Range(match.range(at: 2), in: normalized) else { continue }
        let kindToken = String(normalized[typeRange]).lowercased()
        let spec = String(normalized[specRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        switch kindToken {
        case "input":
          let (label, defVal) = splitLabelAndDefault(spec)
          let key = "in:\(label)"
          guard !seenKeys.contains(key) else { continue }
          seenKeys.insert(key)
          fields.append(SnippetFillInField(key: key, label: label, kind: .singleLine(defaultValue: defVal)))

        case "textarea":
          let (label, defVal) = splitLabelAndDefault(spec)
          let key = "area:\(label)"
          guard !seenKeys.contains(key) else { continue }
          seenKeys.insert(key)
          fields.append(SnippetFillInField(key: key, label: label, kind: .multiLine(defaultValue: defVal)))

        case "select":
          let parts = spec.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
          guard let rawLabel = parts.first else { continue }
          let rawOptions = Array(parts.dropFirst())
          guard !rawOptions.isEmpty else { continue }
          var defaultIndex = 0
          var cleanOptions: [String] = []
          for (idx, opt) in rawOptions.enumerated() {
            if opt.hasPrefix("*") && opt.count > 1 {
              defaultIndex = idx
              cleanOptions.append(String(opt.dropFirst()))
            } else {
              cleanOptions.append(opt)
            }
          }
          let key = "sel:\(rawLabel)"
          guard !seenKeys.contains(key) else { continue }
          seenKeys.insert(key)
          fields.append(
            SnippetFillInField(
              key: key,
              label: rawLabel,
              kind: .dropdown(options: cleanOptions, defaultIndex: defaultIndex)
            )
          )

        default:
          break
        }
      }
    }

    return fields
  }

  /// Renders a snippet completely (applying Fill-in answers, Date/Time math, Clipboard, Scripts, Case, and Keystrokes)
  /// off the main thread where needed, returning ordered `ExpandedActionStep`s ready for execution.
  static func renderActionSteps(
    for item: SnippetItem,
    typedAbbreviation: String? = nil,
    trailingDelimiter: String? = nil,
    fillInValues: [String: String] = [:],
    optionalToggles: [String: Bool] = [:],
    clipboardString: String = "",
    referenceDate: Date = Date.now
  ) async -> [ExpandedActionStep] {
    if item.contentMode == .image, let pngData = item.imagePNGData, !pngData.isEmpty {
      return [.pasteImage(pngData)]
    }

    var text: String
    switch item.contentMode {
    case .shellScript:
      text = await runExternalProcess(
        executable: "/bin/zsh",
        arguments: ["-c", item.content],
        clipboardString: clipboardString
      )
    case .appleScript:
      text = await runExternalProcess(
        executable: "/usr/bin/osascript",
        arguments: ["-e", item.content],
        clipboardString: clipboardString
      )
    case .javaScript:
      text = await runExternalProcess(
        executable: "/usr/bin/osascript",
        arguments: ["-l", "JavaScript", "-e", item.content],
        clipboardString: clipboardString
      )
    case .plainText, .richText, .html, .image:
      text = normalizeLegacyFillIns(in: item.content)
      text = applyFillIns(to: text, values: fillInValues, optionalToggles: optionalToggles)
      text = await evaluateInlineScripts(in: text, clipboardString: clipboardString)
      text = evaluateMacros(in: text, clipboardString: clipboardString, now: referenceDate)
    }

    if item.caseMode == .propagateCase, let typed = typedAbbreviation, !typed.isEmpty {
      text = applyPropagatedCase(from: typed, to: text)
    }

    if let delim = trailingDelimiter, !delim.isEmpty {
      text += delim
    }

    return buildStepsFromRenderedText(text, item: item)
  }

  /// Fast synchronous preview renderer (skips spawning shell scripts) for live Fill-in dialog preview.
  static func renderLivePreview(
    for item: SnippetItem,
    fillInValues: [String: String],
    optionalToggles: [String: Bool],
    clipboardString: String
  ) -> String {
    var text = normalizeLegacyFillIns(in: item.content)
    text = applyFillIns(to: text, values: fillInValues, optionalToggles: optionalToggles)
    text = evaluateMacros(in: text, clipboardString: clipboardString, now: Date.now)
    return text
      .replacingOccurrences(of: "{{cursor}}", with: "▏")
      .replacingOccurrences(of: "{cursor}", with: "▏")
      .replacingOccurrences(of: "%|", with: "▏")
  }

  // MARK: - Fill-in Substitution

  private static func applyFillIns(
    to template: String,
    values: [String: String],
    optionalToggles: [String: Bool]
  ) -> String {
    guard template.contains("{{") else { return template }
    var output = template

    if let optRegex = optionalSectionRegex {
      let matches = optRegex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed()
      for match in matches {
        guard match.numberOfRanges >= 3,
              let fullRange = Range(match.range(at: 0), in: output),
              let headerRange = Range(match.range(at: 1), in: output),
              let bodyRange = Range(match.range(at: 2), in: output) else { continue }
        let rawHeader = String(output[headerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let (label, defaultFlag) = splitLabelAndDefault(rawHeader)
        let key = "opt:\(label)"
        let defaultOn = ["1", "true", "yes", "on"].contains(defaultFlag.lowercased())
        let isIncluded = optionalToggles[key] ?? defaultOn
        let replacement = isIncluded ? String(output[bodyRange]) : ""
        output.replaceSubrange(fullRange, with: replacement)
      }
    }

    if let inlineRegex = inlineControlRegex {
      let matches = inlineRegex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed()
      for match in matches {
        guard match.numberOfRanges >= 3,
              let fullRange = Range(match.range(at: 0), in: output),
              let typeRange = Range(match.range(at: 1), in: output),
              let specRange = Range(match.range(at: 2), in: output) else { continue }
        let kindToken = String(output[typeRange]).lowercased()
        let spec = String(output[specRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        let replacement: String
        switch kindToken {
        case "input":
          let (label, defVal) = splitLabelAndDefault(spec)
          replacement = values["in:\(label)"] ?? defVal
        case "textarea":
          let (label, defVal) = splitLabelAndDefault(spec)
          replacement = values["area:\(label)"] ?? defVal
        case "select":
          let parts = spec.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
          let label = parts.first ?? ""
          let options = parts.dropFirst().map { $0.hasPrefix("*") && $0.count > 1 ? String($0.dropFirst()) : $0 }
          replacement = values["sel:\(label)"] ?? options.first ?? ""
        default:
          replacement = ""
        }
        output.replaceSubrange(fullRange, with: replacement)
      }
    }

    return output
  }

  /// Converts TextExpander `%filltext...%`, `%fillpopup...%`, `%fillarea...%`, `%fillpart...%` into `{{...}}`.
  static func normalizeLegacyFillIns(in input: String) -> String {
    guard input.contains("%fill") else { return input }
    var result = input

    // %fillpart:name=Label:default=yes%...%fillpartend%
    if let regex = legacyFillPartRegex {
      let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
      for match in matches {
        guard let fullRange = Range(match.range(at: 0), in: result),
              let nameRange = Range(match.range(at: 1), in: result),
              let bodyRange = Range(match.range(at: 3), in: result) else { continue }
        let name = String(result[nameRange])
        let def = match.range(at: 2).location != NSNotFound
          ? String(result[Range(match.range(at: 2), in: result)!])
          : "0"
        let body = String(result[bodyRange])
        result.replaceSubrange(fullRange, with: "{{optional:\(name)=\(def)}}\(body){{/optional}}")
      }
    }

    // %filltext:name=Label:default=Val%
    if let regex = legacyFillTextRegex {
      let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
      for match in matches {
        guard let fullRange = Range(match.range(at: 0), in: result),
              let kindRange = Range(match.range(at: 1), in: result),
              let nameRange = Range(match.range(at: 2), in: result) else { continue }
        let kind = String(result[kindRange]).lowercased() == "area" ? "textarea" : "input"
        let name = String(result[nameRange])
        let def = match.range(at: 3).location != NSNotFound
          ? String(result[Range(match.range(at: 3), in: result)!])
          : ""
        result.replaceSubrange(fullRange, with: "{{\(kind):\(name)=\(def)}}")
      }
    }

    // %fillpopup:name=Label:Opt1:default=Opt2:Opt3%
    if let regex = legacyFillPopupRegex {
      let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
      for match in matches {
        guard let fullRange = Range(match.range(at: 0), in: result),
              let nameRange = Range(match.range(at: 1), in: result),
              let optsRange = Range(match.range(at: 2), in: result) else { continue }
        let name = String(result[nameRange])
        let rawParts = String(result[optsRange]).split(separator: ":").map(String.init)
        var formattedOpts: [String] = []
        for part in rawParts {
          if part.lowercased().hasPrefix("default=") {
            formattedOpts.append("*" + String(part.dropFirst("default=".count)))
          } else {
            formattedOpts.append(part)
          }
        }
        result.replaceSubrange(fullRange, with: "{{select:\(name)|\(formattedOpts.joined(separator: "|"))}}")
      }
    }

    return result
  }

  // MARK: - Dynamic Date/Time, Business-Day Math, Clipboard & UUID Macros

  static func evaluateMacros(in input: String, clipboardString: String, now: Date = Date.now) -> String {
    guard input.contains("{") || input.contains("%") else { return input }
    var result = input

    // Clipboard & UUID
    if result.contains("clipboard") {
      result = result
        .replacingOccurrences(of: "{{clipboard}}", with: clipboardString)
        .replacingOccurrences(of: "{clipboard}", with: clipboardString)
        .replacingOccurrences(of: "%clipboard", with: clipboardString)
    }

    while let range = result.range(of: "{{uuid}}") ?? result.range(of: "{uuid}") {
      result.replaceSubrange(range, with: UUID().uuidString)
    }

    // Random integer: {{random:1000-9999}}
    if result.contains("{{random:"), let randRegex = randomMacroRegex {
      let matches = randRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
      for match in matches {
        guard let fullRange = Range(match.range(at: 0), in: result),
              let minR = Range(match.range(at: 1), in: result),
              let maxR = Range(match.range(at: 2), in: result),
              let low = Int(result[minR]),
              let high = Int(result[maxR]),
              low <= high else { continue }
        result.replaceSubrange(fullRange, with: String(Int.random(in: low...high)))
      }
    }

    // Double-brace & Alfred single-brace date/time macros:
    // Examples:
    //   {{date}}, {{time}}, {{datetime}}, {{isodate}}, {{compactdate}}
    //   {{date:yyyyMMdd}}, {{date:yyyyMMDD}}, {{date +5bd:dd/MM/yyyy}}, {date:yyyyMMdd}
    if result.contains("{") && (result.contains("date") || result.contains("time")),
       let regex = dateMacroRegex {
      let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
      if !matches.isEmpty {
        let formatter = DateFormatter()
        formatter.locale = vietnameseLocale
        for match in matches {
          guard let fullRange = Range(match.range(at: 0), in: result),
                let kindRange = Range(match.range(at: 1), in: result) else { continue }
          let token = String(result[fullRange])
          // Ensure balanced braces (either `{...}` or `{{...}}`)
          let startsDouble = token.hasPrefix("{{")
          let endsDouble = token.hasSuffix("}}")
          guard startsDouble == endsDouble else { continue }

          let kind = String(result[kindRange]).lowercased()
          let offsetSpec: String? = match.range(at: 2).location != NSNotFound
            ? String(result[Range(match.range(at: 2), in: result)!])
            : nil
          let customFormat: String? = match.range(at: 3).location != NSNotFound
            ? String(result[Range(match.range(at: 3), in: result)!])
            : nil

          let targetDate = applyDateMath(to: now, spec: offsetSpec)
          let format: String
          if let customFormat, !customFormat.isEmpty {
            format = normalizeDateFormat(customFormat)
          } else {
            switch kind {
            case "time": format = "HH:mm"
            case "datetime": format = "dd/MM/yyyy HH:mm"
            case "isodate": format = "yyyy-MM-dd"
            case "compactdate": format = "yyyyMMdd"
            default: format = "dd/MM/yyyy"
            }
          }
          formatter.dateFormat = format
          result.replaceSubrange(fullRange, with: formatter.string(from: targetDate))
        }
      }
    }

    // Direct format shorthand inside double braces without `date:` prefix:
    // Examples: `{{yyyyMMdd}}`, `{{yyyyMMDD}}`, `{{YYYYMMDD}}`, `{{dd/MM/yyyy}}`, `{{yyyyMMdd_HHmm}}`
    if result.contains("{{"), let directRegex = directDateFormatRegex {
      let matches = directRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
      if !matches.isEmpty {
        let formatter = DateFormatter()
        formatter.locale = vietnameseLocale
        for match in matches {
          guard let fullRange = Range(match.range(at: 0), in: result),
                let fmtRange = Range(match.range(at: 1), in: result) else { continue }
          let rawFmt = String(result[fmtRange]).trimmingCharacters(in: .whitespaces)
          formatter.dateFormat = normalizeDateFormat(rawFmt)
          result.replaceSubrange(fullRange, with: formatter.string(from: now))
        }
      }
    }

    // Typinator standalone date/time tokens: `{YYYY}`, `{YY}`, `{MM}`, `{DD}`, `{hh}`, `{h024}`, `{mm}`, `{ss}`
    // Example: `{YYYY}{MM}{DD}` -> `20261103`
    if result.contains("{YYYY}") || result.contains("{YY}") || result.contains("{MM}")
        || result.contains("{DD}") || result.contains("{hh}") || result.contains("{h024}")
        || result.contains("{mm}") || result.contains("{ss}") {
      let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
      let year4 = String(format: "%04d", comps.year ?? 2026)
      let year2 = String(year4.suffix(2))
      let month2 = String(format: "%02d", comps.month ?? 1)
      let day2 = String(format: "%02d", comps.day ?? 1)
      let hour2 = String(format: "%02d", comps.hour ?? 0)
      let min2 = String(format: "%02d", comps.minute ?? 0)
      let sec2 = String(format: "%02d", comps.second ?? 0)
      result = result
        .replacingOccurrences(of: "{YYYY}", with: year4)
        .replacingOccurrences(of: "{YY}", with: year2)
        .replacingOccurrences(of: "{MM}", with: month2)
        .replacingOccurrences(of: "{DD}", with: day2)
        .replacingOccurrences(of: "{hh}", with: hour2)
        .replacingOccurrences(of: "{h024}", with: hour2)
        .replacingOccurrences(of: "{mm}", with: min2)
        .replacingOccurrences(of: "{ss}", with: sec2)
    }

    // Legacy TextExpander strftime-style tokens (%Y, %m, %d, %H, %M, %S)
    if result.contains("%Y") || result.contains("%m") || result.contains("%d") || result.contains("%H") {
      let cal = Calendar.current
      let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
      result = result
        .replacingOccurrences(of: "%Y", with: String(format: "%04d", comps.year ?? 2026))
        .replacingOccurrences(of: "%m", with: String(format: "%02d", comps.month ?? 1))
        .replacingOccurrences(of: "%d", with: String(format: "%02d", comps.day ?? 1))
        .replacingOccurrences(of: "%H", with: String(format: "%02d", comps.hour ?? 0))
        .replacingOccurrences(of: "%M", with: String(format: "%02d", comps.minute ?? 0))
        .replacingOccurrences(of: "%S", with: String(format: "%02d", comps.second ?? 0))
    }

    return result
  }

  /// Normalizes user-written date format patterns so common human conventions (`yyyyMMDD`, `YYYYMMDD`, `yyyymmdd`,
  /// `DD/MM/YYYY`) produce day-of-month (`dd`) and calendar year (`yyyy`) instead of ICU day-of-year (`DD` = 001..366)
  /// or ISO week-year (`YYYY`).
  static func normalizeDateFormat(_ rawFormat: String) -> String {
    guard !rawFormat.isEmpty else { return rawFormat }

    var hasTimeTokens = false
    var hasDateTokens = false
    var inQuotes = false
    for ch in rawFormat {
      if ch == "'" {
        inQuotes.toggle()
        continue
      }
      guard !inQuotes else { continue }
      if ch == "H" || ch == "h" || ch == "s" || ch == "S" || ch == "k" || ch == "K" {
        hasTimeTokens = true
      }
      if ch == "y" || ch == "Y" || ch == "d" || ch == "D" {
        hasDateTokens = true
      }
    }

    var out = ""
    out.reserveCapacity(rawFormat.count)
    inQuotes = false
    let convertLowerMToMonth = hasDateTokens && !hasTimeTokens

    for ch in rawFormat {
      if ch == "'" {
        inQuotes.toggle()
        out.append(ch)
        continue
      }
      if inQuotes {
        out.append(ch)
        continue
      }
      switch ch {
      case "Y":
        out.append("y")
      case "D":
        out.append("d")
      case "m" where convertLowerMToMonth:
        out.append("M")
      default:
        out.append(ch)
      }
    }
    return out
  }

  /// Supports calendar offsets (`+3d`, `-2w`, `+1M`, `+1y`, `+4h`) and Business Days (`+5bd`, `-3bd` skipping Sat/Sun).
  static func applyDateMath(to baseDate: Date, spec: String?) -> Date {
    guard let raw = spec?.replacingOccurrences(of: " ", with: ""), !raw.isEmpty else {
      return baseDate
    }

    let cal = Calendar.current
    if raw.lowercased().hasSuffix("bd"),
       let delta = Int(raw.dropLast(2)) {
      return addBusinessDays(delta, to: baseDate, calendar: cal)
    }

    guard let unitChar = raw.last, let value = Int(raw.dropLast()) else {
      return baseDate
    }

    switch unitChar {
    case "d", "D":
      return cal.date(byAdding: .day, value: value, to: baseDate) ?? baseDate
    case "w", "W":
      return cal.date(byAdding: .weekOfYear, value: value, to: baseDate) ?? baseDate
    case "M":
      return cal.date(byAdding: .month, value: value, to: baseDate) ?? baseDate
    case "y", "Y":
      return cal.date(byAdding: .year, value: value, to: baseDate) ?? baseDate
    case "h", "H":
      return cal.date(byAdding: .hour, value: value, to: baseDate) ?? baseDate
    case "m":
      return cal.date(byAdding: .minute, value: value, to: baseDate) ?? baseDate
    default:
      return baseDate
    }
  }

  static func addBusinessDays(_ businessDays: Int, to date: Date, calendar: Calendar = .current) -> Date {
    guard businessDays != 0 else { return date }
    let step = businessDays > 0 ? 1 : -1
    var remaining = abs(businessDays)
    var cursor = date

    while remaining > 0 {
      guard let next = calendar.date(byAdding: .day, value: step, to: cursor) else { break }
      cursor = next
      if !calendar.isDateInWeekend(cursor) {
        remaining -= 1
      }
    }
    return cursor
  }

  // MARK: - Inline & Whole-Snippet Scripts

  private static func evaluateInlineScripts(in input: String, clipboardString: String) async -> String {
    guard input.contains("{{shell:") || input.contains("{{applescript:") || input.contains("{{jxa:") else {
      return input
    }

    var current = input
    guard let regex = inlineScriptRegex else { return current }

    while let match = regex.firstMatch(in: current, range: NSRange(current.startIndex..., in: current)),
          match.numberOfRanges >= 3,
          let fullRange = Range(match.range(at: 0), in: current),
          let kindRange = Range(match.range(at: 1), in: current),
          let codeRange = Range(match.range(at: 2), in: current) {
      let kind = String(current[kindRange]).lowercased()
      let code = String(current[codeRange])
      let output: String
      switch kind {
      case "shell":
        output = await runExternalProcess(executable: "/bin/zsh", arguments: ["-c", code], clipboardString: clipboardString)
      case "applescript":
        output = await runExternalProcess(executable: "/usr/bin/osascript", arguments: ["-e", code], clipboardString: clipboardString)
      case "jxa":
        output = await runExternalProcess(
          executable: "/usr/bin/osascript",
          arguments: ["-l", "JavaScript", "-e", code],
          clipboardString: clipboardString
        )
      default:
        output = ""
      }
      current.replaceSubrange(fullRange, with: output)
    }

    return current
  }

  static func runExternalProcess(
    executable: String,
    arguments: [String],
    clipboardString: String,
    timeoutSeconds: TimeInterval = 5.0
  ) async -> String {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["MACCY_CLIPBOARD"] = clipboardString
        env["LANG"] = env["LANG"] ?? "vi_VN.UTF-8"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
          try process.run()
        } catch {
          continuation.resume(returning: "")
          return
        }

        final class TimeoutFlag: @unchecked Sendable {
          var didTimeout = false
        }
        let flag = TimeoutFlag()
        let timeoutWork = DispatchWorkItem {
          if process.isRunning {
            flag.didTimeout = true
            process.terminate()
          }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

        // Drain stderr concurrently so >64KB output never deadlocks pipe buffers
        DispatchQueue.global(qos: .utility).async {
          _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWork.cancel()

        if flag.didTimeout {
          continuation.resume(returning: "")
          return
        }

        let str = String(data: data, encoding: .utf8) ?? ""
        let cleaned = str
          .replacingOccurrences(of: "\r\n", with: "\n")
          .replacingOccurrences(of: "\\n$", with: "", options: .regularExpression)
        continuation.resume(returning: cleaned)
      }
    }
  }

  // MARK: - Case Propagation & Keystroke Token Splitting

  static func applyPropagatedCase(from typed: String, to expansion: String) -> String {
    let letters = typed.filter(\.isLetter)
    guard !letters.isEmpty else { return expansion }
    let locale = vietnameseLocale

    if letters.allSatisfy(\.isUppercase) && letters.count >= 2 {
      return expansion.uppercased(with: locale)
    }
    if let first = letters.first, first.isUppercase, letters.dropFirst().allSatisfy(\.isLowercase) {
      guard let firstExpIdx = expansion.firstIndex(where: \.isLetter) else { return expansion }
      var copy = expansion
      let upperFirst = String(copy[firstExpIdx]).uppercased(with: locale)
      copy.replaceSubrange(firstExpIdx...firstExpIdx, with: upperFirst)
      return copy
    }
    return expansion
  }

  private static func buildStepsFromRenderedText(_ text: String, item: SnippetItem) -> [ExpandedActionStep] {
    // Normalize cursor placeholders to `{{cursor}}` without double-wrapping existing `{{cursor}}`
    let normalized = text
      .replacingOccurrences(of: "{{cursor}}", with: "{cursor}")
      .replacingOccurrences(of: "{cursor}", with: "{{cursor}}")
      .replacingOccurrences(of: "%|", with: "{{cursor}}")

    // Fast path when there are no special keystrokes or cursor tokens
    if !normalized.contains("{{") {
      if item.contentMode == .html {
        let htmlBytes = normalized.data(using: .utf8)
        return [.pasteText(normalized, htmlData: htmlBytes, rtfData: nil)]
      } else if item.contentMode == .richText, item.rtfData != nil || item.htmlData != nil {
        return [.pasteText(normalized, htmlData: item.htmlData, rtfData: item.rtfData)]
      }
      return [.pasteText(normalized, htmlData: nil, rtfData: nil)]
    }

    // Split around keystroke/delay tokens: {{tab}}, {{enter}}, {{esc}}, {{up}}, {{down}}, {{left}}, {{right}}, {{delay:200}}
    guard let regex = keystrokeTokenRegex else {
      return appendSegmentWithCursor(normalized, item: item)
    }

    var steps: [ExpandedActionStep] = []
    var lastIndex = normalized.startIndex
    let matches = regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))

    for match in matches {
      guard let matchRange = Range(match.range(at: 0), in: normalized),
            let innerRange = Range(match.range(at: 1), in: normalized) else { continue }
      let preceding = String(normalized[lastIndex..<matchRange.lowerBound])
      if !preceding.isEmpty {
        steps.append(contentsOf: appendSegmentWithCursor(preceding, item: item))
      }

      let cmd = String(normalized[innerRange]).lowercased()
      if cmd.hasPrefix("delay:"), let ms = Int(cmd.dropFirst("delay:".count)) {
        steps.append(.delayMilliseconds(min(max(ms, 10), 5_000)))
      } else {
        switch cmd {
        case "tab": steps.append(.keyPress(.tab, count: 1))
        case "enter", "return": steps.append(.keyPress(.enter, count: 1))
        case "esc", "escape": steps.append(.keyPress(.escape, count: 1))
        case "up": steps.append(.keyPress(.upArrow, count: 1))
        case "down": steps.append(.keyPress(.downArrow, count: 1))
        case "left": steps.append(.keyPress(.leftArrow, count: 1))
        case "right": steps.append(.keyPress(.rightArrow, count: 1))
        default: break
        }
      }
      lastIndex = matchRange.upperBound
    }

    let tail = String(normalized[lastIndex..<normalized.endIndex])
    if !tail.isEmpty {
      steps.append(contentsOf: appendSegmentWithCursor(tail, item: item))
    }

    return steps
  }

  private static func appendSegmentWithCursor(_ segment: String, item: SnippetItem) -> [ExpandedActionStep] {
    let cleanSegment = segment.replacingOccurrences(of: "\r\n", with: "\n")
    if let cursorRange = cleanSegment.range(of: "{{cursor}}") {
      let before = String(cleanSegment[..<cursorRange.lowerBound])
      let after = String(cleanSegment[cursorRange.upperBound...])
        .replacingOccurrences(of: "{{cursor}}", with: "")
      let combined = before + after
      var result: [ExpandedActionStep] = []
      if !combined.isEmpty {
        if after.isEmpty {
          if item.contentMode == .html {
            result.append(.pasteText(combined, htmlData: combined.data(using: .utf8), rtfData: nil))
          } else {
            result.append(.pasteText(combined, htmlData: item.htmlData, rtfData: item.rtfData))
          }
        } else {
          result.append(.pasteText(combined, htmlData: nil, rtfData: nil))
        }
      }
      let moveLeftCount = after.count
      if moveLeftCount > 0 {
        result.append(.keyPress(.leftArrow, count: moveLeftCount))
      }
      return result
    }

    if item.contentMode == .html {
      return [.pasteText(cleanSegment, htmlData: cleanSegment.data(using: .utf8), rtfData: nil)]
    }
    return [.pasteText(cleanSegment, htmlData: item.htmlData, rtfData: item.rtfData)]
  }

  private static func splitLabelAndDefault(_ raw: String) -> (label: String, defaultValue: String) {
    if let eqIdx = raw.firstIndex(of: "=") {
      let label = String(raw[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
      let def = String(raw[raw.index(after: eqIdx)...])
      return (label.isEmpty ? "Giá trị" : label, def)
    }
    return (raw.isEmpty ? "Giá trị" : raw, "")
  }
}
