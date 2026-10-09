#if canImport(AppKit)
  import AppKit
  import MCPKitWiring
  import SwiftUI

  /// The Bastion row of an app's MCP settings: "Add to Bastion…" where Bastion is installed,
  /// and where it is not, one sentence on what it is and a link to find out more.
  ///
  /// In the kit so every app on it offers the same thing in the same words. The link is made
  /// when the button is pressed rather than when the row is drawn, so the token it carries is
  /// read then, after any Regenerate, and never sits in a view's state.
  ///
  /// Drawn as a `LabeledContent` and a caption, to sit in a grouped `Form` section beside the
  /// token and the port.
  public struct BastionRow: View {
    private let link: @MainActor () -> BastionLink

    @State private var isInstalled = false
    @State private var error: String?

    public init(link: @escaping @MainActor () -> BastionLink) {
      self.link = link
    }

    public var body: some View {
      VStack(alignment: .leading, spacing: 4) {
        LabeledContent("Bastion") {
          if isInstalled {
            Button("Add to Bastion…", action: open)
          } else {
            Link("Get Bastion", destination: BastionLink.website)
          }
        }
        Text(.init(caption))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let error {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      // Read when the row appears, not once: Bastion may be installed while Settings is open
      // in another tab, and the next visit should offer the button.
      .onAppear { isInstalled = BastionLink.installedApplication != nil }
    }

    /// Markdown, for the link: `Text(LocalizedStringKey)` draws it as one.
    private var caption: String {
      let site = "[bastion.mgcrea.io](\(BastionLink.website.absoluteString))"
      return isInstalled
        ? "Hands this server to Bastion, which asks before adding it. Bastion keeps the token "
          + "in your Keychain, logs every call, and holds writes behind a switch of its own. "
          + site
        : "Bastion is a menu bar app that stands in front of your MCP servers: the tokens in "
          + "your Keychain instead of in every client's config, every call logged, and writes "
          + "behind a switch of its own. \(site)"
    }

    private func open() {
      error = nil
      let link = link()
      Task {
        do {
          try await link.open()
        } catch {
          self.error = error.localizedDescription
        }
      }
    }
  }
#endif
