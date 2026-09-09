import Foundation
import Testing

@testable import MCPKit

@Suite("Dialect")
struct DialectTests {

  // MARK: - Helpers

  /// A well-formed 2026-07-28 frame: the `_meta` block and the three headers that must
  /// agree with it.
  private func modern(
    method: String, name: String? = nil, id: JSONValue? = 1,
    version: String = "2026-07-28", overrideHeaders: [String: String] = [:]
  ) -> (HTTPHeaders, Data) {
    var params: [String: JSONValue] = [
      "_meta": [
        "io.modelcontextprotocol/protocolVersion": .string(version),
        "io.modelcontextprotocol/clientInfo": ["name": "TestClient", "version": "1.0.0"],
        "io.modelcontextprotocol/clientCapabilities": [:],
      ]
    ]
    if let name { params["name"] = .string(name) }
    var body: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
    if let id { body["id"] = id }
    body["params"] = .object(params)

    var fields = ["mcp-protocol-version": version, "mcp-method": method]
    if let name { fields["mcp-name"] = name }
    for (key, value) in overrideHeaders { fields[key] = value }
    // An empty override value means "omit this header entirely".
    fields = fields.filter { !$0.value.isEmpty }
    return (HTTPHeaders(fields), try! JSONEncoder().encode(JSONValue.object(body)))
  }

  /// A legacy `initialize`, exactly as an SDK 1.x client sends it: no headers at all.
  private func legacyInitialize(version: String = "2025-11-25") -> (HTTPHeaders, Data) {
    let body: JSONValue = [
      "jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": [
        "protocolVersion": .string(version),
        "capabilities": [:],
        "clientInfo": ["name": "LegacyClient", "version": "1.0.0"],
      ],
    ]
    return (HTTPHeaders([:]), try! JSONEncoder().encode(body))
  }

  // MARK: - Era detection

  @Test("A modern frame parses as the stateless era")
  func modernFrameIsStateless() throws {
    let (headers, body) = modern(method: "tools/call", name: "do_thing")
    let request = try Dialect.parse(headers: headers, body: body).get()
    #expect(request.version == .v20260728)
    #expect(request.version.era == .stateless)
    #expect(request.method == "tools/call")
    #expect(request.clientInfo?.name == "TestClient")
  }

  @Test("A legacy initialize parses as the handshake era and carries its version")
  func legacyInitializeIsHandshake() throws {
    let (headers, body) = legacyInitialize()
    let request = try Dialect.parse(headers: headers, body: body).get()
    #expect(request.version == .v20251125)
    #expect(request.version.era == .handshake)
    #expect(request.clientInfo?.name == "LegacyClient")
  }

  /// The reason dual-era exists at all: the SDK the fleet's own servers ship on is 1.30.0,
  /// whose latest is 2025-11-25. A 2026-07-28-only server is unusable with today's clients.
  @Test("Every supported version is accepted", arguments: MCPVersion.allCases)
  func everySupportedVersion(_ version: MCPVersion) throws {
    let (headers, body) =
      version.era == .stateless
      ? modern(method: "tools/list", version: version.rawValue)
      : legacyInitialize(version: version.rawValue)
    let request = try Dialect.parse(headers: headers, body: body).get()
    #expect(request.version == version)
  }

  // MARK: - Version negotiation

  @Test("An unknown protocol version is refused with the supported list")
  func unknownVersion() throws {
    let (headers, body) = modern(method: "tools/list", version: "2024-11-05")
    let fault = try #require(Dialect.parse(headers: headers, body: body).failure)
    #expect(fault.code == .unsupportedProtocolVersion)
    #expect(fault.httpStatus == 400)
    let supported = try #require(fault.data?["supported"]?.arrayValue)
    #expect(supported.contains(.string("2026-07-28")))
    #expect(supported.contains(.string("2025-11-25")))
  }

  /// The header and the `_meta` field are two spellings of one fact. When they disagree a
  /// gateway routing on the header and a server executing on the body would act on
  /// different values, which is the vulnerability the rule exists to close.
  @Test("A protocol version header that contradicts the body is a header mismatch")
  func versionHeaderContradictsBody() throws {
    let (headers, body) = modern(
      method: "tools/list", overrideHeaders: ["mcp-protocol-version": "2025-11-25"])
    let fault = try #require(Dialect.parse(headers: headers, body: body).failure)
    #expect(fault.code == .headerMismatch)
    #expect(fault.httpStatus == 400)
  }

  // MARK: - Header validation, stateless era only

  @Test("Mcp-Method must match the body method")
  func methodHeaderMismatch() throws {
    let (headers, body) = modern(
      method: "tools/call", name: "do_thing", overrideHeaders: ["mcp-method": "tools/list"])
    let fault = try #require(Dialect.parse(headers: headers, body: body).failure)
    #expect(fault.code == .headerMismatch)
  }

  @Test("Mcp-Name must match the tool named in the body")
  func nameHeaderMismatch() throws {
    let (headers, body) = modern(
      method: "tools/call", name: "do_thing", overrideHeaders: ["mcp-name": "other_thing"])
    let fault = try #require(Dialect.parse(headers: headers, body: body).failure)
    #expect(fault.code == .headerMismatch)
  }

  @Test("A missing required header is a header mismatch, not a parse error")
  func missingRequiredHeader() throws {
    let (headers, body) = modern(
      method: "tools/call", name: "do_thing", overrideHeaders: ["mcp-name": ""])
    let fault = try #require(Dialect.parse(headers: headers, body: body).failure)
    #expect(fault.code == .headerMismatch)
  }

  /// Tool names are only SHOULD-constrained to header-safe characters, so a name outside
  /// that set travels base64-wrapped in the sentinel. The server has to decode before
  /// comparing, or every such call would be refused as a mismatch against itself.
  @Test("A base64-sentinel Mcp-Name is decoded before comparison")
  func base64SentinelName() throws {
    let name = "outil_créé"
    let encoded = "=?base64?\(Data(name.utf8).base64EncodedString())?="
    let (headers, body) = modern(
      method: "tools/call", name: name, overrideHeaders: ["mcp-name": encoded])
    let request = try Dialect.parse(headers: headers, body: body).get()
    #expect(request.params["name"]?.stringValue == name)
  }

  /// The handshake era predates these headers. Requiring them would refuse every real
  /// client in existence today.
  @Test("The handshake era does not require the mirrored headers")
  func handshakeEraSkipsHeaderValidation() throws {
    let body: JSONValue = [
      "jsonrpc": "2.0", "id": 2, "method": "tools/call",
      "params": ["name": "do_thing", "arguments": [:]],
    ]
    let headers = HTTPHeaders(["mcp-protocol-version": "2025-11-25"])
    let request = try Dialect.parse(
      headers: headers, body: try JSONEncoder().encode(body)
    ).get()
    #expect(request.version == .v20251125)
    #expect(request.method == "tools/call")
  }

  // MARK: - Method routing across eras

  /// `initialize` was removed by the stateless revision. A client claiming 2026-07-28 and
  /// then sending it is confused about which protocol it speaks, and the answer that says
  /// so is "no such method".
  @Test("A stateless frame naming initialize is method-not-found")
  func statelessInitializeIsMethodNotFound() throws {
    let (headers, body) = modern(method: "initialize")
    let fault = try #require(Dialect.parse(headers: headers, body: body).failure)
    #expect(fault.code == .methodNotFound)
    #expect(fault.httpStatus == 404)
  }

  @Test("A notification is recognised as one and carries no id")
  func notification() throws {
    let body: JSONValue = ["jsonrpc": "2.0", "method": "notifications/initialized"]
    let headers = HTTPHeaders(["mcp-protocol-version": "2025-11-25"])
    let request = try Dialect.parse(
      headers: headers, body: try JSONEncoder().encode(body)
    ).get()
    #expect(request.isNotification)
    #expect(request.id == nil)
  }

  // MARK: - Malformed input

  @Test("A body that is not JSON is a parse error")
  func notJSON() throws {
    let fault = try #require(
      Dialect.parse(headers: HTTPHeaders([:]), body: Data("{oops".utf8)).failure)
    #expect(fault.code == .parseError)
  }

  @Test("A frame with no method is an invalid request")
  func noMethod() throws {
    let body: JSONValue = ["jsonrpc": "2.0", "id": 1]
    let fault = try #require(
      Dialect.parse(headers: HTTPHeaders([:]), body: try JSONEncoder().encode(body)).failure)
    #expect(fault.code == .invalidRequest)
  }
}

extension Result {
  /// The failure, for a test that expects one. `try #require(...)` on this reads better
  /// than a `case .failure` dance at every call site.
  var failure: Failure? {
    guard case .failure(let error) = self else { return nil }
    return error
  }
}
