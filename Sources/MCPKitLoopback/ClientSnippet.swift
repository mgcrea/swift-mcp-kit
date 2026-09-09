import Foundation

/// The configuration a person pastes into their editor.
///
/// Three shapes for four clients, which is the actual state of the world rather than an
/// oversight: the JSON hosts agree, Codex uses TOML, and a stdio-only host cannot use an
/// HTTP endpoint at all and is told so rather than given something that will not work.
public enum ClientSnippet: String, Sendable, CaseIterable {
  case claudeCode = "Claude Code"
  case json = "Claude Desktop / Cursor / VS Code"
  case codex = "Codex"

  public func text(serverName: String, port: Int, token: String) -> String {
    let url = "http://127.0.0.1:\(port)/mcp"
    switch self {
    case .claudeCode:
      return """
        claude mcp add --transport http \(serverName) \(url) \\
          --header "Authorization: Bearer \(token)"
        """
    case .json:
      return """
        {
          "mcpServers": {
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
