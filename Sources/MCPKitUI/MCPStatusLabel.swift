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

  /// A tooltip's worth, and what VoiceOver reads as the button's value, in the kit's own
  /// translation: an app's catalog never held these, since a `String` is drawn as it is.
  public var summary: String {
    switch self {
    case .unavailable: localized("Let an AI agent on this Mac reach your data")
    case .off: localized("The MCP server is off")
    case .starting: localized("The MCP server is starting")
    case .listening: localized("The MCP server is listening")
    case .working: localized("An agent is using the MCP server")
    case .turnedAway: localized("An agent was turned away for its token")
    case .failed: localized("The MCP server could not start")
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
        Label(localized("Not running. It starts with the app's window."), systemImage: "circle")
          .foregroundStyle(.secondary)
      case .listening(let port), .working(let port), .turnedAway(let port):
        Label(listeningLine(port: port), systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
        if case .turnedAway = status {
          Label(
            localized("An agent was turned away for its token. Copy its configuration again."),
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
          // Formatted first: a key's interpolation must not nest a call, or the catalog
          // checks cannot match it to its entry.
          let when = served.formatted(.relative(presentation: .named))
          Text(localized("Last request from an agent: \(when)"))
        } else {
          Text(localized("No request from an agent yet."))
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
