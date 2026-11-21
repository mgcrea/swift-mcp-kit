import Foundation
import Testing

/// What a translation must keep of its key, read off the catalog on disk.
///
/// The drift checks prove every key has a value in every language; these prove the values
/// are the kind that can ship. A hand-written catalog has no translator's tool to catch a
/// dropped `%@` or a localized file path, and either one is wrong only in a language the
/// author may not read.
@Suite("Translations keep what they must")
struct TranslationRulesTests {
  /// A value with fewer specifiers than its key drops an argument; one with more, or another
  /// kind, reads memory that was never passed. `xcstringstool` compiles both without a word.
  @Test("Every translation keeps its key's specifiers", arguments: CatalogScanner.Module.all)
  func specifiersAgree(module: CatalogScanner.Module) throws {
    var offenders: [String] = []
    for (key, values) in try CatalogScanner.translations(for: module) {
      let expected = Self.specifiers(in: key)
      for (language, value) in values where Self.specifiers(in: value) != expected {
        offenders.append("\(language): \(key)  →  \(value)")
      }
    }
    #expect(
      offenders.isEmpty,
      """
      \(offenders.count) translation(s) disagree with their key's format specifiers:
      \(offenders.sorted().map { "  • \($0)" }.joined(separator: "\n"))
      """
    )
  }

  /// Names, paths and addresses the person types or finds elsewhere in English: a client's
  /// name, a file another app reads, the loopback address, VS Code's own command. "Terminal"
  /// is not here, because it is translated where Apple translates it (Terminale in Italian).
  static let untranslatable = [
    "127.0.0.1", "~/.codex/config.toml", "~/.cursor/mcp.json", "mcp.json",
    "MCP: Open User Configuration", "Bastion", "MCP", "Claude Code", "Codex", "Cursor", "VS Code",
  ]

  @Test("Names and paths are never translated", arguments: CatalogScanner.Module.all)
  func namesStayAsTheyAre(module: CatalogScanner.Module) throws {
    var offenders: [String] = []
    for (key, values) in try CatalogScanner.translations(for: module) {
      for term in Self.untranslatable where key.contains(term) {
        for (language, value) in values where !value.contains(term) {
          offenders.append("\(language) drops \"\(term)\": \(value)")
        }
      }
    }
    #expect(
      offenders.isEmpty,
      """
      \(offenders.count) translation(s) lost a name or a path from their key:
      \(offenders.sorted().map { "  • \($0)" }.joined(separator: "\n"))
      """
    )
  }

  /// The house style across the apps on this kit: no em dash in any language; French puts a
  /// non-breaking space before `: ; ? !`, so the mark never starts a line on its own; German
  /// puts a space before the ellipsis of a button or menu item, as Apple's German does.
  @Test("Typography", arguments: CatalogScanner.Module.all)
  func typography(module: CatalogScanner.Module) throws {
    var offenders: [String] = []
    for (key, values) in try CatalogScanner.translations(for: module) {
      for (language, value) in values where value.contains("—") {
        offenders.append("\(language) has an em dash: \(value)")
      }
      if let french = values["fr"] {
        // An address and VS Code's command keep their colon as they are.
        var prose = french.replacingOccurrences(of: "127.0.0.1:%@", with: "")
        for term in Self.untranslatable { prose = prose.replacingOccurrences(of: term, with: "") }
        let marks = Array(prose)
        for (index, mark) in marks.enumerated() where ":;?!".contains(mark) {
          if index == 0 || !"\u{00A0}\u{202F}".contains(marks[index - 1]) {
            offenders.append("fr wants a non-breaking space before \"\(mark)\": \(french)")
          }
        }
      }
      if key.hasSuffix("…"), let german = values["de"], !german.hasSuffix(" …") {
        offenders.append("de wants a space before the ellipsis: \(german)")
      }
    }
    #expect(
      offenders.isEmpty,
      """
      \(offenders.count) translation(s) break the typography:
      \(offenders.sorted().map { "  • \($0)" }.joined(separator: "\n"))
      """
    )
  }

  /// The specifiers in a string, in order, `%%` left out.
  private static func specifiers(in string: String) -> [String] {
    let pattern = #"%(\d+\$)?[-+ 0#]*[0-9]*(\.[0-9]+)?(hh|h|ll|l|q|z|t|j)?[@dioufFeEgGxXsScp]"#
    let unescaped = string.replacingOccurrences(of: "%%", with: "")
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: unescaped, range: NSRange(unescaped.startIndex..., in: unescaped))
      .compactMap { Range($0.range, in: unescaped).map { String(unescaped[$0]) } }
  }
}
