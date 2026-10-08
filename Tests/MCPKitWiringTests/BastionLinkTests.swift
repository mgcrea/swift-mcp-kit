import Foundation
import Testing

@testable import MCPKitWiring

@Suite("BastionLink")
struct BastionLinkTests {

  private let link = BastionLink(
    id: "pochette", displayName: "Pochette", url: "http://127.0.0.1:8791/mcp",
    token: "a+b/c=d&e", summary: "Tags & folders, 100% local",
    writeTools: ["pochette_edit_tags", "pochette_undo"])

  @Test func readsBackWhatItWrites() throws {
    #expect(try BastionLink(link: link.link) == link)
  }

  @Test func isABastionAddServerLink() {
    #expect(link.link.scheme == "bastion")
    #expect(link.link.host == "add-server")
    #expect(link.link.absoluteString.contains("v=1"))
  }

  /// A token is random bytes in some alphabet, and `+`, `&` or `=` left bare would be read back
  /// as a space or a new field.
  @Test func keepsSeparatorsInsideValues() throws {
    let read = try BastionLink(link: link.link)
    #expect(read.token == "a+b/c=d&e")
    #expect(read.summary == "Tags & folders, 100% local")
  }

  @Test func leavesOutWhatItDoesNotHave() throws {
    let bare = BastionLink(
      id: "almanac", displayName: "Almanac", url: "http://[::1]:8788/mcp", token: "t")
    let query = bare.link.query ?? ""
    #expect(!query.contains("summary"))
    #expect(!query.contains("write_tools"))
    #expect(try BastionLink(link: bare.link).writeTools == [])
  }

  @Test func isMadeFromAWiredServer() {
    let server = WiredServer(key: "armada", url: "http://127.0.0.1:8790/mcp", token: "tok")
    let link = BastionLink(server, displayName: "Armada")
    #expect(link.id == "armada")
    #expect(link.url == server.url)
    #expect(link.token == "tok")
  }

  @Test(arguments: [
    "http://localhost:8791/mcp",
    "http://192.168.1.10:8791/mcp",
    "https://example.com/mcp",
    "http://127.0.0.1/mcp",
    "http://user:pass@127.0.0.1:8791/mcp",
    "file:///tmp/mcp",
  ])
  func refusesAnythingButLiteralLoopback(url: String) {
    let foreign = BastionLink(id: "x", displayName: "X", url: url, token: "t")
    #expect(throws: BastionLink.Problem.notLoopback(url)) { try BastionLink(link: foreign.link) }
  }

  @Test(arguments: ["", "Pochette", "-pochette", "poch_ette", "poché"])
  func refusesAnIDThatIsNotKebabCase(id: String) {
    let bad = BastionLink(id: id, displayName: "X", url: "http://127.0.0.1:1/mcp", token: "t")
    #expect(throws: BastionLink.Problem.self) { try BastionLink(link: bad.link) }
  }

  @Test func refusesAMissingToken() {
    let tokenless = BastionLink(
      id: "x", displayName: "X", url: "http://127.0.0.1:1/mcp", token: "")
    #expect(throws: BastionLink.Problem.missing("token")) { try BastionLink(link: tokenless.link) }
  }

  @Test func refusesAVersionItDoesNotKnow() throws {
    let newer = try #require(
      URL(string: link.link.absoluteString.replacingOccurrences(of: "v=1", with: "v=2")))
    #expect(throws: BastionLink.Problem.unknownVersion("2")) { try BastionLink(link: newer) }
  }

  @Test func refusesAnotherLink() throws {
    let other = try #require(URL(string: "bastion://remove-server?id=x"))
    #expect(throws: BastionLink.Problem.notABastionLink) { try BastionLink(link: other) }
  }
}
