import Foundation
import Testing

@testable import MCPKit

@Suite("ToolTable and the write gate")
struct ToolTableTests {

  private func table() -> ToolTable {
    var table = ToolTable()
    table.add(
      MCPTool(name: "read_thing", description: "Reads.", annotations: .readOnly)
    ) { _ in .text("read") }
    table.add(
      MCPTool(
        name: "write_thing", description: "Writes.", gate: .requiresWrites,
        annotations: .mutating(destructive: false))
    ) { _ in .text("wrote") }
    // Writes a file but is not gated: the toggle governs the user's data, not the
    // `readOnlyHint` bit.
    table.add(
      MCPTool(
        name: "export_thing", description: "Exports.", gate: .always,
        annotations: .mutating(destructive: false, idempotent: true))
    ) { _ in .text("exported") }
    return table
  }

  @Test("With writes off, a mutating tool is absent from the listing entirely")
  func gateHides() {
    let names = table().listing(allowWrites: false).map(\.name)
    #expect(names.contains("read_thing"))
    #expect(!names.contains("write_thing"))
    // Not gated, despite readOnlyHint being false.
    #expect(names.contains("export_thing"))
  }

  @Test("With writes on, everything is listed")
  func gateReveals() {
    #expect(table().listing(allowWrites: true).count == 3)
  }

  /// `tools/list` is advisory: a client may have cached an older list, or simply guessed a
  /// name. Hiding is what stops a model planning around a tool it cannot use; refusing is
  /// the actual enforcement.
  @Test("A gated tool is refused at call time as well as hidden")
  func gateRefusesAtCallTime() async throws {
    let result = try await table().call(
      name: "write_thing", arguments: .object([:]), allowWrites: false)
    #expect(result.isError)
    #expect(result.text.contains("Allow writes"))
  }

  @Test("A gated tool runs once writes are allowed")
  func gatedToolRuns() async throws {
    let result = try await table().call(
      name: "write_thing", arguments: .object([:]), allowWrites: true)
    #expect(!result.isError)
    #expect(result.text == "wrote")
  }

  @Test("An ungated writing tool runs with the toggle off")
  func ungatedWriterRuns() async throws {
    let result = try await table().call(
      name: "export_thing", arguments: .object([:]), allowWrites: false)
    #expect(!result.isError)
  }

  /// A name that does not exist and a name that is merely hidden must give the same
  /// answer shape but different sentences — "no such tool" sends a model looking for a
  /// typo, when the truth is a switch it can tell the user to flip.
  @Test("An unknown tool is an error naming what is available")
  func unknownTool() async throws {
    let result = try await table().call(
      name: "nope", arguments: .object([:]), allowWrites: true)
    #expect(result.isError)
    #expect(result.text.contains("read_thing"))
  }

  @Test("A thrown handler error becomes a tool error, never a transport error")
  func handlerThrows() async throws {
    var table = ToolTable()
    struct Boom: LocalizedError { var errorDescription: String? { "the disk is on fire" } }
    table.add(MCPTool(name: "boom", description: "Fails.", annotations: .readOnly)) { _ in
      throw Boom()
    }
    let result = try await table.call(name: "boom", arguments: .object([:]), allowWrites: true)
    #expect(result.isError)
    #expect(result.text.contains("the disk is on fire"))
  }

  @Test("Annotations are derived, and a read tool does not restate its own defaults")
  func annotationsAreLean() throws {
    let listing = table().listing(allowWrites: true)
    let read = try #require(listing.first { $0.name == "read_thing" })
    let annotations = try #require(read.json["annotations"]?.objectValue)
    #expect(annotations["readOnlyHint"] == .bool(true))
    // `destructiveHint` defaults to true, but only *matters* when readOnlyHint is false.
    // Emitting it on a read tool is bytes spent restating the line above it.
    #expect(annotations["destructiveHint"] == nil)
  }

  @Test("A tool with no required arguments omits the empty required array")
  func schemaOmitsEmptyRequired() throws {
    let read = try #require(table().listing(allowWrites: true).first { $0.name == "read_thing" })
    let schema = try #require(read.json["inputSchema"]?.objectValue)
    #expect(schema["type"] == .string("object"))
    #expect(schema["required"] == nil)
  }

  /// Clients cache the listing and use it for prompt-cache hits; an unstable order costs
  /// them both.
  @Test("The listing is in a deterministic order")
  func deterministicOrder() {
    let once = table().listing(allowWrites: true).map(\.name)
    let twice = table().listing(allowWrites: true).map(\.name)
    #expect(once == twice)
  }
}
