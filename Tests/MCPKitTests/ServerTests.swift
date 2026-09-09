import Foundation
import Testing

@testable import MCPKit

@Suite("MCPServer")
struct ServerTests {

  private func server() -> MCPServer {
    var tools = ToolTable()
    tools.add(MCPTool(name: "read_thing", description: "Reads.", annotations: .readOnly)) { _ in
      .answer("one row", ["rows": 1])
    }
    tools.add(
      MCPTool(
        name: "write_thing", description: "Writes.", gate: .requiresWrites,
        annotations: .mutating(destructive: false))
    ) { _ in .text("wrote") }
    return MCPServer(
      info: ServerInfo(name: "TestServer", version: "1.0.0"),
      instructions: "Numbers are UTC.", tools: tools)
  }

  private func request(
    _ method: String, version: MCPVersion = .v20260728, params: JSONValue = .object([:])
  ) -> MCPRequest {
    MCPRequest(
      id: .int(1), method: method, params: params, version: version,
      clientInfo: ClientInfo(name: "T", version: "1"), clientCapabilities: .object([:]))
  }

  // MARK: - Discovery, both eras

  /// The stateless revision made `server/discover` mandatory: with no handshake there is
  /// nowhere else to state what the server is or which versions it accepts.
  @Test("server/discover reports identity and every supported version")
  func discover() async throws {
    let response = await server().respond(to: request("server/discover"), allowWrites: false)
    let result = try #require(response.body?["result"])
    #expect(result["serverInfo"]?["name"] == .string("TestServer"))
    let versions = try #require(result["protocolVersions"]?.arrayValue)
    #expect(versions.first == .string("2026-07-28"))
    #expect(versions.contains(.string("2025-11-25")))
    #expect(result["capabilities"]?["tools"] != nil)
  }

  @Test("initialize echoes the version the client asked for")
  func initializeEchoes() async throws {
    let response = await server().respond(
      to: request(
        "initialize", version: .v20251125, params: ["protocolVersion": "2025-11-25"]),
      allowWrites: false)
    let result = try #require(response.body?["result"])
    #expect(result["protocolVersion"] == .string("2025-11-25"))
    #expect(result["serverInfo"]?["name"] == .string("TestServer"))
    #expect(result["instructions"] == .string("Numbers are UTC."))
  }

  /// One long-lived server answers every editor on the machine. A handshake that could only
  /// happen once would mean the second client to connect is refused for having arrived
  /// second — the bug the SDK's own guarded default has.
  @Test("initialize is idempotent across independent clients")
  func initializeIsIdempotent() async throws {
    let server = server()
    for _ in 0..<3 {
      let response = await server.respond(
        to: request(
          "initialize", version: .v20251125, params: ["protocolVersion": "2025-11-25"]),
        allowWrites: false)
      #expect(response.body?["result"] != nil)
      #expect(response.body?["error"] == nil)
    }
  }

  // MARK: - Stateless envelope

  @Test("A stateless result carries resultType and serverInfo")
  func statelessEnvelope() async throws {
    let response = await server().respond(to: request("tools/list"), allowWrites: false)
    let result = try #require(response.body?["result"])
    #expect(result["resultType"] == .string("complete"))
    #expect(
      result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == .string("TestServer"))
  }

  /// Those two fields belong to the stateless revision. Emitting them to a handshake-era
  /// client would be inventing a field its schema does not have.
  @Test("A handshake-era result carries neither resultType nor cache fields")
  func handshakeEnvelope() async throws {
    let response = await server().respond(
      to: request("tools/list", version: .v20251125), allowWrites: false)
    let result = try #require(response.body?["result"])
    #expect(result["resultType"] == nil)
    #expect(result["ttlMs"] == nil)
    #expect(result["tools"] != nil)
  }

  @Test("tools/list is cacheable and private to this install")
  func listingIsCacheable() async throws {
    let response = await server().respond(to: request("tools/list"), allowWrites: false)
    let result = try #require(response.body?["result"])
    #expect(result["ttlMs"]?.intValue != nil)
    // The listing varies with a toggle only this user can see, so a shared intermediary
    // must never hand one user's listing to another.
    #expect(result["cacheScope"] == .string("private"))
  }

  // MARK: - The gate, end to end

  @Test("The listing honours the write gate")
  func listingHonoursGate() async throws {
    let off = await server().respond(to: request("tools/list"), allowWrites: false)
    let names = try #require(off.body?["result"]?["tools"]?.arrayValue).map { $0["name"] }
    #expect(names.contains(.string("read_thing")))
    #expect(!names.contains(.string("write_thing")))

    let on = await server().respond(to: request("tools/list"), allowWrites: true)
    #expect(try #require(on.body?["result"]?["tools"]?.arrayValue).count == 2)
  }

  @Test("A gated call is refused as a tool error, not a transport error")
  func gatedCallIsToolError() async throws {
    let response = await server().respond(
      to: request("tools/call", params: ["name": "write_thing", "arguments": [:]]),
      allowWrites: false)
    #expect(response.httpStatus == 200)
    // A JSON-RPC error would tell the model the transport failed; this tells it why.
    #expect(response.body?["error"] == nil)
    let result = try #require(response.body?["result"])
    #expect(result["isError"] == .bool(true))
  }

  @Test("A successful call returns structured content")
  func callReturnsStructured() async throws {
    let response = await server().respond(
      to: request("tools/call", params: ["name": "read_thing", "arguments": [:]]),
      allowWrites: false)
    let result = try #require(response.body?["result"])
    #expect(result["structuredContent"]?["rows"] == .int(1))
    #expect(result["isError"] == .bool(false))
  }

  /// 2025-06-18 clients do not read `structuredContent`, so for them the same data has to
  /// travel as text or it does not arrive at all.
  @Test("The oldest era gets the payload serialized as text instead")
  func oldestEraGetsTextFallback() async throws {
    let response = await server().respond(
      to: request(
        "tools/call", version: .v20250618, params: ["name": "read_thing", "arguments": [:]]),
      allowWrites: false)
    let result = try #require(response.body?["result"])
    #expect(result["structuredContent"] == nil)
    let blocks = try #require(result["content"]?.arrayValue)
    #expect(blocks.count == 2)
    #expect(blocks.last?["text"]?.stringValue?.contains("\"rows\":1") == true)
  }

  // MARK: - Everything else

  @Test("A notification is accepted with no body")
  func notificationAccepted() async {
    let request = MCPRequest(
      id: nil, method: "notifications/initialized", params: .object([:]),
      version: .v20251125, clientInfo: nil, clientCapabilities: .object([:]))
    let response = await server().respond(to: request, allowWrites: false)
    #expect(response.httpStatus == 202)
    #expect(response.body == nil)
  }

  @Test("An unknown method is 404 with a method-not-found error")
  func unknownMethod() async throws {
    let response = await server().respond(to: request("tools/frobnicate"), allowWrites: false)
    #expect(response.httpStatus == 404)
    #expect(response.body?["error"]?["code"] == .int(-32601))
  }
}
