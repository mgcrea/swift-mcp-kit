import MCPKit
import MCPKitLoopback
import SwiftUI

/// The settings panel a consuming app would otherwise write again.
///
/// It is in this package rather than in each app because two of the three apps that led to
/// it had already built the same one, and because the copy on it is a security surface: the
/// sentence that explains what "Allow writes" governs is the only place a user learns that
/// the answer is *their data*, not "anything that writes".
public struct MCPServerPanel: View {

  @Binding private var isEnabled: Bool
  @Binding private var allowWrites: Bool
  @Binding private var port: Int

  private let serverName: String
  private let state: LoopbackListener.State
  private let token: String
  private let regenerateToken: () -> Void

  @State private var snippet: ClientSnippet = .claudeCode
  @State private var tokenRevealed = false

  public init(
    serverName: String, isEnabled: Binding<Bool>, allowWrites: Binding<Bool>,
    port: Binding<Int>, state: LoopbackListener.State, token: String,
    regenerateToken: @escaping () -> Void
  ) {
    self.serverName = serverName
    self._isEnabled = isEnabled
    self._allowWrites = allowWrites
    self._port = port
    self.state = state
    self.token = token
    self.regenerateToken = regenerateToken
  }

  private var isRunning: Bool {
    if case .running = state { return true }
    return false
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle("MCP server", isOn: $isEnabled)
      Text(
        "Lets an AI agent on this Mac read \(serverName)'s data. It listens on 127.0.0.1 "
          + "only — nothing is reachable from another machine, and nothing leaves this one."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if isEnabled {
        Divider()
        status
        Toggle("Allow writes", isOn: $allowWrites)
        // The precise sentence matters. "Anything that writes" would be wrong — an export
        // writes a file and is never gated — and leaving it vague is how the gate later
        // gets "fixed" into covering things it was never meant to.
        Text(
          "Off, an agent can only read. On, it can also change your data and preferences "
            + "in \(serverName). Writing an export file is not covered by this switch."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        portField
        if isRunning { connection }
      }
    }
  }

  @ViewBuilder private var status: some View {
    switch state {
    case .running(let boundPort):
      Label("Listening on 127.0.0.1:\(boundPort)", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.callout)
    case .stopped:
      Label("Not running", systemImage: "circle").foregroundStyle(.secondary).font(.callout)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .font(.callout)
    }
  }

  private var portField: some View {
    HStack {
      Text("Port")
      TextField("Port", value: $port, format: .number.grouping(.never))
        .frame(width: 80)
        // Changing the port under a live listener would leave clients pointed at a socket
        // that is no longer there, with nothing on screen saying so.
        .disabled(isRunning)
      if isRunning {
        Text("Turn the server off to change the port.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var connection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Token").font(.callout)
        Text(tokenRevealed ? token : String(repeating: "•", count: 24))
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
        Button(tokenRevealed ? "Hide" : "Reveal") { tokenRevealed.toggle() }
          .buttonStyle(.borderless)
        Button("Regenerate", action: regenerateToken).buttonStyle(.borderless)
      }
      Text("Regenerating stops any agent still using the old token.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Set up in", selection: $snippet) {
        ForEach(ClientSnippet.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      if case .running(let boundPort) = state {
        let text = snippet.text(serverName: serverName, port: boundPort, token: token)
        ScrollView(.horizontal) {
          Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
        .frame(maxHeight: 120)
        Button("Copy") { copy(text) }.buttonStyle(.borderless)
      }
    }
  }

  private func copy(_ text: String) {
    #if canImport(AppKit)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #elseif canImport(UIKit)
      UIPasteboard.general.string = text
    #endif
  }
}

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif
