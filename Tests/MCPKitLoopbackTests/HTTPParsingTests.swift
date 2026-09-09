import Foundation
import MCPKit
import Testing

@testable import MCPKitLoopback

@Suite("HTTP parsing")
struct HTTPParsingTests {

  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  @Test("A complete request parses into head and body")
  func complete() throws {
    let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8788\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
    guard case .complete(let head, let body) = HTTPParser.parse(bytes(raw)) else {
      Issue.record("expected a complete parse")
      return
    }
    #expect(head.method == "POST")
    #expect(head.target == "/mcp")
    #expect(head.headers["host"] == "127.0.0.1:8788")
    #expect(String(decoding: body, as: UTF8.self) == "{\"a\":1}")
  }

  /// TCP is free to split anywhere, so a half-arrived request is the normal case rather than
  /// an error. Treating it as malformed would drop perfectly good requests under load.
  @Test("A request whose body has not all arrived is incomplete, not malformed")
  func partialBody() {
    let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"a\":1}"
    guard case .incomplete = HTTPParser.parse(bytes(raw)) else {
      Issue.record("expected incomplete")
      return
    }
  }

  @Test("Headers arriving without the blank line are incomplete")
  func partialHeaders() {
    guard case .incomplete = HTTPParser.parse(bytes("POST /mcp HTTP/1.1\r\nHost: x")) else {
      Issue.record("expected incomplete")
      return
    }
  }

  /// RFC 9110 says repeated fields combine with commas. Overwriting instead would let a
  /// second `Authorization` line quietly replace the first.
  @Test("A header repeated is comma-joined rather than silently dropped")
  func repeatedHeader() throws {
    let raw =
      "POST /mcp HTTP/1.1\r\nAccept: application/json\r\nAccept: text/event-stream\r\n"
      + "Content-Length: 0\r\n\r\n"
    guard case .complete(let head, _) = HTTPParser.parse(bytes(raw)) else {
      Issue.record("expected a complete parse")
      return
    }
    #expect(head.headers["accept"] == "application/json,text/event-stream")
  }

  /// Checked against the declared length rather than by accumulating, so an absurd
  /// declaration costs nothing to refuse.
  @Test("A body larger than the cap is refused rather than buffered")
  func oversizedBody() {
    let raw = "POST /mcp HTTP/1.1\r\nContent-Length: \(HTTPParser.maxBodyBytes + 1)\r\n\r\n"
    guard case .malformed = HTTPParser.parse(bytes(raw)) else {
      Issue.record("expected malformed")
      return
    }
  }

  @Test("A query string is not part of the path")
  func queryStripped() throws {
    let raw = "POST /mcp?x=1 HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
    guard case .complete(let head, _) = HTTPParser.parse(bytes(raw)) else {
      Issue.record("expected a complete parse")
      return
    }
    #expect(head.target == "/mcp")
  }
}
