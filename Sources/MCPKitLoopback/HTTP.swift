import Foundation
import MCPKit

/// A parsed request line plus headers.
public struct HTTPRequestHead: Sendable, Hashable {
  public let method: String
  /// The path, with any query string removed.
  public let target: String
  public let headers: HTTPHeaders

  public init(method: String, target: String, headers: HTTPHeaders) {
    self.method = method
    self.target = target
    self.headers = headers
  }
}

/// A response to write back.
///
/// `Error` so a refusal can travel as the failure half of a `Result` — a refusal *is* the
/// answer in that case, and wrapping it in a second type to satisfy the protocol would add
/// a layer that only ever holds one thing.
public struct HTTPResponse: Sendable, Hashable, Error {
  public let status: Int
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  /// A refusal carrying a JSON-RPC error body.
  ///
  /// The body is not decoration. A client deciding whether this server is modern or legacy
  /// inspects the body of a `400`, and falls back to a handshake only when it does *not*
  /// find a recognised JSON-RPC error — so a bare status here would send a perfectly modern
  /// client down the legacy path.
  static func fault(_ fault: MCPFault, extra: [String: String] = [:]) -> HTTPResponse {
    let body = MCPJSON.data(fault.frame)
    return HTTPResponse(
      status: fault.httpStatus,
      headers: ["Content-Type": "application/json"].merging(extra) { _, new in new },
      body: body)
  }

  public var serialized: Data {
    var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
    var fields = headers
    fields["Content-Length"] = String(body.count)
    // Every response closes its connection. Keep-alive would buy a round trip on a socket
    // that carries one request per agent turn, in exchange for owning connection reuse.
    fields["Connection"] = "close"
    for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
      text += "\(name): \(value)\r\n"
    }
    text += "\r\n"
    return Data(text.utf8) + body
  }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 202: "Accepted"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 413: "Payload Too Large"
    case 500: "Internal Server Error"
    case 503: "Service Unavailable"
    default: "Status"
    }
  }
}

/// Just enough HTTP/1.1 to serve one JSON-RPC endpoint on loopback.
///
/// Hand-written rather than swift-nio, and the reason is the dependency rather than the
/// code: a package meant to be embedded in a sandboxed App Store app should not drag a
/// networking stack in to read a request line and a `Content-Length`. What it does *not*
/// support is as deliberate as what it does — no chunked encoding, no keep-alive, no
/// pipelining, no upgrade. A loopback client sending any of those is not a client this
/// server has.
public enum HTTPParser {

  /// The largest body accepted, before reading it.
  ///
  /// Checked against the declared `Content-Length` rather than by accumulating, so an
  /// absurd declaration costs nothing to refuse.
  public static let maxBodyBytes = 4 * 1024 * 1024

  public enum Outcome: Sendable {
    /// More bytes are needed. Not an error — TCP is free to split anywhere.
    case incomplete
    case complete(HTTPRequestHead, body: Data)
    case malformed(String)
  }

  public static func parse(_ buffer: [UInt8]) -> Outcome {
    let separator: [UInt8] = Array("\r\n\r\n".utf8)
    guard let headerEnd = firstRange(of: separator, in: buffer) else { return .incomplete }

    let headerBytes = Array(buffer[..<headerEnd.lowerBound])
    guard let headerText = String(bytes: headerBytes, encoding: .utf8) else {
      return .malformed("Headers are not UTF-8.")
    }
    var lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .malformed("No request line.") }
    lines.removeFirst()

    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return .malformed("Malformed request line.") }
    let method = String(parts[0]).uppercased()
    let target = String(parts[1].split(separator: "?", maxSplits: 1)[0])

    var fields: [String: String] = [:]
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else {
        return .malformed("Malformed header line.")
      }
      let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      // RFC 9110 says repeated fields combine with commas. Overwriting instead would let a
      // second `Authorization` line quietly replace the first.
      fields[name] = fields[name].map { "\($0),\(value)" } ?? value
    }

    let declared = Int(fields["content-length"] ?? "0") ?? 0
    guard declared >= 0 else { return .malformed("Negative Content-Length.") }
    guard declared <= maxBodyBytes else {
      return .malformed("Body of \(declared) bytes exceeds the \(maxBodyBytes)-byte cap.")
    }

    let bodyStart = headerEnd.upperBound
    let available = buffer.count - bodyStart
    guard available >= declared else { return .incomplete }

    return .complete(
      HTTPRequestHead(method: method, target: target, headers: HTTPHeaders(fields)),
      body: Data(buffer[bodyStart..<(bodyStart + declared)]))
  }

  private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
    guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
    for start in 0...(haystack.count - needle.count)
    where Array(haystack[start..<(start + needle.count)]) == needle {
      return start..<(start + needle.count)
    }
    return nil
  }
}
