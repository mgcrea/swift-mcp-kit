import Foundation

/// Reading a frame from either era of the protocol, and saying no precisely when it is wrong.
///
/// One endpoint answers three revisions. The alternative — two endpoints, or a server that
/// picks an era at startup — fails the case that actually happens: two editors on one
/// machine, one of them a version behind, both pointed at the same URL.
///
/// Everything here is a pure function over headers and bytes. Nothing binds, reads a clock
/// or touches a store, which is what lets the whole specification-conformance suite run
/// offline on any platform.
public enum Dialect {

  /// Keys the stateless era carries in `params._meta`.
  enum MetaKey {
    static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
    static let clientInfo = "io.modelcontextprotocol/clientInfo"
    static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfo = "io.modelcontextprotocol/serverInfo"
  }

  /// Methods the stateless revision removed. Naming one while claiming `2026-07-28` is a
  /// client confused about which protocol it is speaking.
  static let handshakeOnlyMethods: Set<String> = [
    "initialize", "notifications/initialized", "ping", "logging/setLevel",
    "resources/subscribe", "resources/unsubscribe",
  ]

  /// Parse one request frame.
  ///
  /// The order below is load-bearing. The version is settled *first*, because which
  /// validation rules apply at all depends on the era — requiring `Mcp-Method` of a
  /// handshake-era client would refuse every real client shipping today.
  public static func parse(headers: HTTPHeaders, body: Data) -> Result<MCPRequest, MCPFault> {
    let frame: JSONValue
    do {
      frame = try JSONDecoder().decode(JSONValue.self, from: body)
    } catch {
      return .failure(.parseError(error.localizedDescription))
    }

    let id = frame["id"]
    guard let method = frame["method"]?.stringValue, !method.isEmpty else {
      return .failure(.invalidRequest("A request must carry a 'method'.", id: id))
    }
    let params = frame["params"] ?? .object([:])
    guard params.objectValue != nil else {
      return .failure(.invalidRequest("'params' must be an object.", id: id))
    }

    let version: MCPVersion
    switch resolveVersion(headers: headers, method: method, params: params, id: id) {
    case .success(let resolved): version = resolved
    case .failure(let fault): return .failure(fault)
    }

    if version.era == .stateless {
      if handshakeOnlyMethods.contains(method) {
        return .failure(.methodNotFound(method, id: id))
      }
      if let fault = validateMirroredHeaders(
        headers: headers, method: method, params: params, id: id)
      {
        return .failure(fault)
      }
    }

    let meta = params["_meta"]
    return .success(
      MCPRequest(
        id: id, method: method, params: params, version: version,
        clientInfo: readClientInfo(params: params, meta: meta),
        clientCapabilities: meta?[MetaKey.clientCapabilities]
          ?? params["capabilities"] ?? .object([:])))
  }

  // MARK: - Version

  private static func resolveVersion(
    headers: HTTPHeaders, method: String, params: JSONValue, id: JSONValue?
  ) -> Result<MCPVersion, MCPFault> {
    let headerValue = headers.trimmed("mcp-protocol-version")
    let metaValue = params["_meta"]?[MetaKey.protocolVersion]?.stringValue

    // The stateless era states its version in the body, and the header must agree. Two
    // spellings of one fact are a vulnerability the moment they can disagree: a gateway
    // routing on the header and a server executing on the body would act on different
    // values.
    if let metaValue {
      if let headerValue, headerValue != metaValue {
        return .failure(
          .headerMismatch(
            "MCP-Protocol-Version header '\(headerValue)' does not match the "
              + "'\(MetaKey.protocolVersion)' in the request body ('\(metaValue)').", id: id))
      }
      return known(metaValue, id: id)
    }

    // A handshake-era client sends `initialize` before it has a negotiated version to put
    // in a header, so the only statement of intent is in the body.
    if method == "initialize", let asked = params["protocolVersion"]?.stringValue {
      return known(asked, id: id)
    }

    if let headerValue { return known(headerValue, id: id) }

    // Nothing said anything. A notification is answered with `202` and no body whatever we
    // decide, so refusing one over a missing header would be pedantry with no reader.
    if id == nil { return .success(.latestHandshake) }

    return .failure(.unsupportedVersion(nil, id: id))
  }

  private static func known(_ raw: String, id: JSONValue?) -> Result<MCPVersion, MCPFault> {
    guard let version = MCPVersion(rawValue: raw) else {
      return .failure(.unsupportedVersion(raw, id: id))
    }
    return .success(version)
  }

  // MARK: - Mirrored headers

  /// `Mcp-Method` and `Mcp-Name` mirror body fields so an intermediary can route without
  /// parsing the body. A server that also parses the body must check they agree, or the two
  /// halves of the system can be made to act on different values.
  private static func validateMirroredHeaders(
    headers: HTTPHeaders, method: String, params: JSONValue, id: JSONValue?
  ) -> MCPFault? {
    guard headers.trimmed("mcp-protocol-version") != nil else {
      return .headerMismatch("The MCP-Protocol-Version header is required.", id: id)
    }
    guard let headerMethod = headers.trimmed("mcp-method") else {
      return .headerMismatch("The Mcp-Method header is required.", id: id)
    }
    guard headerMethod == method else {
      return .headerMismatch(
        "Mcp-Method header '\(headerMethod)' does not match the body method '\(method)'.",
        id: id)
    }

    // Only three methods address something by name; the rest must not carry the header and
    // are not checked for it.
    let field = method == "resources/read" ? "uri" : "name"
    guard ["tools/call", "resources/read", "prompts/get"].contains(method),
      let bodyName = params[field]?.stringValue
    else { return nil }

    guard let rawHeaderName = headers.trimmed("mcp-name") else {
      return .headerMismatch("The Mcp-Name header is required for '\(method)'.", id: id)
    }
    guard let headerName = decodeSentinel(rawHeaderName) else {
      return .headerMismatch("The Mcp-Name header is not valid base64.", id: id)
    }
    guard headerName == bodyName else {
      return .headerMismatch(
        "Mcp-Name header '\(headerName)' does not match the body value '\(bodyName)'.", id: id)
    }
    return nil
  }

  /// Undo the `=?base64?…?=` wrapper a client uses for a value that cannot travel as plain
  /// ASCII. Returns the value unchanged when it is not wrapped, and `nil` when it is wrapped
  /// around something that is not decodable.
  static func decodeSentinel(_ value: String) -> String? {
    let prefix = "=?base64?"
    let suffix = "?="
    guard value.hasPrefix(prefix), value.hasSuffix(suffix),
      value.count > prefix.count + suffix.count
    else { return value }
    let encoded = String(value.dropFirst(prefix.count).dropLast(suffix.count))
    guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8)
    else { return nil }
    return decoded
  }

  private static func readClientInfo(params: JSONValue, meta: JSONValue?) -> ClientInfo? {
    // The stateless era puts it in `_meta` on every request; the handshake era puts it in
    // `initialize` params once. Same fact, two homes.
    let source = meta?[MetaKey.clientInfo] ?? params["clientInfo"]
    guard let name = source?["name"]?.stringValue else { return nil }
    return ClientInfo(
      name: name, version: source?["version"]?.stringValue,
      title: source?["title"]?.stringValue)
  }
}
