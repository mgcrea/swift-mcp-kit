import Foundation

/// A protocol revision this package speaks, and which era it belongs to.
///
/// Three, and the range is not conservatism. `2026-07-28` is what a server should be built
/// on today; `2025-11-25` and `2025-06-18` are what clients actually send. The
/// `@modelcontextprotocol/sdk` in wide use is 1.30.0, whose `LATEST_PROTOCOL_VERSION` is
/// `2025-11-25`, so a server that spoke only the newest revision would be correct and
/// unusable at the same time.
public enum MCPVersion: String, Sendable, Hashable, CaseIterable, Codable {
  case v20250618 = "2025-06-18"
  case v20251125 = "2025-11-25"
  case v20260728 = "2026-07-28"

  /// Which shape of the protocol a version belongs to.
  ///
  /// The split is not a matter of degree. Across this line the handshake, sessions, the GET
  /// stream and stream resumability all disappear, and per-request `_meta` replaces them —
  /// so almost every rule in this package branches on the era rather than on the version.
  public enum Era: Sendable, Hashable {
    /// `initialize` negotiates once, and the connection remembers. Up to `2025-11-25`.
    case handshake
    /// Every request carries its own version, identity and capabilities. `2026-07-28` on.
    case stateless
  }

  public var era: Era {
    switch self {
    case .v20250618, .v20251125: .handshake
    case .v20260728: .stateless
    }
  }

  /// The newest revision, and what `server/discover` reports as preferred.
  public static let latest: MCPVersion = .v20260728

  /// The newest revision of the handshake era, used when a client says nothing at all.
  static let latestHandshake: MCPVersion = .v20251125

  /// Newest first, which is the order `server/discover` and the error payloads want.
  public static var supported: [MCPVersion] { allCases.reversed() }
}
