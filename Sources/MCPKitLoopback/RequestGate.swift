import Foundation
import MCPKit

/// What checking a bearer token concluded.
///
/// Three-valued on purpose. "I cannot tell you" is a different answer from "no", and
/// collapsing it into a refusal is how a locked Keychain gets reported to the user as a bad
/// credential — sending them to regenerate a token that was correct all along.
public enum TokenVerdict: Sendable, Hashable {
  /// Recognised. The name, when there is one, is for the audit line, never for access.
  case accepted(client: String?)
  case rejected
  /// The credential store could not be read at all.
  case unavailable
}

/// Compare two secrets without leaking where they first differ.
///
/// `==` on `String` returns as soon as it finds a difference, and the time that takes is a
/// measurement of how much of a guess was right. Over a loopback socket the signal is
/// small; it is not zero, and the fix is four lines.
public func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
  let left = Array(lhs.utf8)
  let right = Array(rhs.utf8)
  // The length is not secret — it is observable from the request anyway — so returning
  // early on it leaks nothing the caller did not already send.
  guard left.count == right.count else { return false }
  var difference: UInt8 = 0
  for index in left.indices { difference |= left[index] ^ right[index] }
  return difference == 0
}

/// Everything that must be true before a request is allowed to reach the protocol.
///
/// The order of the checks below is the security property, not the implementation:
///
/// 1. `Host` must be loopback — this is what closes DNS rebinding, where a page the user
///    visits resolves a name it controls to 127.0.0.1 and then speaks to this server.
/// 2. `Origin`, *if present*, must be loopback. Absent is allowed, because real MCP clients
///    are not browsers and send none; requiring it would refuse every genuine caller.
/// 3. Only then, the token.
///
/// Reversing 1 and 3 would make the refusal a measurement: a rebinding probe would learn
/// from the status code whether the token it guessed was valid.
public struct RequestGate: Sendable {

  let port: Int
  let endpoint: String
  let verify: @Sendable (String?) -> TokenVerdict

  public init(
    port: Int, endpoint: String = "/mcp", verify: @escaping @Sendable (String?) -> TokenVerdict
  ) {
    self.port = port
    self.endpoint = endpoint
    self.verify = verify
  }

  /// The refusal, or `nil` when the request may proceed.
  public func check(_ head: HTTPRequestHead) -> HTTPResponse? {
    if let refusal = checkHost(head) { return refusal }
    if let refusal = checkOrigin(head) { return refusal }
    if let refusal = checkRoute(head) { return refusal }
    return checkToken(head)
  }

  // MARK: - Steps

  private func checkHost(_ head: HTTPRequestHead) -> HTTPResponse? {
    // An absent Host is an HTTP/1.0 client, which is not an MCP client.
    guard let host = head.headers.trimmed("host"), Self.isLoopback(authority: host) else {
      return .fault(
        MCPFault(
          httpStatus: 403, code: .invalidRequest,
          message: "This server answers on loopback only."))
    }
    return nil
  }

  private func checkOrigin(_ head: HTTPRequestHead) -> HTTPResponse? {
    guard let origin = head.headers.trimmed("origin") else { return nil }
    let authority =
      origin
      .replacingOccurrences(of: "https://", with: "")
      .replacingOccurrences(of: "http://", with: "")
    guard Self.isLoopback(authority: authority) else {
      return .fault(
        MCPFault(
          httpStatus: 403, code: .invalidRequest,
          message: "Origin '\(origin)' is not permitted."))
    }
    return nil
  }

  private func checkRoute(_ head: HTTPRequestHead) -> HTTPResponse? {
    guard head.target == endpoint else {
      return .fault(
        MCPFault(
          httpStatus: 404, code: .methodNotFound,
          message: "No such path. The MCP endpoint is '\(endpoint)'."))
    }
    guard head.method == "POST" else {
      // 405, never 404. The stateless revision removed the GET stream and the DELETE that
      // ended a session, and a 404 here would send an older client hunting for the
      // deprecated HTTP+SSE endpoint instead of telling it the truth.
      return .fault(
        MCPFault(
          httpStatus: 405, code: .invalidRequest,
          message: "The MCP endpoint accepts POST only. Sessions and the GET stream were "
            + "removed in 2026-07-28."),
        extra: ["Allow": "POST"])
    }
    return nil
  }

  private func checkToken(_ head: HTTPRequestHead) -> HTTPResponse? {
    let presented = head.headers.trimmed("authorization").flatMap { header -> String? in
      let parts = header.split(separator: " ", maxSplits: 1)
      guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
      return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    switch verify(presented) {
    case .accepted:
      return nil
    case .unavailable:
      return .fault(
        MCPFault(
          httpStatus: 503, code: .internalError,
          message: "The credential store cannot be read right now. Unlock the keychain and "
            + "try again."),
        extra: ["Retry-After": "5"])
    case .rejected:
      // One sentence for "no token" and "wrong token" alike. An error that distinguished
      // them would confirm to a caller that a guess was well-formed, which is an oracle.
      return .fault(
        MCPFault(httpStatus: 401, code: .invalidRequest, message: "Unauthorized."),
        extra: ["WWW-Authenticate": "Bearer"])
    }
  }

  // MARK: - Loopback

  /// Whether an `authority` (`host` or `host:port`) names this machine.
  ///
  /// Names as well as literals, because `localhost` is what a person types and what several
  /// clients write into their config. A name that merely *resolves* to 127.0.0.1 is not
  /// accepted — that is exactly the rebinding attack.
  static func isLoopback(authority: String) -> Bool {
    var host = authority
    if host.hasPrefix("[") {
      // A bracketed IPv6 literal, with or without a port: [::1] or [::1]:8788.
      guard let close = host.firstIndex(of: "]") else { return false }
      host = String(host[host.index(after: host.startIndex)..<close])
    } else if let colon = host.lastIndex(of: ":") {
      host = String(host[..<colon])
    }
    host = host.trimmingCharacters(in: .whitespaces).lowercased()
    return host == "127.0.0.1" || host == "localhost" || host == "::1"
  }
}
