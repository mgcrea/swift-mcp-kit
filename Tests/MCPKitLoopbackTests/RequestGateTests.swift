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

  /// Only "good" is accepted, so a refusal means the token was actually compared.
  private var strict: RequestGate {
    gate(verdict: { $0 == "good" ? .accepted(client: "test") : .rejected })
  }

  private func head(
    method: String = "POST", target: String = "/mcp", _ fields: [String: String] = [:]
  ) -> HTTPRequestHead {
    var merged = ["host": "127.0.0.1:\(port)", "authorization": "Bearer good"]
    for (key, value) in fields { merged[key] = value }
    return HTTPRequestHead(
      method: method, target: target,
      // An empty override means "omit this header entirely".
      headers: HTTPHeaders(merged.filter { !$0.value.isEmpty }))
  }

  // MARK: -

  @Test("A well-formed loopback POST is allowed, and names the caller")
  func happyPath() throws {
    let accepted = try gate().check(head()).get()
    #expect(accepted.route == .rpc)
    // From the token, not from the body. This is the only identity worth auditing.
    #expect(accepted.client == "test")
  }

  // MARK: - Order of checks

  /// The order is load-bearing rather than tidy. Host and Origin are settled before the
  /// token, so a DNS-rebinding probe is refused whether or not it guessed a credential — if
  /// the token were checked first, the difference between the two refusals would tell an
  /// attacker's page whether its guess was right.
  @Test("A non-loopback Host is refused even with a valid token")
  func hostCheckedBeforeToken() throws {
    let refusal = try #require(gate().check(head(["host": "evil.example.com"])).failure)
    #expect(refusal.status == 403)
  }

  @Test("A non-loopback Host is refused even with no token at all")
  func hostCheckedBeforeMissingToken() throws {
    let refusal = try #require(
      gate().check(head(["host": "evil.example.com", "authorization": ""])).failure)
    #expect(refusal.status == 403)
  }

  /// One step further down, and the same argument. An unauthenticated caller that could tell
  /// `404` from `405` would be able to map the endpoints before presenting a credential;
  /// with the token first, everything it can reach is one sentence.
  @Test("The route is settled after the token, so an unknown path is 401 without one")
  func routeCheckedAfterToken() throws {
    let unknown = try #require(
      strict.check(head(target: "/secret-admin", ["authorization": ""])).failure)
    #expect(unknown.status == 401)

    let wrongVerb = try #require(
      strict.check(head(method: "GET", ["authorization": ""])).failure)
    #expect(wrongVerb.status == 401)
  }

  @Test("Loopback spellings are all accepted", arguments: ["127.0.0.1", "localhost", "[::1]"])
  func loopbackSpellings(_ host: String) throws {
    #expect(try gate().check(head(["host": "\(host):\(port)"])).get().route == .rpc)
  }

  // MARK: - Origin

  /// Real MCP clients are not browsers and send no Origin at all. Requiring one would refuse
  /// every genuine caller while stopping nothing.
  @Test("An absent Origin is fine")
  func absentOrigin() throws {
    #expect(try gate().check(head(["origin": ""])).get().route == .rpc)
  }

  @Test("A present, foreign Origin is refused")
  func foreignOrigin() throws {
    let refusal = try #require(
      gate().check(head(["origin": "https://evil.example.com"])).failure)
    #expect(refusal.status == 403)
  }

  @Test("A present loopback Origin is fine")
  func loopbackOrigin() throws {
    #expect(
      try gate().check(head(["origin": "http://127.0.0.1:\(port)"])).get().route == .rpc)
  }

  // MARK: - Token

  @Test("No token and a wrong token get the identical refusal")
  func tokenRefusalsAreIdentical() throws {
    let missing = try #require(strict.check(head(["authorization": ""])).failure)
    let wrong = try #require(strict.check(head(["authorization": "Bearer bad"])).failure)
    // An error that distinguished them would be an oracle: it would confirm to a caller that
    // a guessed token was well-formed but wrong, which is halfway to right.
    #expect(missing.status == 401)
    #expect(wrong.status == 401)
    #expect(missing.body == wrong.body)
    #expect(missing.headers["WWW-Authenticate"] != nil)
  }

  /// A locked keychain is the server's problem, not the caller's. Answering 401 would tell a
  /// correctly-configured client its credential is bad and send the user to regenerate a
  /// token that was fine all along.
  @Test("An unreadable credential store is 503 with a retry, never 401")
  func unavailableIsNotUnauthorized() throws {
    let refusal = try #require(gate(verdict: { _ in .unavailable }).check(head()).failure)
    #expect(refusal.status == 503)
    #expect(refusal.headers["Retry-After"] != nil)
  }

  @Test("The Bearer scheme is matched case-insensitively")
  func bearerCaseInsensitive() throws {
    #expect(try strict.check(head(["authorization": "bearer good"])).get().route == .rpc)
  }

  // MARK: - Method and path

  /// 405 rather than 404, and the difference is not cosmetic. A client that sees 404 goes
  /// looking for the deprecated HTTP+SSE endpoint; 405 says the endpoint is right and the
  /// verb is not.
  @Test("GET and DELETE on the MCP endpoint are 405", arguments: ["GET", "DELETE"])
  func wrongVerb(_ method: String) throws {
    let refusal = try #require(gate().check(head(method: method)).failure)
    #expect(refusal.status == 405)
  }

  @Test("An unknown path is 404 for an authenticated caller")
  func unknownPath() throws {
    let refusal = try #require(gate().check(head(target: "/elsewhere")).failure)
    #expect(refusal.status == 404)
  }

  // MARK: - Health

  @Test("GET /health is its own route")
  func healthRoute() throws {
    #expect(try gate().check(head(method: "GET", target: "/health")).get().route == .health)
  }

  /// Behind the token like everything else. It is cheap to answer, and there is no reason to
  /// tell an unauthenticated local process the app's version.
  @Test("Health needs a token too")
  func healthNeedsAToken() throws {
    let refusal = try #require(
      strict.check(head(method: "GET", target: "/health", ["authorization": ""])).failure)
    #expect(refusal.status == 401)
  }

  @Test("POSTing to health is 405")
  func healthIsGetOnly() throws {
    let refusal = try #require(gate().check(head(target: "/health")).failure)
    #expect(refusal.status == 405)
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

extension Result {
  /// The failure, for a test that expects one. `try #require(…)` on this reads better than a
  /// `case .failure` dance at every call site.
  var failure: Failure? {
    guard case .failure(let error) = self else { return nil }
    return error
  }
}
