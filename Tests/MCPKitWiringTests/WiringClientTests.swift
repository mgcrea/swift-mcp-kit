import Foundation
import Testing

@testable import MCPKitWiring

@Suite("WiringClient")
struct WiringClientTests {

  private let server = WiredServer(key: "armada", url: "http://127.0.0.1:8790/mcp", token: "tok")

  private func claude(in directory: URL) -> WiringClient {
    .claudeCode(configURL: directory.appending(path: ".claude.json"), evidence: [directory])
  }

  private func codex(in directory: URL) -> WiringClient {
    WiringClient(
      id: "codex", displayName: "Codex", configURL: directory.appending(path: "config.toml"),
      format: .toml, evidence: [directory], symbol: "terminal")
  }

  /// The shape that makes a line scanner dangerous: a heading and a table header inside a
  /// multi-line string, right above a real `[mcp_servers]` table.
  private static let codexConfig = """
    model = "gpt-5.5"
    # Trust levels below were set by the ChatGPT app.

    developer_instructions = \"\"\"
    # Working rules
    [mcp_servers.invented]
    Never invent a server.
    \"\"\"

    [mcp_servers.node_repl]
    command = "/Applications/ChatGPT.app/Contents/Resources/node_repl"
    args = ["--stdio"]

    [projects."/Users/me/repo"]
    trust_level = "trusted"

    """

  // MARK: - JSON

  @Test("A JSON config is configured, rotated and cleaned out, keeping everyone else's keys")
  func jsonLifecycle() throws {
    let client = claude(in: try scratchDirectory())
    let original: [String: Any] = [
      "numStartups": 42,
      "hasCompletedOnboarding": true,
      "projects": [
        "/Users/me/repo": [
          "allowedTools": ["Bash"], "mcpServers": ["local": ["command": "/bin/echo"]],
        ]
      ],
      "mcpServers": [
        "almanac": [
          "type": "http", "url": "http://127.0.0.1:8788/mcp",
          "headers": ["Authorization": "Bearer other"],
        ]
      ],
    ]
    try JSONSerialization.data(withJSONObject: original).write(to: client.configURL)

    #expect(client.status(of: server) == .notConfigured)
    #expect(!client.isWired(server))
    #expect(try client.configure(server) != nil)
    #expect(client.status(of: server) == .configured)
    #expect(client.isWired(server))

    // A regenerated token leaves the entry ours, and out of date.
    let rotated = WiredServer(key: "armada", url: server.url, token: "new")
    #expect(client.status(of: rotated) == .stale(server.url))
    try client.configure(rotated)
    #expect(client.status(of: rotated) == .configured)
    #expect(try client.configure(rotated) == nil)

    try client.unwire(rotated)
    #expect(client.status(of: rotated) == .notConfigured)
    let after = try WiringFile.readJSON(client.configURL)
    #expect(NSDictionary(dictionary: after).isEqual(to: original))
  }

  @Test("Somebody else's entry under our key is refused, and replaced only when forced")
  func refusesTakenKey() throws {
    let client = claude(in: try scratchDirectory())
    let original = #"{"mcpServers":{"armada":{"command":"/opt/armada-mcp"}}}"#
    try Data(original.utf8).write(to: client.configURL)

    #expect(client.status(of: server) == .taken("/opt/armada-mcp"))
    #expect(!client.isWired(server))
    #expect(throws: WiringError.taken(client: "Claude Code", key: "armada")) {
      try client.configure(server)
    }
    #expect(try String(contentsOf: client.configURL, encoding: .utf8) == original)

    // Removing ours must not reach it either.
    #expect(try client.unwire(server) == nil)
    #expect(try String(contentsOf: client.configURL, encoding: .utf8) == original)

    try client.configure(server, force: true)
    #expect(client.status(of: server) == .configured)
  }

  @Test("An installed client with no config yet is given one, privately")
  func createsConfig() throws {
    let client = claude(in: try scratchDirectory())
    #expect(client.status(of: server) == .notConfigured)
    #expect(try client.configure(server) == nil)
    #expect(client.status(of: server) == .configured)
    #expect(try permissions(client.configURL) == 0o600)
  }

  @Test("Removing from a config that does not exist writes nothing")
  func unwireAbsent() throws {
    let client = claude(in: try scratchDirectory())
    #expect(try client.unwire(server) == nil)
    #expect(!FileManager.default.fileExists(atPath: client.configURL.path))
  }

  @Test("A client with no evidence and no config is not installed")
  func notInstalled() throws {
    let nowhere = try scratchDirectory().appending(path: "absent")
    let client = WiringClient.claudeCode(
      configURL: nowhere.appending(path: ".claude.json"), evidence: [nowhere])
    #expect(client.status(of: server) == .notInstalled)
  }

  @Test("A config that does not parse is unreadable, and is never written")
  func unreadable() throws {
    let client = claude(in: try scratchDirectory())
    try Data("{ not json".utf8).write(to: client.configURL)

    guard case .unreadable = client.status(of: server) else {
      Issue.record("expected .unreadable, got \(client.status(of: server))")
      return
    }
    #expect(throws: (any Error).self) { try client.configure(server) }
    #expect(try String(contentsOf: client.configURL, encoding: .utf8) == "{ not json")
  }

  // MARK: - TOML

  @Test("Configuring then removing in TOML returns the original bytes")
  func tomlRoundTrip() throws {
    let client = codex(in: try scratchDirectory())
    try Data(Self.codexConfig.utf8).write(to: client.configURL)
    #expect(client.status(of: server) == .notConfigured)

    try client.configure(server)
    let wired = try String(contentsOf: client.configURL, encoding: .utf8)
    #expect(
      wired.contains(
        """
        [mcp_servers.armada]
        url = "http://127.0.0.1:8790/mcp"
        http_headers = { Authorization = "Bearer tok" }

        """))
    #expect(wired.contains("Never invent a server."))
    #expect(client.status(of: server) == .configured)

    // Byte-identical the second time, so nothing is written.
    #expect(try client.configure(server) == nil)

    try client.unwire(server)
    #expect(try String(contentsOf: client.configURL, encoding: .utf8) == Self.codexConfig)
  }

  @Test("Updating our TOML entry keeps keys that were added to it")
  func tomlRotation() throws {
    let client = codex(in: try scratchDirectory())
    let stale =
      Self.codexConfig + """

        [mcp_servers.armada]
        url = "http://127.0.0.1:9000/mcp"
        http_headers = { Authorization = "Bearer old" }
        startup_timeout_sec = 20

        """
    try Data(stale.utf8).write(to: client.configURL)
    #expect(client.status(of: server) == .stale("http://127.0.0.1:9000/mcp"))

    try client.configure(server)
    let text = try String(contentsOf: client.configURL, encoding: .utf8)
    #expect(text.contains("Bearer tok"))
    #expect(!text.contains("Bearer old"))
    #expect(text.contains("startup_timeout_sec = 20"))
    #expect(text.components(separatedBy: "[mcp_servers.armada]").count == 2)
    #expect(client.status(of: server) == .configured)
  }

  @Test("CRLF line endings survive a configure and a removal")
  func tomlCRLF() throws {
    let client = codex(in: try scratchDirectory())
    let original = "model = \"gpt-5.5\"\r\n\r\n[projects.\"/r\"]\r\ntrust_level = \"trusted\"\r\n"
    try Data(original.utf8).write(to: client.configURL)

    try client.configure(server)
    #expect(
      try String(contentsOf: client.configURL, encoding: .utf8)
        .contains("[mcp_servers.armada]\r\nurl = "))
    try client.unwire(server)
    #expect(try String(contentsOf: client.configURL, encoding: .utf8) == original)
  }

  @Test("A TOML server under our key that is not ours is refused")
  func tomlTaken() throws {
    let client = codex(in: try scratchDirectory())
    let original = "[mcp_servers.armada]\ncommand = \"/opt/armada-mcp\"\n"
    try Data(original.utf8).write(to: client.configURL)

    #expect(client.status(of: server) == .taken("/opt/armada-mcp"))
    #expect(throws: WiringError.taken(client: "Codex", key: "armada")) {
      try client.configure(server)
    }
    #expect(try String(contentsOf: client.configURL, encoding: .utf8) == original)
  }
}
