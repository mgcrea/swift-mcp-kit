import Foundation

/// Looks a string up in **this module's** catalog.
///
/// `String(localized:)` defaults to `Bundle.main`, and so does a literal handed to `Text`,
/// `Label` or `.help`: inside a package that is the host app's bundle, which has none of these
/// keys, so the lookup falls back to the key and draws English in a French app, with no build
/// error and no crash. Naming `.module` is the whole reason this function exists.
///
/// It returns `String` rather than a `LocalizedStringKey`, so one spelling serves every call
/// site (`Text`, `Label`, `Button`, `Toggle`, `Picker`, `TextField`, `Link`, `.help`), each of
/// which draws a `StringProtocol` verbatim. The key is the English text, so the source still
/// reads as what an English user sees.
///
/// The cost is that Xcode's extractor sees this function's parameter rather than the call
/// site's literal, so nothing fills the catalog on build. Entries are written by hand and
/// marked `manual`, and `MCPKitUILocalizationTests` does the extractor's job instead: a call
/// site with no entry, an entry with no call site, a language left incomplete and a literal
/// handed straight to SwiftUI each fail it. The arrangement is swift-support-kit's.
///
/// `@usableFromInline` because `MCPToolbarButton`'s `unavailableSettingsTitle` defaults to
/// this module's "Settings…", and a public default argument may only name what the caller's
/// module can see. The body is still compiled here, so `.module` is still this package's
/// bundle.
@usableFromInline
func localized(_ key: String.LocalizationValue) -> String {
  String(localized: key, bundle: .module)
}

/// The status line's address. One function for the panel and `MCPStatusLabel`, which say the
/// same thing.
///
/// `String(port)` rather than the `Int`: an interpolated integer is formatted for the locale,
/// and 8791 would read "8 791" in French and "8.791" in German, which is no longer a port
/// anybody can type. As a string it is `%@` in the key and stays as it is in every language.
func listeningLine(port: Int) -> String {
  let port = String(port)
  return localized("Listening on 127.0.0.1:\(port)")
}
