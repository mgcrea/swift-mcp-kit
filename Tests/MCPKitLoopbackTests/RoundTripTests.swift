import Foundation
import MCPKit
import Testing

@testable import MCPKitLoopback

/// Drives a real listener over a real socket.
///
/// The unit suites prove the rules; this proves they are actually reachable through a bound
/// port, which is a different claim. Every bug this file has ever caught lived in the gap
/// between the two.
@Suite(.serialized)
struct RoundTripTests {

  private static let token = "test-token-do-not-ship"

  private func withServer<T>(
    port: Int, allowWrites: Bool = false, _ body: (Int) async throws -> T
  ) async throws -> T {
    var tools = ToolTable()
    tools.add(MCPTool(name: "read_thing", description: "Reads.", annotations: .readOnly)) { _ in
      .answer("one row", ["rows": 1])
    }
    tools.add(
      MCPTool(
        name: "write_thing", description: "Writes.", gate: .requiresWrites,
        annotations: .mutating(destructive: false))
    ) { _ in .text("wrote") }

    let listener = LoopbackListener(
      server: MCPServer(
        info: ServerInfo(name: "RoundTrip", version: "1.0.0"), tools: tools),
      gate: RequestGate(port: port) { presented in
        guard let presented else { return .rejected }
        return constantTimeEquals(presented, Self.token) ? .accepted(client: "test") : .rejected
      },
      allowWrites: { allowWrites })

    listener.start(port: port)
    defer { listener.stop() }
    guard case .running = listener.state else {
      Issue.record("listener did not bind: \(listener.state)")
      throw CancellationError()
    }
    return try await body(port)
  }

  private func post(
    port: Int, body: JSONValue, headers: [String: String] = [:], token: String? = token,
    method: String = "POST"
  ) async throws -> (status: Int, json: JSONValue?) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = method
    // Only POST carries a body. URLSession refuses to send one on a GET at all, so setting
    // it unconditionally would fail the request before it reached the server under test.
    if method == "POST" { request.httpBody = try JSONEncoder().encode(body) }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as! HTTPURLResponse).statusCode
    return (status, try? JSONDecoder().decode(JSONValue.self, from: data))
  }

  private func modernFrame(method: String, name: String? = nil) -> JSONValue {
    var params: [String: JSONValue] = [
      "_meta": [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": ["name": "RoundTripClient", "version": "1"],
      ]
    ]
    if let name {
      params["name"] = .string(name)
      params["arguments"] = .object([:])
    }
    return ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": .object(params)]
  }

  private func modernHeaders(method: String, name: String? = nil) -> [String: String] {
    var headers = ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": method]
    if let name { headers["Mcp-Name"] = name }
    return headers
  }

  // MARK: -

  @Test("The listener binds synchronously, so state is trustworthy on return")
  func bindsBeforeReturning() async throws {
    try await withServer(port: 18_801) { port in
      let (status, _) = try await post(
        port: port, body: modernFrame(method: "server/discover"),
        headers: modernHeaders(method: "server/discover"))
      #expect(status == 200)
    }
  }

  @Test("A 2026-07-28 tools/list round trip")
  func modernListing() async throws {
    try await withServer(port: 18_802) { port in
      let (status, json) = try await post(
        port: port, body: modernFrame(method: "tools/list"),
        headers: modernHeaders(method: "tools/list"))
      #expect(status == 200)
      let result = try #require(json?["result"])
      #expect(result["resultType"] == .string("complete"))
      #expect(result["cacheScope"] == .string("private"))
      #expect(try #require(result["tools"]?.arrayValue).count == 1)
    }
  }

  /// The reason this server speaks three revisions: an SDK 1.x client sends exactly this,
  /// with no MCP headers at all.
  @Test("A legacy initialize round trip, with no MCP headers")
  func legacyHandshake() async throws {
    try await withServer(port: 18_803) { port in
      let (status, json) = try await post(
        port: port,
        body: [
          "jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:],
            "clientInfo": ["name": "LegacySDK", "version": "1.30.0"],
          ],
        ])
      #expect(status == 200)
      #expect(json?["result"]?["protocolVersion"] == .string("2025-11-25"))
      // The handshake era must not be handed the stateless revision's envelope.
      #expect(json?["result"]?["resultType"] == nil)
    }
  }

  @Test("No token is 401")
  func unauthorized() async throws {
    try await withServer(port: 18_804) { port in
      let (status, _) = try await post(
        port: port, body: modernFrame(method: "tools/list"),
        headers: modernHeaders(method: "tools/list"), token: nil)
      #expect(status == 401)
    }
  }

  /// Real agents send no Origin. If the check were "must be present and loopback" rather
  /// than "if present, loopback", every genuine client would get a 403.
  @Test("No Origin header is fine; a foreign one is 403")
  func originHandling() async throws {
    try await withServer(port: 18_805) { port in
      let (ok, _) = try await post(
        port: port, body: modernFrame(method: "tools/list"),
        headers: modernHeaders(method: "tools/list"))
      #expect(ok == 200)

      let (refused, _) = try await post(
        port: port, body: modernFrame(method: "tools/list"),
        headers: modernHeaders(method: "tools/list").merging(
          ["Origin": "https://evil.example.com"]) { _, new in new })
      #expect(refused == 403)
    }
  }

  @Test("GET on the endpoint is 405, not 404")
  func getIs405() async throws {
    try await withServer(port: 18_806) { port in
      let (status, _) = try await post(
        port: port, body: .object([:]), method: "GET")
      #expect(status == 405)
    }
  }

  @Test("A header that contradicts the body is refused with -32020")
  func headerMismatchOverTheWire() async throws {
    try await withServer(port: 18_807) { port in
      let (status, json) = try await post(
        port: port, body: modernFrame(method: "tools/call", name: "read_thing"),
        headers: modernHeaders(method: "tools/call", name: "write_thing"))
      #expect(status == 400)
      #expect(json?["error"]?["code"] == .int(-32020))
    }
  }

  @Test("The write gate hides and refuses over the wire")
  func writeGateOverTheWire() async throws {
    try await withServer(port: 18_808, allowWrites: false) { port in
      let (_, listing) = try await post(
        port: port, body: modernFrame(method: "tools/list"),
        headers: modernHeaders(method: "tools/list"))
      let names = try #require(listing?["result"]?["tools"]?.arrayValue).map { $0["name"] }
      #expect(!names.contains(.string("write_thing")))

      let (status, called) = try await post(
        port: port, body: modernFrame(method: "tools/call", name: "write_thing"),
        headers: modernHeaders(method: "tools/call", name: "write_thing"))
      // A tool error, not a transport error: the model can read it and tell the user which
      // switch to flip.
      #expect(status == 200)
      #expect(called?["result"]?["isError"] == .bool(true))
    }
    try await withServer(port: 18_809, allowWrites: true) { port in
      let (_, listing) = try await post(
        port: port, body: modernFrame(method: "tools/list"),
        headers: modernHeaders(method: "tools/list"))
      #expect(try #require(listing?["result"]?["tools"]?.arrayValue).count == 2)
    }
  }

  @Test("Concurrent requests are all answered")
  func concurrency() async throws {
    try await withServer(port: 18_810) { port in
      try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<12 {
          group.addTask {
            try await self.post(
              port: port, body: self.modernFrame(method: "tools/list"),
              headers: self.modernHeaders(method: "tools/list")
            ).status
          }
        }
        for try await status in group { #expect(status == 200) }
      }
    }
  }
}
