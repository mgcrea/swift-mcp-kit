import Foundation
import MCPKit
import Testing

@testable import MCPKitLoopback

@Suite("RequestGate")
struct RequestGateTests {

  private let port = 8788

  private func gate(
    verdict: @escaping @Sendable (String?) -> TokenVerdict = { _ in .accepted(client: "test") }
  ) -> RequestGate {
    RequestGate(port: port, endpoint: "/mcp", verify: verdict)
  }

  private func head(
    method: String = "POST", target: String = "/mcp", _ fields: [String: String] = [:]
  ) -> HTTPRequestHead {
    var merged = ["host": "127.0.0.1:\(port)", "authorization": "Bearer good"]
    for (key, value) in fields { merged[key] = value }
    return HTTPRequestHead(
      method: method, target: target,
      headers: HTTPHeaders(merged.filter { !$0.value.isEmpty }))
  }

  @Test("A well-formed loopback POST is allowed")
  func happyPath() {
    #expect(gate().check(head()) == nil)
  }

  // MARK: - Order of checks

  /// The order is load-bearing rather than tidy. Host and Origin are settled before the
  /// token, so a DNS-rebinding probe is refused whether or not it guessed a credential —
  /// if the token were checked first, the difference between the two refusals would tell an
  /// attacker's page whether its guess was right.
  @Test("A non-loopback Host is refused even with a valid token")
  func hostCheckedBeforeToken() throws {
    let refusal = try #require(gate().check(head(["host": "evil.example.com"])))
    #expect(refusal.status == 403)
  }

  @Test("A non-loopback Host is refused even with no token at all")
  func hostCheckedBeforeMissingToken() throws {
    let refusal = try #require(
      gate().check(head(["host": "evil.example.com", "authorization": ""])))
    #expect(refusal.status == 403)
  }

  @Test("Loopback spellings are all accepted", arguments: ["127.0.0.1", "localhost", "[::1]"])
  func loopbackSpellings(_ host: String) {
    #expect(gate().check(head(["host": "\(host):\(port)"])) == nil)
  }

  // MARK: - Origin

  /// Real MCP clients are not browsers and send no Origin at all. Requiring one would
  /// refuse every genuine caller while stopping nothing.
  @Test("An absent Origin is fine")
  func absentOrigin() {
    #expect(gate().check(head(["origin": ""])) == nil)
  }

  @Test("A present, foreign Origin is refused")
  func foreignOrigin() throws {
    let refusal = try #require(gate().check(head(["origin": "https://evil.example.com"])))
    #expect(refusal.status == 403)
  }

  @Test("A present loopback Origin is fine")
  func loopbackOrigin() {
    #expect(gate().check(head(["origin": "http://127.0.0.1:\(port)"])) == nil)
  }

  // MARK: - Token

  @Test("No token and a wrong token get the identical refusal")
  func tokenRefusalsAreIdentical() throws {
    let strict = gate(verdict: { $0 == "good" ? .accepted(client: "test") : .rejected })
    let missing = try #require(strict.check(head(["authorization": ""])))
    let wrong = try #require(strict.check(head(["authorization": "Bearer bad"])))
    // An error that distinguished them would be an oracle: it would confirm to a caller
    // that a guessed token was well-formed but wrong, which is halfway to right.
    #expect(missing.status == 401)
    #expect(wrong.status == 401)
    #expect(missing.body == wrong.body)
    #expect(missing.headers["WWW-Authenticate"] != nil)
  }

  /// A locked Keychain is the server's problem, not the caller's. Answering 401 would tell
  /// a correctly-configured client its credential is bad and send the user to regenerate a
  /// token that was fine all along.
  @Test("An unreadable credential store is 503 with a retry, never 401")
  func unavailableIsNotUnauthorized() throws {
    let refusal = try #require(gate(verdict: { _ in .unavailable }).check(head()))
    #expect(refusal.status == 503)
    #expect(refusal.headers["Retry-After"] != nil)
  }

  @Test("The Bearer scheme is matched case-insensitively")
  func bearerCaseInsensitive() {
    let strict = gate(verdict: { $0 == "good" ? .accepted(client: "t") : .rejected })
    #expect(strict.check(head(["authorization": "bearer good"])) == nil)
  }

  // MARK: - Method and path

  /// 405 rather than 404, and the difference is not cosmetic. A client that sees 404 goes
  /// looking for the deprecated HTTP+SSE endpoint; 405 says the endpoint is right and the
  /// verb is not.
  @Test("GET and DELETE on the endpoint are 405", arguments: ["GET", "DELETE"])
  func wrongVerb(_ method: String) throws {
    let refusal = try #require(gate().check(head(method: method)))
    #expect(refusal.status == 405)
  }

  @Test("An unknown path is 404")
  func unknownPath() throws {
    let refusal = try #require(gate().check(head(target: "/elsewhere")))
    #expect(refusal.status == 404)
  }

  // MARK: - Constant-time compare

  @Test("Constant-time compare agrees with equality")
  func constantTimeAgrees() {
    #expect(constantTimeEquals("abc", "abc"))
    #expect(!constantTimeEquals("abc", "abd"))
    #expect(!constantTimeEquals("abc", "abcd"))
    #expect(constantTimeEquals("", ""))
  }
}
