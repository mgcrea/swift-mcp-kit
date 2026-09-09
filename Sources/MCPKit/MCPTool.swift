import Foundation

/// Whether the write toggle governs a tool.
///
/// Deliberately NOT the same thing as `readOnlyHint`, and the difference is worth a type
/// rather than a convention. A tool that writes an export file to a directory the user
/// chose is honestly `readOnlyHint: false`, and gating it behind "allow writes" would put
/// a data-export feature behind a safety switch it has nothing to do with.
///
/// The toggle governs changes to the user's own data, preferences and credentials. It does
/// not govern the annotation.
public enum ToolGate: Sendable, Hashable {
  /// Always reachable, whatever the toggle says.
  case always
  /// Hidden from `tools/list` and refused when called, unless writes are allowed.
  case requiresWrites
}

/// One tool: what it is called, what it takes, and what it will admit to doing.
public struct MCPTool: Sendable, Hashable {

  /// The hints a client uses to decide how much ceremony a call deserves.
  ///
  /// Rendered lean rather than complete. `destructiveHint` and `idempotentHint` are only
  /// meaningful when `readOnlyHint` is false — the specification says so — so emitting them
  /// on a read tool is a byte-for-byte restatement of the line above them, paid on every
  /// connect by every client.
  public struct Annotations: Sendable, Hashable {
    public var readOnlyHint: Bool
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public static let readOnly = Annotations(readOnlyHint: true, openWorldHint: false)

    /// A tool that changes something. `destructive` defaults to the specification's own
    /// default of `true`, so a caller has to say when it is not.
    public static func mutating(
      destructive: Bool = true, idempotent: Bool? = nil, openWorld: Bool = false
    ) -> Annotations {
      Annotations(
        readOnlyHint: false, destructiveHint: destructive, idempotentHint: idempotent,
        openWorldHint: openWorld)
    }

    var json: JSONValue {
      var fields: [String: JSONValue] = ["readOnlyHint": .bool(readOnlyHint)]
      if !readOnlyHint {
        if let destructiveHint { fields["destructiveHint"] = .bool(destructiveHint) }
        if let idempotentHint { fields["idempotentHint"] = .bool(idempotentHint) }
      }
      if let openWorldHint { fields["openWorldHint"] = .bool(openWorldHint) }
      return .object(fields)
    }
  }

  public let name: String
  public let title: String?
  public let description: String
  /// The `properties` of the input schema. The `type: object` wrapper is added on the way
  /// out so no tool has to spell it.
  public let properties: [String: JSONValue]
  public let required: [String]
  public let outputSchema: JSONValue?
  public let gate: ToolGate
  public let annotations: Annotations

  public init(
    name: String, title: String? = nil, description: String,
    properties: [String: JSONValue] = [:], required: [String] = [],
    outputSchema: JSONValue? = nil, gate: ToolGate = .always,
    annotations: Annotations
  ) {
    self.name = name
    self.title = title
    self.description = description
    self.properties = properties
    self.required = required
    self.outputSchema = outputSchema
    self.gate = gate
    self.annotations = annotations
  }

  public var mutates: Bool { gate == .requiresWrites }

  /// The `tools/list` entry.
  public var json: JSONValue {
    var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
    // Omitted when empty rather than sent as `[]`: it is the commonest shape in a listing
    // and the two spellings mean the same thing.
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }

    var fields: [String: JSONValue] = [
      "name": .string(name),
      "description": .string(description),
      "inputSchema": .object(schema),
      "annotations": annotations.json,
    ]
    if let title { fields["title"] = .string(title) }
    if let outputSchema { fields["outputSchema"] = outputSchema }
    return .object(fields)
  }
}
