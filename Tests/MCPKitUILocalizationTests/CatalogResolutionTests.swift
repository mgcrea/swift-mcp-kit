import Foundation
import Testing

/// Compiles the catalog and reads the result. See `CompiledCatalog` for why the lookup does
/// not go through `Bundle.module`.
@Suite("String catalogs compile and resolve", .enabled(if: CompiledCatalog.isAvailable))
struct CatalogResolutionTests {
  /// A malformed catalog, or a value whose format specifiers disagree with its key's, fails
  /// here rather than in the next app build that links it.
  @Test("Catalogs compile", arguments: CatalogScanner.Module.all)
  func catalogCompiles(module: CatalogScanner.Module) throws {
    try CompiledCatalog.compile(module)
  }

  /// Spot-checks in the languages that are *not* the source. If the catalog were wired
  /// wrongly these would be absent from the compiled tables, and a French app would fall back
  /// to the English key. The words are Cadence's, the first app the popover sits in.
  @Test(
    "Translations resolve",
    arguments: [
      ("fr", "Run the MCP server", "Activer le serveur MCP"),
      ("de", "Run the MCP server", "MCP-Server ausführen"),
      ("it", "Allow writes", "Consenti modifiche"),
      ("es", "Settings…", "Ajustes…"),
      ("de", "Settings…", "Einstellungen …"),
      ("fr", "Token", "Jeton"),
    ])
  func translationsResolve(language: String, key: String, expected: String) throws {
    let table = try CompiledCatalog.table(for: .ui, language: language)
    #expect(table[key] == expected)
  }

  /// The arguments are a port, a client's name, a date and the app's name, and each language
  /// puts them where its sentence wants them. The specifier has to survive compilation for
  /// that to work at all, and filling it is what the app does at runtime.
  @Test("Interpolated keys keep their specifier, in French and German")
  func interpolationSurvivesCompilation() throws {
    let french = try CompiledCatalog.table(for: .ui, language: "fr")
    let german = try CompiledCatalog.table(for: .ui, language: "de")

    // A port, as a string: no grouping separator in any language.
    let listening = "Listening on 127.0.0.1:%@"
    #expect(french[listening] == "À l’écoute sur 127.0.0.1:%@")
    #expect(german[listening] == "Erreichbar unter 127.0.0.1:%@")
    let port = String(8791)
    #expect(french[listening].map { String(format: $0, port) } == "À l’écoute sur 127.0.0.1:8791")
    #expect(german[listening].map { String(format: $0, port) } == "Erreichbar unter 127.0.0.1:8791")

    let copy = "Copy the configuration for %@, with its token"
    #expect(
      french[copy].map { String(format: $0, "Claude Code") }
        == "Copier la configuration pour Claude Code, avec son jeton")
    #expect(
      german[copy].map { String(format: $0, "Claude Code") }
        == "Konfiguration für Claude Code samt Token kopieren")

    // The app's name, with nothing glued to it: "dans Almanac", never "de Almanac".
    let reads =
      "Lets an AI agent on this Mac read %@'s data. It listens on 127.0.0.1 only: nothing is "
      + "reachable from another machine, and nothing leaves this one."
    let frenchReads = try #require(french[reads])
    let germanReads = try #require(german[reads])
    #expect(String(format: frenchReads, "Almanac").contains("vos données dans Almanac."))
    #expect(String(format: germanReads, "Almanac").contains("deine Daten in Almanac zu lesen."))
  }

  /// English is the source language, so it needs no authored entries, but the compiled `en`
  /// table still has to exist, because it is what an app in none of the shipped languages
  /// falls back to.
  @Test("Every shipped language compiles", arguments: CatalogScanner.Module.all)
  func everyLanguageCompiles(module: CatalogScanner.Module) throws {
    let languages = try CompiledCatalog.compiledLanguages(for: module)
    #expect(languages.contains("en"), "\(module.name) compiled no English table")
    for language in CatalogScanner.shippedLanguages {
      #expect(languages.contains(language), "\(module.name) compiled no \(language) table")
    }
  }
}
