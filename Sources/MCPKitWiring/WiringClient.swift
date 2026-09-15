import Foundation

#if canImport(AppKit)
  import AppKit
#endif

/// An MCP client installed on this Mac, and the file it keeps its servers in.
///
/// The catalog below is the clients that can reach a loopback URL with a bearer header, which
/// is the only thing a server built on `MCPKitLoopback` can offer. Three are left out on
/// purpose:
///
/// - **Claude Desktop** runs every local server as a `command`; it has no URL entry at all.
///   Reaching it takes a stdio bridge inside the app, which is Bastion's answer and not this
///   package's.
/// - **Windsurf** spells a remote server `serverUrl`, and its header shape is unverified.
/// - **LM Studio** holds bare `url` entries with no header anywhere in its file, so an entry
///   carrying a token is unverified there. A client that quietly ignores an entry is worse
///   than one that is not listed.
public struct WiringClient: Identifiable, Hashable, Sendable {

  /// What the file is written in.
  public enum Format: Hashable, Sendable {
    /// Strict JSON, servers under `rootKey` — `mcpServers` for most, `servers` for VS Code.
    case json(rootKey: String)
    /// `WiringTOML`: spliced in place, never re-encoded.
    case toml
  }

  public let id: String
  public let displayName: String
  public let configURL: URL
  public let format: Format
  /// Asked of LaunchServices first, which finds an app wherever it lives.
  public let bundleID: String?
  /// Paths whose presence says the client is installed — the only evidence a CLI has.
  public let evidence: [URL]
  /// An SF Symbol for a client with no app icon to draw.
  public let symbol: String
  /// A caveat worth showing beside the client.
  public let note: String?

  public init(
    id: String, displayName: String, configURL: URL, format: Format, bundleID: String? = nil,
    evidence: [URL] = [], symbol: String, note: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.configURL = configURL
    self.format = format
    self.bundleID = bundleID
    self.evidence = evidence
    self.symbol = symbol
    self.note = note
  }

  public var rootKey: String {
    switch format {
    case .json(let rootKey): return rootKey
    case .toml: return WiringTOML.rootKey
    }
  }

  /// Deliberately not `which`: an app launched by Finder inherits `PATH=/usr/bin:/bin` and
  /// would miss every Homebrew and npm-global install there is.
  public var isInstalled: Bool {
    #if canImport(AppKit)
      if let bundleID,
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
      {
        return true
      }
    #endif
    let fm = FileManager.default
    if evidence.contains(where: { fm.fileExists(atPath: $0.path) }) { return true }
    // A config file is evidence too: nothing but the client writes one.
    return fm.fileExists(atPath: configURL.path)
  }
}

// MARK: - The catalog

extension WiringClient {

  /// Claude Code's user-scope servers — the top-level `mcpServers` every session reads.
  ///
  /// The file is a parameter because it moves: `~/.claude.json` for the default config folder,
  /// but `<folder>/.claude.json`, *inside* the folder, for one named by `CLAUDE_CONFIG_DIR`. An
  /// app that knows about several accounts makes one client per folder.
  public static func claudeCode(
    configURL: URL, evidence: [URL] = [], id: String = "claude-code",
    displayName: String = "Claude Code"
  ) -> WiringClient {
    WiringClient(
      id: id, displayName: displayName, configURL: configURL,
      format: .json(rootKey: "mcpServers"), evidence: evidence, symbol: "terminal")
  }

  /// One client, not three: the ChatGPT app, the Codex CLI and the IDE extension read this one
  /// file, so separate rows would write the same key twice and a removal from any would take
  /// out the others.
  public static func codex(home: URL) -> WiringClient {
    WiringClient(
      id: "codex", displayName: "ChatGPT & Codex",
      configURL: home.appending(path: ".codex/config.toml"), format: .toml,
      // The ChatGPT app took the CLI's name.
      bundleID: "com.openai.codex",
      evidence: [
        home.appending(path: ".codex"),
        URL(filePath: "/Applications/ChatGPT.app"),
        URL(filePath: "/opt/homebrew/bin/codex"),
        URL(filePath: "/usr/local/bin/codex"),
      ],
      symbol: "terminal",
      note: "The ChatGPT app, the Codex CLI and the IDE extension all read this file.")
  }

  public static func cursor(home: URL) -> WiringClient {
    WiringClient(
      id: "cursor", displayName: "Cursor",
      configURL: home.appending(path: ".cursor/mcp.json"),
      format: .json(rootKey: "mcpServers"),
      // Cursor ships under its Electron packager's id.
      bundleID: "com.todesktop.230313mzl4w4u92",
      evidence: [URL(filePath: "/Applications/Cursor.app")],
      symbol: "cursorarrow")
  }

  /// `User/mcp.json`, never `User/settings.json`: that one is JSONC, and a round trip through
  /// `JSONSerialization` would delete every comment somebody wrote in it.
  public static func visualStudioCode(home: URL) -> WiringClient {
    WiringClient(
      id: "vscode", displayName: "Visual Studio Code",
      configURL: home.appending(path: "Library/Application Support/Code/User/mcp.json"),
      format: .json(rootKey: "servers"),
      bundleID: "com.microsoft.VSCode",
      evidence: [
        URL(filePath: "/Applications/Visual Studio Code.app"),
        URL(filePath: "/opt/homebrew/bin/code"),
        URL(filePath: "/usr/local/bin/code"),
      ],
      symbol: "chevron.left.forwardslash.chevron.right")
  }
}
