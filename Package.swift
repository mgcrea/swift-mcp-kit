// swift-tools-version: 6.0
import PackageDescription

// An MCP server that runs *inside* a Mac or iOS app, on the loopback interface.
//
// Four products, deliberately split, on the same rule `swift-support-kit` splits by:
//
//   MCPKit           The protocol. Foundation only — no sockets, no SwiftUI, no Security.
//                    Every rule in the specification is a pure function over a frame here,
//                    so the conformance suite runs offline, on any platform, with nothing
//                    bound. That is the whole reason this target has no dependencies.
//   MCPKitLoopback   The listener: a POSIX socket on 127.0.0.1, a hand-written HTTP/1.1
//                    parser, the Host/Origin/bearer checks and the Keychain token.
//   MCPKitUI         The settings panel every consuming app otherwise builds again.
//   MCPKitWiring     Writing the server into the MCP clients on this Mac: their config
//                    files, merged or spliced so nothing else in them moves. It depends on
//                    nothing here, because it never talks to the server — it describes one.
//
// Why this is not part of `swift-support-kit`: that package CANNOT open a connection, and
// that is a requirement rather than a coincidence — it is what keeps the consuming apps'
// App Store privacy label at "Data Not Collected". This one binds a listening socket, so
// it needs its own package rather than a version of that one which quietly gained a
// network dependency. Same reasoning that produced `swift-cloudflare-kit`.
//
// The platform floor is macOS 15 / iOS 17 because nothing here needs more: a BSD socket,
// Foundation, and (in Loopback) Security for the token. The apps consuming it today all
// target macOS 26, and a floor raised to match them would lock out other consumers for no
// gain.
//
// `defaultLocalization` is what gives `Bundle.module` a localization table at all, and it names
// the language the source is written in. `MCPKitUI` owns a `Resources/Localizable.xcstrings`,
// because a bare `Text("…")` inside a package resolves against `Bundle.main`, the host app's
// bundle, finds no entry there, and draws the English key to a French user with no build error
// and no crash. Every string it draws goes through `localized(_:)`, which names `.module`, and
// `MCPKitUILocalizationTests` holds the catalog to the call sites, as swift-support-kit does.
//
// The other three have no catalog. What they say is mostly read by an agent (a fault, the
// write gate's refusal) or written into a file (a client's config). The exception is the few
// failures `MCPKitUI` shows as they come, the listener's and the Bastion link's, which are
// still English.
let package = Package(
  name: "swift-mcp-kit",
  defaultLocalization: "en",
  platforms: [.macOS(.v15), .iOS(.v17)],
  products: [
    .library(name: "MCPKit", targets: ["MCPKit"]),
    .library(name: "MCPKitLoopback", targets: ["MCPKitLoopback"]),
    .library(name: "MCPKitUI", targets: ["MCPKitUI"]),
    .library(name: "MCPKitWiring", targets: ["MCPKitWiring"]),
  ],
  targets: [
    .target(name: "MCPKit"),
    .target(name: "MCPKitLoopback", dependencies: ["MCPKit"]),
    .target(
      name: "MCPKitUI",
      dependencies: ["MCPKitLoopback", "MCPKitWiring"],
      resources: [.process("Resources")]
    ),
    .target(name: "MCPKitWiring"),
    .testTarget(name: "MCPKitTests", dependencies: ["MCPKit"]),
    .testTarget(name: "MCPKitLoopbackTests", dependencies: ["MCPKitLoopback"]),
    .testTarget(name: "MCPKitWiringTests", dependencies: ["MCPKitWiring"]),
    // Depends on no module: it reads the sources and the catalog off disk, so a lookup that
    // happens to resolve at runtime for the wrong reason cannot fool it.
    .testTarget(name: "MCPKitUILocalizationTests"),
  ]
)
