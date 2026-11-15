#if os(macOS) || targetEnvironment(macCatalyst)
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
  /// the server (not bought, say), `status` is the line under the switch while it is on
  /// (`MCPStatusLabel` unless the app words its own), and `openSettings` turns Settings to the
  /// right pane.
  ///
  /// The status is held as an `AnyView`, not as a third type parameter, so that an app which
  /// spells the type out (`MCPToolbarButton<MCPCopySetup, EmptyView>`) still compiles.
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
    private let statusView: (MCPStatus) -> AnyView

    @State private var isPresented = false

    /// - Parameters:
    ///   - access: A line under the status on what an agent may do, which the app words for
    ///     its own data and its write switch.
    ///   - unavailableSettingsTitle: The footer button's title while the server is not
    ///     available, such as "See Pro…"; `openSettings` runs either way.
    ///   - status: The server's state in the app's own words, drawn under the switch while it
    ///     is on, for an app whose server does not behave as `MCPStatusLabel` says (it starts
    ///     before any window, say) or whose words are its own. Drawn only while the switch is
    ///     on, so handed `.starting`, `.listening`, `.working`, `.turnedAway` or `.failed`,
    ///     never `.off` or `.unavailable`; redrawn as the light is.
    public init<Status: View>(
      isAvailable: Bool = true, isEnabled: Binding<Bool>, state: LoopbackListener.State,
      activity: MCPActivity, access: Text? = nil,
      unavailableSettingsTitle: LocalizedStringKey = "Settings…",
      openSettings: @escaping () -> Void,
      @ViewBuilder status: @escaping (MCPStatus) -> Status,
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
      self.statusView = { AnyView(status($0)) }
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
            statusView(status)
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

  extension MCPToolbarButton {
    /// With the kit's status line, `MCPStatusLabel`.
    public init(
      isAvailable: Bool = true, isEnabled: Binding<Bool>, state: LoopbackListener.State,
      activity: MCPActivity, access: Text? = nil,
      unavailableSettingsTitle: LocalizedStringKey = "Settings…",
      openSettings: @escaping () -> Void,
      @ViewBuilder setup: @escaping (_ port: Int) -> Setup,
      @ViewBuilder unavailable: @escaping () -> Unavailable
    ) {
      self.init(
        isAvailable: isAvailable, isEnabled: isEnabled, state: state, activity: activity,
        access: access, unavailableSettingsTitle: unavailableSettingsTitle,
        openSettings: openSettings,
        status: { MCPStatusLabel(status: $0, activity: activity) },
        setup: setup, unavailable: unavailable)
    }
  }

  extension MCPToolbarButton where Unavailable == EmptyView {
    /// For an app that offers the server to everybody, and words its status itself.
    public init<Status: View>(
      isEnabled: Binding<Bool>, state: LoopbackListener.State, activity: MCPActivity,
      access: Text? = nil, openSettings: @escaping () -> Void,
      @ViewBuilder status: @escaping (MCPStatus) -> Status,
      @ViewBuilder setup: @escaping (_ port: Int) -> Setup
    ) {
      self.init(
        isAvailable: true, isEnabled: isEnabled, state: state, activity: activity,
        access: access, openSettings: openSettings, status: status, setup: setup,
        unavailable: { EmptyView() })
    }

    /// For an app that offers the server to everybody.
    public init(
      isEnabled: Binding<Bool>, state: LoopbackListener.State, activity: MCPActivity,
      access: Text? = nil, openSettings: @escaping () -> Void,
      @ViewBuilder setup: @escaping (_ port: Int) -> Setup
    ) {
      self.init(
        isAvailable: true, isEnabled: isEnabled, state: state, activity: activity,
        access: access, openSettings: openSettings,
        status: { MCPStatusLabel(status: $0, activity: activity) }, setup: setup,
        unavailable: { EmptyView() })
    }
  }
#endif
