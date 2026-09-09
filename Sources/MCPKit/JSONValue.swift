import Foundation

/// A JSON value, as a `Sendable` tree.
///
/// The obvious alternative is `[String: Any]`, which is what a hand-rolled server reaches
/// for first and what the sibling implementation in `bastion` uses throughout. It is not
/// usable here: this package hands frames across task and actor boundaries, and `Any` is
/// not `Sendable`, so every hop would need an `@unchecked` escape hatch. One enum removes
/// the whole class of problem.
///
/// `int` and `double` are separate cases rather than one `number`, for two reasons that
/// both bite in practice:
///
/// - JSON Schema distinguishes `integer` from `number`, and this type carries tool schemas
///   verbatim. Collapsing them would re-emit every `"maxLength": 200` as `200.0`.
/// - The Streamable HTTP transport requires servers to compare a mirrored header value
///   against the body value, and says integers SHOULD be compared numerically. Keeping the
///   integer an integer is what makes that comparison say what it means.
public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

// MARK: - Reading

extension JSONValue {

  /// The value at `key`, or `nil` when this is not an object or has no such key.
  ///
  /// Note what this deliberately does NOT do: a key present with a null value returns
  /// `.null`, not `nil`. A missing key and a null are different claims, and a subscript
  /// that flattened them would make the difference unreachable at exactly the point the
  /// caller needs it.
  public subscript(key: String) -> JSONValue? {
    guard case .object(let fields) = self else { return nil }
    return fields[key]
  }

  public subscript(index: Int) -> JSONValue? {
    guard case .array(let items) = self, items.indices.contains(index) else { return nil }
    return items[index]
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    guard case .int(let value) = self else { return nil }
    return value
  }

  /// The value as a `Double`, accepting an integer.
  ///
  /// Asymmetric with `intValue` on purpose: every integer is a number, so reading one as a
  /// double loses nothing, while reading `3.5` as an `Int` would silently invent a value.
  public var doubleValue: Double? {
    switch self {
    case .double(let value): value
    case .int(let value): Double(value)
    default: nil
    }
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let items) = self else { return nil }
    return items
  }

  public var objectValue: [String: JSONValue]? {
    guard case .object(let fields) = self else { return nil }
    return fields
  }

  public var isNull: Bool { self == .null }
}

// MARK: - Codable

extension JSONValue: Codable {

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      // Ordered before `Double` deliberately. `Double` decodes "42" happily, so trying it
      // first would turn every integer in every tool schema into a float on the way out.
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Not a JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
