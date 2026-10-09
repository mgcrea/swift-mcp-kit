import MCPKitLoopback
import SwiftUI

extension MCPStatus {
  /// The light on the toolbar button. None while nothing is listening, so a light means a
  /// socket.
  public var tint: Color? {
    switch self {
    case .unavailable, .off, .starting: nil
    case .listening, .working: .green
    case .turnedAway: .orange
    case .failed: .red
    }
  }

  /// A tooltip's worth, and what VoiceOver reads as the button's value.
  public var summary: String {
    switch self {
    case .unavailable: "Let an AI agent on this Mac reach your data"
    case .off: "The MCP server is off"
    case .starting: "The MCP server is starting"
    case .listening: "The MCP server is listening"
    case .working: "An agent is using the MCP server"
    case .turnedAway: "An agent was turned away for its token"
    case .failed: "The MCP server could not start"
    }
  }
}

/// Whether the server listens, and what it last heard, for a settings form or the toolbar's
/// popover. Draws nothing while the server is off or unavailable.
public struct MCPStatusLabel: View {
  private let status: MCPStatus
  private let activity: MCPActivity

  public init(status: MCPStatus, activity: MCPActivity) {
    self.status = status
    self.activity = activity
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      switch status {
      case .unavailable, .off:
        EmptyView()
      case .starting:
        Label("Not running. It starts with the app's window.", systemImage: "circle")
          .foregroundStyle(.secondary)
      case .listening(let port), .working(let port), .turnedAway(let port):
        // `String(port)`: an interpolated `Int` in a `LocalizedStringKey` is grouped by the
        // locale, and 8791 would read "8 791".
        Label("Listening on 127.0.0.1:\(String(port))", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        if case .turnedAway = status {
          Label(
            "An agent was turned away for its token. Copy its configuration again.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }
        lastRequest
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Ticking on its own, since nothing else redraws a settings form while an agent works.
  private var lastRequest: some View {
    TimelineView(.periodic(from: .now, by: 10)) { _ in
      Group {
        if let served = activity.lastServed {
          Text(
            "Last request from an agent: \(served.formatted(.relative(presentation: .named)))")
        } else {
          Text("No request from an agent yet.")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
