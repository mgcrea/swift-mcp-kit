import Foundation

/// Who is calling. Advisory in every era — never an authorisation input.
public struct ClientInfo: Sendable, Hashable, Codable {
  public let name: String
  public let version: String?
  public let title: String?

  public init(name: String, version: String? = nil, title: String? = nil) {
    self.name = name
    self.version = version
    self.title = title
  }
}

/// One incoming call, with the era already resolved.
///
/// The point of this type is that a handler never has to ask which revision it is serving.
/// A legacy `initialize` and a stateless `tools/call` arrive here in the same shape, and
/// the only thing that still varies downstream is how the *result* is rendered.
public struct MCPRequest: Sendable, Hashable {
  /// `nil` for a notification, which is the one thing that must not be answered.
  public let id: JSONValue?
  public let method: String
  /// Always an object, `[:]` when the frame carried none.
  public let params: JSONValue
  public let version: MCPVersion
  public let clientInfo: ClientInfo?
  public let clientCapabilities: JSONValue

  public var isNotification: Bool { id == nil }

  /// The `name` (or, for `resources/read`, the `uri`) this call addresses, if any.
  ///
  /// This is the value `Mcp-Name` mirrors, and it is worth having one spelling of it: the
  /// header validation and the tool dispatch must agree about which field it is, or a call
  /// could pass validation against one field and execute against another.
  public var addressedName: String? {
    switch method {
    case "tools/call", "prompts/get": params["name"]?.stringValue
    case "resources/read": params["uri"]?.stringValue
    default: nil
    }
  }

  public var arguments: JSONValue { params["arguments"] ?? .object([:]) }

  init(
    id: JSONValue?, method: String, params: JSONValue, version: MCPVersion,
    clientInfo: ClientInfo?, clientCapabilities: JSONValue
  ) {
    self.id = id
    self.method = method
    self.params = params
    self.version = version
    self.clientInfo = clientInfo
    self.clientCapabilities = clientCapabilities
  }
}
