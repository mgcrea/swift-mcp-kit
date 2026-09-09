import Foundation

/// What the server calls itself.
public struct ServerInfo: Sendable, Hashable {
  public let name: String
  public let version: String
  public let title: String?

  public init(name: String, version: String, title: String? = nil) {
    self.name = name
    self.version = version
    self.title = title
  }

  var json: JSONValue {
    var fields: [String: JSONValue] = ["name": .string(name), "version": .string(version)]
    if let title { fields["title"] = .string(title) }
    return .object(fields)
  }
}

/// One answer: the HTTP status, and the body when there is one.
public struct MCPResponse: Sendable, Hashable {
  public let httpStatus: Int
  /// `nil` for the `202` a notification gets, which must have no body at all.
  public let body: JSONValue?

  public init(httpStatus: Int, body: JSONValue?) {
    self.httpStatus = httpStatus
    self.body = body
  }
}

/// The protocol, over a tool table. Knows nothing about sockets.
///
/// Everything here is a pure function of the request and the write toggle, which is what
/// makes the conformance suite offline and total: there is no order of calls that can put
/// this type into a state, because it does not have one. That is not an accident of the
/// implementation — it is the stateless revision's central claim, and building the server
/// as a value is how the claim gets checked.
public struct MCPServer: Sendable {

  public let info: ServerInfo
  /// Said once, to the client, rather than repeated in every tool description. The right
  /// home for cross-cutting semantics: what a null means, which derivations are unsound.
  public let instructions: String?
  public var tools: ToolTable

  /// How long a client may cache `tools/list`.
  ///
  /// A minute. The listing changes only when a human moves the write toggle, and a client
  /// that re-reads it a minute later is not a cost worth optimising against — while a long
  /// TTL would leave a model planning against tools that have since been switched off.
  public static let listingTTL = 60_000

  public init(info: ServerInfo, instructions: String? = nil, tools: ToolTable) {
    self.info = info
    self.instructions = instructions
    self.tools = tools
  }

  public var capabilities: JSONValue {
    .object(["tools": .object(["listChanged": .bool(true)])])
  }

  public func respond(to request: MCPRequest, allowWrites: Bool) async -> MCPResponse {
    // A notification is acknowledged and never answered. Returning a body here would be a
    // JSON-RPC response to something that carried no id to match it against.
    guard !request.isNotification else { return MCPResponse(httpStatus: 202, body: nil) }

    switch request.method {
    case "server/discover":
      return complete(discovery, for: request)

    case "initialize":
      // Idempotent, deliberately. One server answers every editor on the machine for the
      // whole life of the app, so a guard that allowed this once would refuse the second
      // client for no reason except that it arrived second.
      return complete(initializeResult(for: request), for: request)

    case "tools/list":
      let listing: JSONValue = .object([
        "tools": .array(tools.listing(allowWrites: allowWrites).map(\.json))
      ])
      return complete(cacheable(listing, for: request), for: request)

    case "tools/call":
      guard let name = request.addressedName else {
        return fault(.invalidRequest("'tools/call' needs a 'name'.", id: request.id))
      }
      let result = await tools.call(
        name: name, arguments: request.arguments, allowWrites: allowWrites)
      return complete(result.json(for: request.version), for: request)

    default:
      return fault(.methodNotFound(request.method, id: request.id))
    }
  }

  // MARK: - Results

  private var discovery: JSONValue {
    .object([
      "protocolVersions": .array(MCPVersion.supported.map { .string($0.rawValue) }),
      "capabilities": capabilities,
      "serverInfo": info.json,
    ])
  }

  private func initializeResult(for request: MCPRequest) -> JSONValue {
    var fields: [String: JSONValue] = [
      // Echo what the client asked for. `Dialect` has already refused anything unsupported,
      // so by here the requested version is one this server speaks.
      "protocolVersion": .string(request.version.rawValue),
      "capabilities": capabilities,
      "serverInfo": info.json,
    ]
    if let instructions { fields["instructions"] = .string(instructions) }
    return .object(fields)
  }

  /// Add the freshness hints the stateless revision requires on list results.
  private func cacheable(_ result: JSONValue, for request: MCPRequest) -> JSONValue {
    guard request.version.era == .stateless else { return result }
    return result.merging([
      "ttlMs": .int(Self.listingTTL),
      // Never `public`. What is listed depends on a toggle belonging to one install, so a
      // shared intermediary handing one user's listing to another would be handing over a
      // capability, not a cache hit.
      "cacheScope": "private",
    ])
  }

  /// Wrap a result in the JSON-RPC envelope, adding the era's own fields.
  private func complete(_ result: JSONValue, for request: MCPRequest) -> MCPResponse {
    var payload = result
    if request.version.era == .stateless {
      payload = payload.merging([
        "resultType": "complete",
        "_meta": .object([Dialect.MetaKey.serverInfo: info.json]),
      ])
    }
    return MCPResponse(
      httpStatus: 200,
      body: .object(["jsonrpc": "2.0", "id": request.id ?? .null, "result": payload]))
  }

  private func fault(_ fault: MCPFault) -> MCPResponse {
    MCPResponse(httpStatus: fault.httpStatus, body: fault.frame)
  }
}
