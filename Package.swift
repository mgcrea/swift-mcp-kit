// swift-tools-version: 6.0
import PackageDescription

// An MCP server that runs *inside* a Mac or iOS app, on the loopback interface.
//
// Three products, deliberately split, on the same rule `swift-support-kit` splits by:
//
//   MCPKit           The protocol. Foundation only — no sockets, no SwiftUI, no Security.
//                    Every rule in the specification is a pure function over a frame here,
//                    so the conformance suite runs offline, on any platform, with nothing
//                    bound. That is the whole reason this target has no dependencies.
//   MCPKitLoopback   The listener: a POSIX socket on 127.0.0.1, a hand-written HTTP/1.1
//                    parser, the Host/Origin/bearer checks and the Keychain token.
//   MCPKitUI         The settings panel every consuming app otherwise builds again.
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
let package = Package(
  name: "swift-mcp-kit",
  platforms: [.macOS(.v15), .iOS(.v17)],
  products: [
    .library(name: "MCPKit", targets: ["MCPKit"]),
    .library(name: "MCPKitLoopback", targets: ["MCPKitLoopback"]),
    .library(name: "MCPKitUI", targets: ["MCPKitUI"]),
  ],
  targets: [
    .target(name: "MCPKit"),
    .target(name: "MCPKitLoopback", dependencies: ["MCPKit"]),
    .target(name: "MCPKitUI", dependencies: ["MCPKitLoopback"]),
    .testTarget(name: "MCPKitTests", dependencies: ["MCPKit"]),
    .testTarget(name: "MCPKitLoopbackTests", dependencies: ["MCPKitLoopback"]),
  ]
)
