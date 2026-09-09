import Foundation

/// The JSON-RPC error codes this package emits.
///
/// The `-32020` block is the range the specification reserved for itself once the
/// implementation-defined `-32000…-32019` had been spent; the three codes below were
/// renumbered into it and should not be spelled with their draft values.
public enum MCPErrorCode: Int, Sendable, Hashable {
  case parseError = -32700
  case invalidRequest = -32600
  case methodNotFound = -32601
  case invalidParams = -32602
  case internalError = -32603

  /// Headers and body disagree, or a required header is missing or malformed.
  case headerMismatch = -32020
  case missingRequiredClientCapability = -32021
  case unsupportedProtocolVersion = -32022
}

/// A refusal, carrying both halves: what HTTP says and what JSON-RPC says.
///
/// Both are needed and neither is derivable from the other. A client deciding whether a
/// server is modern or legacy inspects the *body* of a `400`, because a modern server uses
/// `400` for three different well-formed errors — so a status code alone would send it
/// falling back to a handshake it did not need.
public struct MCPFault: Sendable, Hashable, Error {
  public let httpStatus: Int
  public let code: MCPErrorCode
  public let message: String
  public let data: JSONValue?
  /// Echoed back so the client can match the error to its request. `nil` for a frame so
  /// malformed that no id could be read out of it.
  public let id: JSONValue?

  public init(
    httpStatus: Int, code: MCPErrorCode, message: String, data: JSONValue? = nil,
    id: JSONValue? = nil
  ) {
    self.httpStatus = httpStatus
    self.code = code
    self.message = message
    self.data = data
    self.id = id
  }

  /// The JSON-RPC error response body.
  public var frame: JSONValue {
    var error: [String: JSONValue] = ["code": .int(code.rawValue), "message": .string(message)]
    if let data { error["data"] = data }
    return .object(["jsonrpc": "2.0", "id": id ?? .null, "error": .object(error)])
  }

  // MARK: - The refusals this package makes

  static func parseError(_ detail: String) -> MCPFault {
    MCPFault(httpStatus: 400, code: .parseError, message: "Could not parse JSON: \(detail)")
  }

  static func invalidRequest(_ detail: String, id: JSONValue? = nil) -> MCPFault {
    MCPFault(httpStatus: 400, code: .invalidRequest, message: detail, id: id)
  }

  static func methodNotFound(_ method: String, id: JSONValue?) -> MCPFault {
    MCPFault(
      httpStatus: 404, code: .methodNotFound, message: "No such method: '\(method)'.", id: id)
  }

  static func headerMismatch(_ detail: String, id: JSONValue? = nil) -> MCPFault {
    MCPFault(httpStatus: 400, code: .headerMismatch, message: detail, id: id)
  }

  static func unsupportedVersion(_ requested: String?, id: JSONValue? = nil) -> MCPFault {
    let asked = requested.map { "'\($0)'" } ?? "an unstated version"
    return MCPFault(
      httpStatus: 400, code: .unsupportedProtocolVersion,
      message: "This server does not implement \(asked).",
      data: .object([
        "supported": .array(MCPVersion.supported.map { .string($0.rawValue) })
      ]),
      id: id)
  }
}
