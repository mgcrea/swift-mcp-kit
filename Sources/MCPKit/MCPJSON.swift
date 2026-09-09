import Foundation

/// The one encoder every response goes through.
///
/// Two options, and both are load-bearing:
///
/// - **`.sortedKeys`.** Swift dictionaries iterate in an order that varies per process and
///   per insertion, so without this the same answer serializes differently every time. That
///   defeats client-side caching of `tools/list` and the prompt caching the deterministic
///   ordering rule exists to enable — and it made two refusals that are supposed to be
///   byte-identical differ at random, which is how this was found.
/// - **`.withoutEscapingSlashes`.** Otherwise every URL in every payload ships as
///   `http:\/\/`, which is legal, unreadable, and pure overhead.
///
/// Deliberately **not** `.prettyPrinted`. A model does not need the indentation and it is
/// not free: measured against realistic rows it adds a quarter to a third of the payload,
/// worst on exactly the widest responses.
public enum MCPJSON {

  public static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  public static func data(_ value: JSONValue) -> Data {
    // `JSONValue` is a closed tree of JSON-representable cases, so encoding cannot fail for
    // any value that can be constructed. Returning empty rather than throwing keeps the
    // call sites honest about that.
    (try? encoder.encode(value)) ?? Data()
  }

  public static func string(_ value: JSONValue) -> String {
    String(decoding: data(value), as: UTF8.self)
  }
}
