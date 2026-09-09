import Foundation

/// A case-insensitive header bag.
///
/// RFC 9110 makes field names case-insensitive, and the specification restates it for MCP's
/// own headers. Header *values* are case-sensitive and are stored untouched — `Mcp-Method`
/// carries a method name, and lowercasing `tools/call` would be harmless while lowercasing
/// a tool name would not.
public struct HTTPHeaders: Sendable, Hashable {
  private var fields: [String: String]

  public init(_ fields: [String: String] = [:]) {
    self.fields = Dictionary(
      fields.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
  }

  public subscript(name: String) -> String? {
    get { fields[name.lowercased()] }
    set { fields[name.lowercased()] = newValue }
  }

  /// The value with surrounding whitespace removed, or `nil` when absent **or empty**.
  ///
  /// An empty header is treated as absent on purpose: a proxy that strips a value leaves
  /// the field behind, and "present but blank" is never a claim anyone meant to make.
  public func trimmed(_ name: String) -> String? {
    guard let value = self[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
      return nil
    }
    return value
  }
}
