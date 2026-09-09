import Foundation
import Testing

@testable import MCPKit

@Suite("JSONValue")
struct JSONValueTests {

  @Test("Round-trips every JSON shape through Foundation")
  func roundTrip() throws {
    let value: JSONValue = [
      "string": "hello",
      "int": 42,
      "double": 3.5,
      "bool": true,
      "null": .null,
      "array": [1, "two", false],
      "nested": ["deep": ["deeper": 1]],
    ]
    let data = try JSONEncoder().encode(value)
    let back = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(back == value)
  }

  /// An integer must not come back as a double. JSON Schema distinguishes `integer` from
  /// `number`, and the header-validation rules compare a header's `42` against a body's
  /// `42` — a value that decoded as `42.0` and re-encoded as `42.0` would fail a
  /// comparison the specification says should pass.
  @Test("Integers survive as integers")
  func integersStayIntegers() throws {
    let data = Data(#"{"n":42}"#.utf8)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded["n"] == .int(42))
    #expect(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self) == #"{"n":42}"#)
  }

  /// The distinction the whole response contract rests on: a key that is absent and a key
  /// whose value is null are different claims, and subscripting must not conflate them.
  @Test("Absent and null are distinguishable")
  func absentIsNotNull() {
    let object: JSONValue = ["present": .null]
    #expect(object["present"] == JSONValue.null)
    #expect(object["missing"] == nil)
  }

  @Test("Typed accessors read what is there and refuse what is not")
  func accessors() {
    let object: JSONValue = ["s": "text", "i": 7, "d": 1.5, "b": false]
    #expect(object["s"]?.stringValue == "text")
    #expect(object["i"]?.intValue == 7)
    #expect(object["d"]?.doubleValue == 1.5)
    #expect(object["b"]?.boolValue == false)
    #expect(object["s"]?.intValue == nil)
    // An integer is a number; asking for it as a double is not a type confusion.
    #expect(object["i"]?.doubleValue == 7)
  }
}

@Suite("MCPJSON")
struct MCPJSONTests {

  /// Swift dictionaries iterate in an order that varies per process, so an unsorted encode
  /// produces a different byte string for the same value every time. That is not cosmetic:
  /// it defeats client-side caching of a listing that has not changed, and it made two
  /// refusals that are meant to be byte-identical differ at random — which is how the
  /// missing option was found in the first place.
  @Test("The same value always encodes to the same bytes")
  func deterministic() {
    let value: JSONValue = [
      "zebra": 1, "alpha": 2, "middle": ["b": 1, "a": 2], "yak": 3, "beta": 4,
    ]
    let once = MCPJSON.string(value)
    #expect((0..<50).allSatisfy { _ in MCPJSON.string(value) == once })
    #expect(once.hasPrefix("{\"alpha\""))
  }

  @Test("Slashes are not escaped")
  func slashes() {
    #expect(MCPJSON.string(["url": "http://127.0.0.1:8788/mcp"]).contains("http://127.0.0.1"))
  }

  /// A model does not need the indentation, and it is not free.
  @Test("Output is compact")
  func compact() {
    #expect(!MCPJSON.string(["a": 1, "b": 2]).contains("\n"))
  }
}
