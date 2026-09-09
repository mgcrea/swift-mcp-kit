import Foundation

/// What a tool does when called.
public typealias ToolHandler = @Sendable (JSONValue) async throws -> ToolResult

/// The tools a server offers, and the gate in front of the ones that change things.
///
/// The gate is enforced twice, and both are necessary:
///
/// - **Hidden from the listing.** A model handed a tool it will always be refused for will
///   plan around it and then report a failure the person cannot act on.
/// - **Refused at call time.** `tools/list` is advisory. A client may hold a cached listing
///   from before the toggle moved, or may simply call a name it guessed. Hiding is the
///   ergonomics; this is the enforcement.
///
/// A gate that only filtered the listing would be a suggestion, and one that only refused
/// would waste a model's turn on every attempt.
public struct ToolTable: Sendable {

  private struct Entry: Sendable {
    let tool: MCPTool
    let handler: ToolHandler
  }

  /// Insertion order is preserved and is the wire order. Servers SHOULD return tools
  /// deterministically so clients can cache the listing and hit their own prompt caches; a
  /// dictionary's order would quietly defeat both.
  private var entries: [Entry] = []

  public init() {}

  public mutating func add(_ tool: MCPTool, handler: @escaping ToolHandler) {
    precondition(
      !entries.contains { $0.tool.name == tool.name },
      "Two tools named '\(tool.name)'. A duplicate silently shadows, so this is a build error.")
    entries.append(Entry(tool: tool, handler: handler))
  }

  /// The tools visible right now. A pure function of `allowWrites` and nothing else.
  ///
  /// Deliberately not varying with any runtime condition that can change while the process
  /// lives — a credential going stale, a network coming back. Clients cache this list, so a
  /// tool that appeared and vanished would leave them calling names the server no longer
  /// has. Tools whose preconditions are unmet report that when called.
  public func listing(allowWrites: Bool) -> [MCPTool] {
    entries.map(\.tool).filter { allowWrites || !$0.mutates }
  }

  public func tool(named name: String) -> MCPTool? {
    entries.first { $0.tool.name == name }?.tool
  }

  /// Run a tool.
  ///
  /// Every failure below comes back as a *tool* error rather than a JSON-RPC one, because a
  /// model can read a tool error and change what it does next. A transport error is
  /// something it is merely told about.
  public func call(
    name: String, arguments: JSONValue, allowWrites: Bool
  ) async -> ToolResult {
    guard let entry = entries.first(where: { $0.tool.name == name }) else {
      let available = listing(allowWrites: allowWrites).map(\.name).joined(separator: ", ")
      return ToolResult(
        content: [.text("No tool named '\(name)'. Available: \(available).")],
        isError: true, outcome: .unknownTool)
    }
    guard allowWrites || !entry.tool.mutates else {
      return ToolResult(
        content: [
          .text(
            "'\(name)' changes data, and this server's write gate is off. "
              + "Turn on \"Allow writes\" in the app to use it.")
        ],
        isError: true, outcome: .writeGateRefused)
    }
    do {
      return try await entry.handler(arguments)
    } catch {
      // `localizedDescription` on a LocalizedError is its `errorDescription`, which is
      // where a well-written tool error puts the sentence meant for the caller.
      return .failure(error.localizedDescription)
    }
  }
}
