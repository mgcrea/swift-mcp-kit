import Foundation

/// The configuration a person pastes into their editor.
///
/// Four shapes, which is the actual state of the world rather than an oversight: Claude Code
/// takes a command, Claude Desktop and Cursor agree on `mcpServers`, VS Code's `mcp.json`
/// reads `servers` instead, and Codex uses TOML. The VS Code key is its own case because a
/// snippet under the wrong key pastes cleanly and configures nothing.
public enum ClientSnippet: String, Sendable, CaseIterable {
  case claudeCode = "Claude Code"
  case json = "Claude Desktop / Cursor"
  case vscode = "VS Code"
  case codex = "Codex"

  public func text(serverName: String, port: Int, token: String) -> String {
    let url = "http://127.0.0.1:\(port)/mcp"
    switch self {
    case .claudeCode:
      return """
        claude mcp add --transport http \(serverName) \(url) \\
          --header "Authorization: Bearer \(token)"
        """
    case .json, .vscode:
      return """
        {
          "\(self == .vscode ? "servers" : "mcpServers")": {
            "\(serverName)": {
              "type": "http",
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    case .codex:
      return """
        [mcp_servers.\(serverName)]
        url = "\(url)"
        http_headers = { "Authorization" = "Bearer \(token)" }
        """
    }
  }
}
