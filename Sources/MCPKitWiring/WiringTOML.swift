import Foundation

/// Reading and editing the `[mcp_servers]` blocks of a TOML client config — Codex's
/// `~/.codex/config.toml` — without disturbing a byte of the rest of it.
///
/// Ported from Bastion's `ClientWiringTOML`. Why not a TOML library: the JSON clients are
/// serialised from a dictionary, which is safe because their files hold nothing but data.
/// Codex's config is hand-written prose and structure — project trust tables, feature flags, a
/// multi-line string full of markdown — and a round trip through any serialiser would
/// reformat and de-comment a file this package does not own. So this never re-encodes the
/// file: it locates the lines that hold MCP servers, replaces those, and quotes every other
/// byte verbatim.
///
/// **The invariant: the scanner may fail to describe a server, but it must never fail to NAME
/// one.** A server it can see but not parse still appears in `servers`, so ownership reads
/// false and a collision refuses the write. Dropping it instead would let a configure append a
/// second `[mcp_servers.<name>]`, and a duplicate key makes the whole file fail to parse —
/// Codex loses every server and every project trust level at once. Hence two jobs:
///
/// - The **lexer** decides extents. It may throw, and a throw makes the client unreadable and
///   every write impossible, because every write begins with a read.
/// - The **value parser** is best effort and never throws. A value it cannot type is omitted
///   rather than guessed.
public enum WiringTOML {
  public static let rootKey = "mcp_servers"

  // MARK: - What a scan produces

  /// One server as the file holds it: what it says, and which lines say it.
  public struct Table {
    public let name: String
    /// Line indices, half-open. Plural because `[mcp_servers.a.env]` may sit somewhere other
    /// than directly under `[mcp_servers.a]`, and both belong to `a`.
    var ranges: [Range<Int>]
    /// Best effort. Empty is a legitimate answer — see the invariant above.
    public internal(set) var value: [String: Any]

    /// `enabled = false`, which Codex honours and no JSON client has.
    public var isDisabled: Bool { (value["enabled"] as? Bool) == false }
  }

  public struct Document {
    /// The file, verbatim. Every splice quotes out of this.
    public let text: String
    /// One range per line, INCLUDING its terminator — so an untouched CRLF line comes back
    /// with its CR, and a file with no final newline keeps not having one.
    let lines: [Range<String.Index>]
    /// What a rendered block ends its lines with.
    let newline: String
    public let tables: [String: Table]
    /// Where new blocks go: just past the last `mcp_servers` span in the ORIGINAL file,
    /// counting the ones about to be deleted. That is what makes a second configure
    /// byte-identical to the first.
    let anchor: Int

    /// The shape `WiringMerge` takes, so no rule there learns this file is TOML.
    public var servers: [String: Any] { tables.mapValues { $0.value } }

    public var disabled: Set<String> {
      Set(tables.values.filter { $0.isDisabled }.map { $0.name })
    }
  }

  /// For a config that does not exist yet. Computed, because a `Document` is not `Sendable`.
  public static var empty: Document {
    Document(text: "", lines: [], newline: "\n", tables: [:], anchor: 0)
  }

  public enum ScanError: LocalizedError, Equatable {
    case notUTF8(URL)
    /// Legal TOML this cannot splice safely. Named, because the remedy is a person looking.
    case unsupportedShape(line: Int, why: String)
    /// Not TOML, or not TOML in a way that leaves a span's end unknowable.
    case malformed(line: Int, why: String)

    public var errorDescription: String? {
      switch self {
      case .notUTF8(let url):
        return "\(url.lastPathComponent) is not UTF-8; leaving it alone"
      case .unsupportedShape(let line, let why):
        return "line \(line + 1) uses a shape that cannot be edited safely (\(why)). "
          + "Nothing was written."
      case .malformed(let line, let why):
        return "line \(line + 1) is not valid TOML (\(why)). Nothing was written."
      }
    }
  }

  // MARK: - Reading

  public static func read(_ url: URL) throws -> Document {
    let data = try Data(contentsOf: url)
    guard let text = String(data: data, encoding: .utf8) else { throw ScanError.notUTF8(url) }
    return try scan(text)
  }

  public static func scan(_ text: String) throws -> Document {
    let lines = lineRanges(text)
    var tables: [String: Table] = [:]

    // Which table the assignments on this line belong to.
    enum Context {
      /// Nothing we care about, or before the first header.
      case other
      /// A bare `[mcp_servers]`, under which every key IS a server.
      case parent
      /// `[mcp_servers.<name>]` and its subtables; `path` is what comes after the name.
      case server(name: String, path: [String])
    }
    var context = Context.other

    var openName: String?
    var openStart = 0
    // The last line that is neither blank nor comment-only. A span ends here rather than at
    // the next header, so the blank line and comment above the NEXT table stay with it.
    var lastContent = -1

    func closeSpan() {
      guard let name = openName else { return }
      let stop = max(openStart + 1, lastContent + 1)
      tables[name, default: Table(name: name, ranges: [], value: [:])]
        .ranges.append(openStart..<stop)
      openName = nil
    }

    var state = LexState()
    for (index, span) in lines.enumerated() {
      let line = text[span]
      let fresh = state.isClean
      try advance(&state, over: line, at: index)

      guard fresh else {
        // A continuation line of a multi-line value: content, but nothing to classify.
        lastContent = index
        continue
      }

      switch try classify(line, at: index) {
      case .blank, .comment:
        continue

      case .header(let parts, let arrayOfTables):
        closeSpan()
        lastContent = index
        guard parts.first == rootKey else {
          context = .other
          continue
        }
        if arrayOfTables {
          throw ScanError.unsupportedShape(
            line: index, why: "an array of tables under [\(rootKey)]")
        }
        if parts.count == 1 {
          context = .parent
        } else {
          let name = parts[1]
          context = .server(name: name, path: Array(parts.dropFirst(2)))
          openName = name
          openStart = index
          // Named even if nothing below it parses. That is the invariant.
          if tables[name] == nil { tables[name] = Table(name: name, ranges: [], value: [:]) }
        }

      case .assignment(let key, let value):
        lastContent = index
        switch context {
        case .other:
          continue
        case .parent:
          guard key.count == 1 else {
            throw ScanError.unsupportedShape(line: index, why: "a dotted key under [\(rootKey)]")
          }
          let name = key[0]
          var table = tables[name] ?? Table(name: name, ranges: [], value: [:])
          table.ranges.append(index..<(index + 1))
          if let value = value as? [String: Any] { table.value = value }
          tables[name] = table
        case .server(let name, let path):
          var table = tables[name] ?? Table(name: name, ranges: [], value: [:])
          if let value { set(&table.value, path: path + key, to: value) }
          tables[name] = table
        }
      }
    }
    closeSpan()

    if !state.isClean {
      throw ScanError.malformed(line: max(0, lines.count - 1), why: "a value that is never closed")
    }

    let anchor = tables.values.flatMap { $0.ranges }.map { $0.upperBound }.max() ?? lines.count
    return Document(
      text: text, lines: lines, newline: newline(of: text, lines: lines), tables: tables,
      anchor: anchor)
  }

  // MARK: - Writing

  /// One `[mcp_servers.<name>]` block.
  ///
  /// Only ever called on an entry this package built. A hand-written entry is never
  /// re-rendered — it is read, classified and quoted back verbatim — and that asymmetry is the
  /// safety argument: rendering may be opinionated about quoting and order because the only
  /// thing it sees is a shape the caller chose.
  static func render(name: String, entry: [String: Any], newline: String) -> String {
    var out = "[\(rootKey).\(key(name))]" + newline
    let preferred = ["url", "command", "args", "env", "http_headers"]
    let rest = entry.keys.filter { !preferred.contains($0) }.sorted()
    for name in preferred + rest {
      guard let value = entry[name], let literal = literal(value) else { continue }
      out += "\(key(name)) = \(literal)" + newline
    }
    return out
  }

  private static func key(_ name: String) -> String {
    let bare =
      !name.isEmpty
      && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    return bare ? name : quoted(name)
  }

  private static func quoted(_ value: String) -> String {
    var out = "\""
    for character in value {
      switch character {
      case "\\": out += "\\\\"
      case "\"": out += "\\\""
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
          scalar.value < 0x20
        {
          out += String(format: "\\u%04X", scalar.value)
        } else {
          out.append(character)
        }
      }
    }
    return out + "\""
  }

  private static func literal(_ value: Any) -> String? {
    switch value {
    case let string as String: return quoted(string)
    case let bool as Bool: return bool ? "true" : "false"
    case let int as Int: return String(int)
    case let table as [String: Any]:
      let pairs = table.keys.sorted().compactMap { name -> String? in
        guard let value = table[name], let literal = literal(value) else { return nil }
        return "\(key(name)) = \(literal)"
      }
      return pairs.isEmpty ? "{}" : "{ " + pairs.joined(separator: ", ") + " }"
    case let array as [Any]:
      let elements = array.compactMap { literal($0) }
      guard elements.count == array.count else { return nil }
      return "[" + elements.joined(separator: ", ") + "]"
    default:
      return nil
    }
  }

  /// Delete the lines holding `removing` and `upserting`, emit `upserting` at the anchor, and
  /// quote every other byte verbatim.
  ///
  /// A deleted block also takes the blank line above it, and a written block puts one back.
  /// That pair is what makes configure → unwire return the original bytes, and what stops ten
  /// rounds of either from growing a column of blank lines.
  public static func spliced(
    _ document: Document, removing: Set<String>, upserting: [String: [String: Any]]
  ) -> String {
    let doomed = removing.union(upserting.keys)
    var deleted = Set<Int>()
    for name in doomed {
      for range in document.tables[name]?.ranges ?? [] { deleted.formUnion(range) }
    }
    for name in doomed {
      for range in document.tables[name]?.ranges ?? [] {
        let above = range.lowerBound - 1
        guard above >= 0, !deleted.contains(above), isBlank(document, above) else { continue }
        deleted.insert(above)
      }
    }

    let blocks = upserting.keys.sorted().map {
      render(name: $0, entry: upserting[$0] ?? [:], newline: document.newline)
    }

    var out = ""
    var written = false
    func writeBlocks() {
      guard !written else { return }
      written = true
      for block in blocks {
        if !out.isEmpty {
          // Close an unterminated last line, then add the blank line this block owns —
          // unconditionally, so the blank a configure adds is the blank an unwire takes back.
          if let last = out.last, !breaks.contains(last) { out += document.newline }
          out += document.newline
        }
        out += block
      }
    }

    for index in document.lines.indices {
      if index == document.anchor { writeBlocks() }
      if deleted.contains(index) { continue }
      out += document.text[document.lines[index]]
    }
    if document.anchor >= document.lines.count { writeBlocks() }
    return out
  }

  private static func isBlank(_ document: Document, _ index: Int) -> Bool {
    document.text[document.lines[index]].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - Lines

  /// What ends a line. Both, named once, because `"\r\n"` is ONE `Character` in Swift: compare
  /// against `"\n"` alone and a CRLF file reads as a single line with no servers in it.
  private static let breaks: Set<Character> = ["\n", "\r\n"]

  static func lineRanges(_ text: String) -> [Range<String.Index>] {
    var out: [Range<String.Index>] = []
    var start = text.startIndex
    var i = text.startIndex
    while i < text.endIndex {
      let isBreak = breaks.contains(text[i])
      i = text.index(after: i)
      if isBreak {
        out.append(start..<i)
        start = i
      }
    }
    if start < text.endIndex { out.append(start..<text.endIndex) }
    return out
  }

  private static func newline(of text: String, lines: [Range<String.Index>]) -> String {
    for line in lines {
      guard let last = text[line].last, breaks.contains(last) else { continue }
      return String(last)
    }
    return "\n"
  }

  // MARK: - The lexer

  private struct LexState {
    /// `"` or `'` while inside a `"""` / `'''` block.
    var multiline: Character?
    /// Unclosed `[` or `{` in a value spanning lines.
    var depth = 0

    var isClean: Bool { multiline == nil && depth == 0 }
  }

  /// Walk one line for extents only. Not optional: Codex configs keep `"""` blocks of markdown
  /// — headings starting with `#`, brackets — beside `[mcp_servers]` tables, and a scanner that
  /// did not know it was inside a string would mint servers out of prose and then delete the
  /// lines it invented.
  private static func advance(_ state: inout LexState, over line: Substring, at index: Int) throws {
    let c = Array(line)
    var i = 0
    while i < c.count {
      if let delim = state.multiline {
        if c[i] == delim, i + 2 < c.count, c[i + 1] == delim, c[i + 2] == delim {
          state.multiline = nil
          i += 3
          continue
        }
        // Only a basic string has escapes; a literal one is bytes.
        if delim == "\"", c[i] == "\\", i + 1 < c.count {
          i += 2
          continue
        }
        i += 1
        continue
      }

      switch c[i] {
      case "#":
        return
      case "\"", "'":
        let quote = c[i]
        if i + 2 < c.count, c[i + 1] == quote, c[i + 2] == quote {
          state.multiline = quote
          i += 3
          continue
        }
        var j = i + 1
        var closed = false
        while j < c.count {
          if quote == "\"", c[j] == "\\" {
            j += 2
            continue
          }
          if c[j] == quote {
            j += 1
            closed = true
            break
          }
          j += 1
        }
        guard closed else { throw ScanError.malformed(line: index, why: "an unterminated string") }
        i = j
      case "[", "{":
        state.depth += 1
        i += 1
      case "]", "}":
        state.depth = max(0, state.depth - 1)
        i += 1
      default:
        i += 1
      }
    }
  }

  // MARK: - Classifying a line

  private enum Line {
    case blank
    case comment
    case header(parts: [String], arrayOfTables: Bool)
    case assignment(key: [String], value: Any?)
  }

  private static func classify(_ line: Substring, at index: Int) throws -> Line {
    var cursor = Cursor(Array(line))
    // A byte-order mark is not TOML, but editors write one; it is quoted back verbatim.
    if cursor.peek == "\u{FEFF}" { cursor.advance() }
    cursor.skipSpace()
    guard let first = cursor.peek else { return .blank }
    if breaks.contains(first) || first == "\r" { return .blank }
    if first == "#" { return .comment }

    if first == "[" {
      cursor.advance()
      var arrayOfTables = false
      if cursor.peek == "[" {
        arrayOfTables = true
        cursor.advance()
      }
      guard let parts = cursor.keyPath() else {
        throw ScanError.malformed(line: index, why: "a table header with no key")
      }
      cursor.skipSpace()
      guard cursor.peek == "]" else {
        throw ScanError.malformed(line: index, why: "an unclosed table header")
      }
      cursor.advance()
      if arrayOfTables {
        guard cursor.peek == "]" else {
          throw ScanError.malformed(line: index, why: "an unclosed table header")
        }
        cursor.advance()
      }
      guard cursor.atLineTail else {
        throw ScanError.malformed(line: index, why: "trailing text after a table header")
      }
      return .header(parts: parts, arrayOfTables: arrayOfTables)
    }

    guard let key = cursor.keyPath() else {
      throw ScanError.malformed(line: index, why: "neither a table header nor an assignment")
    }
    cursor.skipSpace()
    guard cursor.peek == "=" else {
      throw ScanError.malformed(line: index, why: "a key with no value")
    }
    cursor.advance()
    cursor.skipSpace()
    // Best effort from here down: an unparseable value is omitted, never guessed.
    let value = cursor.value()
    return .assignment(key: key, value: cursor.atLineTail ? value : nil)
  }

  // MARK: - Values

  /// Nested assignment, for a dotted key or a subtable.
  private static func set(_ dict: inout [String: Any], path: [String], to value: Any) {
    guard let head = path.first else { return }
    if path.count == 1 {
      dict[head] = value
      return
    }
    var child = dict[head] as? [String: Any] ?? [:]
    set(&child, path: Array(path.dropFirst()), to: value)
    dict[head] = child
  }

  /// A hand-rolled reader over one line's characters. Everything it returns is optional rather
  /// than thrown, because a value it cannot type is not an error.
  private struct Cursor {
    private let c: [Character]
    private var i = 0

    init(_ characters: [Character]) { c = characters }

    var peek: Character? { i < c.count ? c[i] : nil }
    mutating func advance() { i += 1 }
    mutating func skipSpace() {
      while let ch = peek, ch == " " || ch == "\t" { advance() }
    }

    /// Whether nothing but whitespace, a comment and the line break remain.
    var atLineTail: Bool {
      var j = i
      while j < c.count, c[j] == " " || c[j] == "\t" { j += 1 }
      guard j < c.count else { return true }
      return c[j] == "#" || WiringTOML.breaks.contains(c[j]) || c[j] == "\r"
    }

    private static func isBare(_ ch: Character) -> Bool {
      ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-")
    }

    mutating func key() -> String? {
      guard let ch = peek else { return nil }
      if ch == "\"" || ch == "'" { return string() }
      var out = ""
      while let d = peek, Cursor.isBare(d) {
        out.append(d)
        advance()
      }
      return out.isEmpty ? nil : out
    }

    /// A dotted key path. `[projects."/Users/me/…"]` is what makes this more than a split.
    mutating func keyPath() -> [String]? {
      var parts: [String] = []
      while true {
        skipSpace()
        guard let part = key() else { return nil }
        parts.append(part)
        skipSpace()
        guard peek == "." else { return parts }
        advance()
      }
    }

    /// A single-line quoted string. `nil` for a `"""` opener, whose extents the lexer owns.
    mutating func string() -> String? {
      guard let quote = peek, quote == "\"" || quote == "'" else { return nil }
      if i + 2 < c.count, c[i + 1] == quote, c[i + 2] == quote { return nil }
      advance()
      var out = ""
      while let ch = peek {
        if ch == quote {
          advance()
          return out
        }
        if quote == "\"", ch == "\\" {
          advance()
          guard let escape = peek else { return nil }
          advance()
          switch escape {
          case "n": out.append("\n")
          case "t": out.append("\t")
          case "r": out.append("\r")
          case "b": out.append("\u{08}")
          case "f": out.append("\u{0C}")
          case "\"": out.append("\"")
          case "\\": out.append("\\")
          case "u", "U":
            let width = escape == "u" ? 4 : 8
            var hex = ""
            for _ in 0..<width {
              guard let d = peek, d.isHexDigit else { return nil }
              hex.append(d)
              advance()
            }
            guard let scalar = UInt32(hex, radix: 16), let unicode = Unicode.Scalar(scalar)
            else { return nil }
            out.append(Character(unicode))
          default:
            return nil
          }
          continue
        }
        if WiringTOML.breaks.contains(ch) { return nil }
        out.append(ch)
        advance()
      }
      return nil
    }

    mutating func value() -> Any? {
      guard let ch = peek else { return nil }
      switch ch {
      case "\"", "'": return string()
      case "[": return array()
      case "{": return inlineTable()
      case "t", "f": return literal()
      default: return number()
      }
    }

    private mutating func array() -> [Any]? {
      advance()
      var out: [Any] = []
      while true {
        skipSpace()
        if peek == "]" {
          advance()
          return out
        }
        guard let element = value() else { return nil }
        out.append(element)
        skipSpace()
        if peek == "," {
          advance()
          continue
        }
        if peek == "]" {
          advance()
          return out
        }
        // End of line inside the brackets: a multi-line array, untypeable here.
        return nil
      }
    }

    private mutating func inlineTable() -> [String: Any]? {
      advance()
      var out: [String: Any] = [:]
      skipSpace()
      if peek == "}" {
        advance()
        return out
      }
      while true {
        skipSpace()
        guard let path = keyPath() else { return nil }
        skipSpace()
        guard peek == "=" else { return nil }
        advance()
        skipSpace()
        guard let element = value() else { return nil }
        WiringTOML.set(&out, path: path, to: element)
        skipSpace()
        if peek == "," {
          advance()
          continue
        }
        if peek == "}" {
          advance()
          return out
        }
        return nil
      }
    }

    private mutating func literal() -> Bool? {
      var word = ""
      while let ch = peek, ch.isLetter {
        word.append(ch)
        advance()
      }
      switch word {
      case "true": return true
      case "false": return false
      default: return nil
      }
    }

    /// Plain integers only. A float or a datetime comes back nil and its key is omitted — none
    /// of them can be a `command` or a `url`.
    private mutating func number() -> Int? {
      var word = ""
      if let ch = peek, ch == "-" || ch == "+" {
        word.append(ch)
        advance()
      }
      while let ch = peek, ch.isASCII, ch.isNumber {
        word.append(ch)
        advance()
      }
      return Int(word)
    }
  }
}
