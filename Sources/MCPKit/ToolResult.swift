import Foundation

/// What a tool answers with.
///
/// The rendering rule this type exists to enforce: `structuredContent` is the answer, and
/// `content` is a short human lede over it — never the same payload twice. A server that
/// emits Markdown, then the serialized JSON of the same rows, then resource links for each
/// of them pays two to three times for one answer, on every call.
public struct ToolResult: Sendable, Hashable {

  public enum Content: Sendable, Hashable {
    case text(String)
    case resourceLink(uri: String, name: String, description: String?, mimeType: String?)

    var json: JSONValue {
      switch self {
      case .text(let value):
        .object(["type": "text", "text": .string(value)])
      case .resourceLink(let uri, let name, let description, let mimeType):
        .object(
          ["type": "resource_link", "uri": .string(uri), "name": .string(name)]
            .merging(description.map { ["description": JSONValue.string($0)] } ?? [:]) { a, _ in a }
            .merging(mimeType.map { ["mimeType": JSONValue.string($0)] } ?? [:]) { a, _ in a })
      }
    }
  }

  public var content: [Content]
  public var structuredContent: JSONValue?
  /// A tool failure, not a protocol failure. The distinction matters: a model can read and
  /// act on a tool error, whereas a JSON-RPC error is a transport-level event it is only
  /// told about.
  public var isError: Bool

  public init(content: [Content], structuredContent: JSONValue? = nil, isError: Bool = false) {
    self.content = content
    self.structuredContent = structuredContent
    self.isError = isError
  }

  public static func text(_ value: String) -> ToolResult {
    ToolResult(content: [.text(value)])
  }

  /// The ordinary answer: a short lede, and the data.
  public static func answer(_ lede: String, _ structured: JSONValue) -> ToolResult {
    ToolResult(content: [.text(lede)], structuredContent: structured)
  }

  public static func failure(_ message: String) -> ToolResult {
    ToolResult(content: [.text(message)], isError: true)
  }

  /// Every text block joined, which is what a test wants to assert against.
  public var text: String {
    content.compactMap { if case .text(let value) = $0 { value } else { nil } }
      .joined(separator: "\n")
  }

  /// The `tools/call` result body.
  ///
  /// `structuredContent` is emitted for every era that reads it. For `2025-06-18`, whose
  /// clients do not, the serialized JSON is added as a second text block instead — which is
  /// the one place speaking three revisions pays for itself rather than costing.
  public func json(for version: MCPVersion) -> JSONValue {
    var blocks = content.map(\.json)
    if let structuredContent {
      if version == .v20250618 {
        blocks.append(
          .object(["type": "text", "text": .string(MCPJSON.string(structuredContent))]))
      }
    }
    var fields: JSONValue = .object(["content": .array(blocks), "isError": .bool(isError)])
    if let structuredContent, version != .v20250618 {
      fields = fields.merging(["structuredContent": structuredContent])
    }
    return fields
  }
}

extension JSONValue {
  /// Add or replace fields on an object. Returns `self` unchanged when it is not one.
  ///
  /// Public because building a response object incrementally — attach the warnings, attach
  /// the gated block, attach the omissions — is what every consuming tool does, and a
  /// consumer forced to destructure and rebuild would eventually stop attaching one of them.
  public func merging(_ fields: [String: JSONValue]) -> JSONValue {
    guard case .object(let existing) = self else { return self }
    return .object(existing.merging(fields) { _, new in new })
  }
}
