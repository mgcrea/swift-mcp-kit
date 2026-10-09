#if canImport(AppKit)
  import AppKit
  import MCPKitLoopback
  import MCPKitWiring
  import SwiftUI

  extension ClientSnippet {
    /// The clients a sandboxed app can hand a configuration to, in the order they are offered.
    public static let setupOrder: [ClientSnippet] = [.claudeCode, .codex, .vscode, .json]

    /// The name to offer the snippet under. The JSON one is Cursor's here: Claude Desktop
    /// shares the shape but only starts servers it launches itself, so it cannot reach one.
    public var setupName: String {
      self == .json ? "Cursor" : rawValue
    }

    /// Where the copied text goes. A sandboxed app can write none of these files itself.
    public var setupHint: LocalizedStringKey {
      switch self {
      case .claudeCode: "A command. Paste it into Terminal."
      case .codex: "A table for ~/.codex/config.toml."
      case .vscode: "For the mcp.json that MCP: Open User Configuration opens."
      case .json: "For ~/.cursor/mcp.json, beside any servers already there."
      }
    }

    /// Onto the pasteboard, with the real token.
    @MainActor public func copy(serverName: String, port: Int, token: String) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(
        text(serverName: serverName, port: port, token: token), forType: .string)
    }
  }

  /// A client's configuration to copy, and Bastion: setup for an app the sandbox keeps out of
  /// every client's config file, for `MCPToolbarButton`'s popover.
  ///
  /// Two columns, labels to the right of the first, so the controls and the captions under
  /// them share one edge. Not `BastionRow`, which is a grouped form's row with a form's
  /// caption, and lines up with nothing outside one.
  public struct MCPCopySetup: View {
    private let serverName: String
    private let port: Int
    private let token: () -> String
    private let bastion: @MainActor (_ token: String) -> BastionLink

    @State private var snippet: ClientSnippet = .claudeCode
    @State private var copied = false
    @State private var isBastionInstalled = false
    @State private var bastionError: String?

    /// - Parameters:
    ///   - token: Read on each copy and each Add to Bastion, so either carries the token as it
    ///     is after a Regenerate. Empty disables Copy.
    ///   - bastion: The link handed to Bastion, made with the token just read.
    public init(
      serverName: String, port: Int, token: @escaping () -> String,
      bastion: @escaping @MainActor (_ token: String) -> BastionLink
    ) {
      self.serverName = serverName
      self.port = port
      self.token = token
      self.bastion = bastion
    }

    public var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        row("Set up in") {
          HStack(spacing: 8) {
            Picker("Set up in", selection: $snippet) {
              ForEach(ClientSnippet.setupOrder, id: \.self) { Text($0.setupName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button {
              snippet.copy(serverName: serverName, port: port, token: token())
              copied = true
            } label: {
              Label(
                copied ? "Copied" : "Copy Configuration",
                systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .contentTransition(.symbolEffect(.replace))
            .help("Copy the configuration for \(snippet.setupName), with its token")
            .disabled(token().isEmpty)
            .task(id: copied) {
              guard copied else { return }
              try? await Task.sleep(for: .seconds(2))
              copied = false
            }
          }
          caption(snippet.setupHint)
        }
        row("Bastion") {
          if isBastionInstalled {
            Button("Add to Bastion…", action: addToBastion)
          } else {
            Link("Get Bastion", destination: BastionLink.website)
          }
          // Markdown, for the link, which an interpolated key would draw as plain text.
          caption(
            LocalizedStringKey(
              (isBastionInstalled
                ? "Keeps the token in your Keychain and logs every call. It asks before adding the server. "
                : "A menu bar app that keeps the token in your Keychain and logs every call. ")
                + "[bastion.mgcrea.io](\(BastionLink.website.absoluteString))"))
          if let bastionError {
            Text(bastionError)
              .font(.caption)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      // Read when shown: Bastion may have been installed since the last time.
      .onAppear { isBastionInstalled = BastionLink.installedApplication != nil }
    }

    /// A label, then its control with the caption under it. The label sits on every label
    /// laid over each other and hidden, so the column is as wide as the longest in any
    /// language, and the second column has the rest: a `Grid` sized that column from the
    /// picker's row and wrapped every caption to it.
    private func row(
      _ label: LocalizedStringKey, @ViewBuilder content: () -> some View
    ) -> some View {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        ZStack(alignment: .trailing) {
          Text("Set up in").hidden()
          Text("Bastion").hidden()
          Text(label)
        }
        VStack(alignment: .leading, spacing: 4) { content() }
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addToBastion() {
      bastionError = nil
      let link = bastion(token())
      Task {
        do {
          try await link.open()
        } catch {
          bastionError = error.localizedDescription
        }
      }
    }
  }
#endif
