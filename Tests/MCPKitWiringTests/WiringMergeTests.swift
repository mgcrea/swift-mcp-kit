import Foundation
import Testing

@testable import MCPKitWiring

@Suite("WiringMerge")
struct WiringMergeTests {

  private let server = WiredServer(key: "armada", url: "http://127.0.0.1:8790/mcp", token: "tok")

  private var expected: [String: Any] {
    ["type": "http", "url": server.url, "headers": ["Authorization": "Bearer tok"]]
  }

  private func state(_ servers: [String: Any]) -> WiringMerge.EntryState {
    WiringMerge.state(of: servers, key: "armada", expected: expected, owns: server.owns)
  }

  @Test("Ownership takes our key and a loopback URL, and ignores port and token")
  func ownership() {
    #expect(server.owns(key: "armada", entry: ["url": "http://127.0.0.1:9999/mcp"]))
    #expect(server.owns(key: "armada", entry: ["url": "http://localhost:8790/mcp"]))
    // Another app on this package serves the very same path.
    #expect(!server.owns(key: "almanac", entry: ["url": "http://127.0.0.1:8788/mcp"]))
    #expect(!server.owns(key: "armada", entry: ["url": "https://armada.example.com/mcp"]))
    #expect(!server.owns(key: "armada", entry: ["command": "/usr/local/bin/armada"]))
  }

  @Test("An entry is missing, matching, stale or foreign")
  func states() {
    #expect(state([:]) == .missing)
    #expect(state(["armada": expected]) == .matches)

    // A key the client added of its own accord does not make the entry stale forever.
    var annotated = expected
    annotated["enabled"] = true
    #expect(state(["armada": annotated]) == .matches)

    var rotated = expected
    rotated["headers"] = ["Authorization": "Bearer old"]
    #expect(state(["armada": rotated]) == .stale(server.url))

    var moved = expected
    moved["url"] = "http://127.0.0.1:9000/mcp"
    #expect(state(["armada": moved]) == .stale("http://127.0.0.1:9000/mcp"))

    #expect(state(["armada": ["command": "/opt/armada-mcp"]]) == .foreign("/opt/armada-mcp"))
    #expect(state(["armada": "not an object"]) == .foreign(nil))
  }

  @Test("Merging updates our entry in place and leaves everything else alone")
  func mergesInPlace() {
    let root: [String: Any] = [
      "numStartups": 12,
      "projects": ["/repo": ["mcpServers": ["local": ["command": "/bin/echo"]]]],
      "mcpServers": [
        "armada": ["type": "http", "url": "http://127.0.0.1:9000/mcp", "timeout": 30],
        "almanac": ["type": "http", "url": "http://127.0.0.1:8788/mcp"],
      ],
    ]
    let merged = WiringMerge.merged(
      into: root, rootKey: "mcpServers", entries: ["armada": expected], owns: server.owns)

    let servers = merged["mcpServers"] as? [String: Any]
    let armada = servers?["armada"] as? [String: Any]
    #expect(armada?["url"] as? String == server.url)
    #expect(armada?["timeout"] as? Int == 30)
    #expect(servers?["almanac"] != nil)
    #expect(merged["numStartups"] as? Int == 12)
    #expect(
      NSDictionary(dictionary: merged["projects"] as? [String: Any] ?? [:])
        .isEqual(to: root["projects"] as? [String: Any] ?? [:]))
  }

  /// Merging into somebody else's entry would graft our URL onto their `command`.
  @Test("A foreign entry under our key is replaced outright, never merged into")
  func replacesForeign() {
    let root: [String: Any] = ["mcpServers": ["armada": ["command": "/opt/x", "args": ["a"]]]]
    let merged = WiringMerge.merged(
      into: root, rootKey: "mcpServers", entries: ["armada": expected], owns: server.owns)
    let armada = (merged["mcpServers"] as? [String: Any])?["armada"] as? [String: Any]
    #expect(armada?["command"] == nil)
    #expect(armada?["url"] as? String == server.url)
  }

  @Test("Unmerging takes out ours, and not another loopback app's entry")
  func unmergesOursOnly() {
    let root: [String: Any] = [
      "mcpServers": [
        "armada": ["type": "http", "url": "http://127.0.0.1:9000/mcp"],
        "almanac": ["type": "http", "url": "http://127.0.0.1:8788/mcp"],
        "remote": ["type": "http", "url": "https://example.com/mcp"],
      ]
    ]
    let servers =
      WiringMerge.unmerged(from: root, rootKey: "mcpServers", owns: server.owns)["mcpServers"]
      as? [String: Any]
    #expect(servers.map { Set($0.keys) } == ["almanac", "remote"])
  }

  @Test("An emptied servers object stays present rather than disappearing")
  func keepsEmptyRoot() {
    let root: [String: Any] = ["mcpServers": ["armada": ["url": "http://127.0.0.1:1/mcp"]]]
    let unmerged = WiringMerge.unmerged(from: root, rootKey: "mcpServers", owns: server.owns)
    #expect((unmerged["mcpServers"] as? [String: Any])?.isEmpty == true)
  }

  @Test("A collision is our key holding somebody else's entry, and nothing else")
  func collisions() {
    let owns = server.owns
    #expect(WiringMerge.collisions(servers: [:], keys: ["armada"], owns: owns).isEmpty)
    #expect(
      WiringMerge.collisions(
        servers: ["armada": ["url": "http://127.0.0.1:1/mcp"]], keys: ["armada"], owns: owns
      ).isEmpty)
    #expect(
      WiringMerge.collisions(servers: ["armada": ["command": "/x"]], keys: ["armada"], owns: owns)
        == ["armada"])
  }
}
