import Foundation
import Testing

@testable import MCPKitLoopback

@Suite("ClientSnippet")
struct ClientSnippetTests {

  private func root(of snippet: ClientSnippet) throws -> [String: Any] {
    let text = snippet.text(serverName: "thing", port: 8787, token: "t0k")
    return try #require(
      JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  /// VS Code's `mcp.json` keeps its servers under `servers`; the others' under `mcpServers`.
  /// A snippet with the wrong key pastes cleanly and configures nothing, with no error.
  @Test("Every JSON snippet naming VS Code uses the key VS Code reads")
  func vsCodeReadsServers() throws {
    #expect(ClientSnippet.allCases.contains { $0.rawValue.contains("VS Code") })
    for snippet in ClientSnippet.allCases where snippet.rawValue.contains("VS Code") {
      let root = try root(of: snippet)
      let servers = try #require(root["servers"] as? [String: Any], "\(snippet)")
      #expect(servers["thing"] != nil)
      #expect(root["mcpServers"] == nil)
    }
  }

  @Test("Claude Desktop and Cursor keep mcpServers")
  func othersReadMCPServers() throws {
    let servers = try #require(try root(of: .json)["mcpServers"] as? [String: Any])
    let thing = try #require(servers["thing"] as? [String: Any])
    #expect(thing["url"] as? String == "http://127.0.0.1:8787/mcp")
  }
}
