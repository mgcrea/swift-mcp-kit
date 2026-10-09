#if canImport(AppKit)
  import MCPKitLoopback
  import SwiftUI

  /// A toolbar button for an app's MCP server, with a light, and a popover holding the switch,
  /// the status and a way to set a client up.
  ///
  /// In the kit because the server is otherwise two levels into Settings in every app, where
  /// nobody who does not already know it is there looks, and because the light means the same
  /// in each: none while nothing listens, green while it does, pulsing for a minute after a
  /// request, orange when a request was turned away for its token, red when it failed.
  ///
  /// What differs between apps comes in from outside: `setup` is the section drawn once the
  /// server listens (`MCPCopySetup` in a sandboxed app, its own client rows in one that may
  /// write their configs), `unavailable` is what the popover says when the app does not offer
  /// the server (not bought, say), and `openSettings` turns Settings to the right pane.
  public struct MCPToolbarButton<Setup: View, Unavailable: View>: View {
    private let isAvailable: Bool
    @Binding private var isEnabled: Bool
    private let state: LoopbackListener.State
    private let activity: MCPActivity
    private let access: Text?
    private let unavailableSettingsTitle: LocalizedStringKey
    private let openSettings: () -> Void
    private let setup: (Int) -> Setup
    private let unavailable: () -> Unavailable

    @State private var isPresented = false

    /// - Parameters:
    ///   - access: A line under the status on what an agent may do, which the app words for
    ///     its own data and its write switch.
    ///   - unavailableSettingsTitle: The footer button's title while the server is not
    ///     available, such as "See Pro…"; `openSettings` runs either way.
    public init(
      isAvailable: Bool = true, isEnabled: Binding<Bool>, state: LoopbackListener.State,
      activity: MCPActivity, access: Text? = nil,
      unavailableSettingsTitle: LocalizedStringKey = "Settings…",
      openSettings: @escaping () -> Void,
      @ViewBuilder setup: @escaping (_ port: Int) -> Setup,
      @ViewBuilder unavailable: @escaping () -> Unavailable
    ) {
      self.isAvailable = isAvailable
      self._isEnabled = isEnabled
      self.state = state
      self.activity = activity
      self.access = access
      self.unavailableSettingsTitle = unavailableSettingsTitle
      self.openSettings = openSettings
      self.setup = setup
      self.unavailable = unavailable
    }

    public var body: some View {
      // Redrawn every few seconds, to let the light settle back from working to listening.
      TimelineView(.periodic(from: .now, by: 10)) { context in
        let status = MCPStatus(
          isAvailable: isAvailable, isEnabled: isEnabled, state: state, activity: activity,
          now: context.date)
        Button {
          isPresented.toggle()
        } label: {
          Label {
            Text("MCP Server")
          } icon: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
              .overlay(alignment: .bottomTrailing) { light(status) }
          }
        }
        .help(status.summary)
        .accessibilityValue(Text(status.summary))
        .accessibilityIdentifier("toolbar.mcp")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
          popover(status)
        }
      }
    }

    @ViewBuilder private func light(_ status: MCPStatus) -> some View {
      if let tint = status.tint {
        Image(systemName: "circle.fill")
          .font(.system(size: 7))
          .foregroundStyle(tint)
          .symbolEffect(.pulse, isActive: status.isWorking)
          .offset(x: 3, y: 3)
      }
    }

    private func popover(_ status: MCPStatus) -> some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "point.3.connected.trianglepath.dotted")
            .foregroundStyle(.secondary)
          Text("MCP Server")
            .font(.headline)
        }
        if isAvailable {
          Toggle("Run the MCP server", isOn: $isEnabled)
            .toggleStyle(.switch)
          if isEnabled {
            MCPStatusLabel(status: status, activity: activity)
            if let access {
              access
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          if case .running(let port) = state {
            Divider()
            setup(port)
          }
        } else {
          unavailable()
        }
        Divider()
        HStack {
          Spacer()
          Button(isAvailable ? "MCP Server Settings…" : unavailableSettingsTitle) {
            isPresented = false
            openSettings()
          }
        }
      }
      .padding(16)
      .frame(width: 340)
    }
  }

  extension MCPToolbarButton where Unavailable == EmptyView {
    /// For an app that offers the server to everybody.
    public init(
      isEnabled: Binding<Bool>, state: LoopbackListener.State, activity: MCPActivity,
      access: Text? = nil, openSettings: @escaping () -> Void,
      @ViewBuilder setup: @escaping (_ port: Int) -> Setup
    ) {
      self.init(
        isAvailable: true, isEnabled: isEnabled, state: state, activity: activity,
        access: access, openSettings: openSettings, setup: setup, unavailable: { EmptyView() })
    }
  }
#endif
