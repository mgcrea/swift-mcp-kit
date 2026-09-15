import Foundation

/// What an entry in a client's servers object means, and how ours are added and taken out.
///
/// Pure functions over dictionaries: no file, no format. A TOML config reaches these as the
/// same `[String: Any]` a JSON one does, which is what keeps the rules below to one
/// implementation.
///
/// **Ownership is the caller's, and it is asked per key.** Bastion recognised its entries by
/// URL grammar alone, which was safe because its paths are unmistakable. A plain
/// `http://127.0.0.1:<port>/mcp` is not: every app on this package serves exactly that, so a
/// rule reading only the URL would let one app's Remove button delete another's entry.
/// `WiredServer.owns` is the rule most consumers want — our key, reaching loopback.
public enum WiringMerge {
  public typealias Ownership = (_ key: String, _ entry: [String: Any]) -> Bool

  /// Where an entry points: its `command`, else its `url`. `nil` for a shape with neither.
  public static func identity(of entry: Any?) -> String? {
    guard let entry = entry as? [String: Any] else { return nil }
    if let command = entry["command"] as? String { return command }
    if let url = entry["url"] as? String { return url }
    return nil
  }

  public static func isLoopback(_ url: String) -> Bool {
    guard let host = URLComponents(string: url)?.host else { return false }
    return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
  }

  /// What is under one key, against what should be there.
  ///
  /// `stale` and `foreign` stay apart because their remedies are opposite. A stale entry is
  /// ours and drifted — a different port, an old token — and the fix is to write over it. A
  /// foreign one is somebody else's server, and writing over it is the damage.
  public enum EntryState: Equatable, Sendable {
    case missing
    case matches
    /// Ours, but not what would be written now. Carries where it points.
    case stale(String?)
    /// Present and not ours. Carries where it points.
    case foreign(String?)
  }

  public static func state(
    of servers: [String: Any], key: String, expected: [String: Any], owns: Ownership
  ) -> EntryState {
    guard let value = servers[key] else { return .missing }
    guard let entry = value as? [String: Any], owns(key, entry) else {
      return .foreign(identity(of: value))
    }
    return covers(entry, expected) ? .matches : .stale(identity(of: entry))
  }

  /// Whether `found` carries every top-level value of `expected`.
  ///
  /// A subset rather than equality, so a key a client adds to an entry of its own accord —
  /// Codex's `enabled`, a `startup_timeout_sec` somebody typed — does not report the entry as
  /// stale forever. `merged` keeps those keys for the same reason.
  public static func covers(_ found: [String: Any], _ expected: [String: Any]) -> Bool {
    expected.allSatisfy { key, value in
      guard let present = found[key] else { return false }
      return NSDictionary(dictionary: [key: present]).isEqual(to: [key: value])
    }
  }

  /// Of `keys`, the ones already holding an entry that is not ours.
  public static func collisions(servers: [String: Any], keys: [String], owns: Ownership)
    -> [String]
  {
    keys.filter { key in
      guard let value = servers[key] else { return false }
      guard let entry = value as? [String: Any] else { return true }
      return !owns(key, entry)
    }
    .sorted()
  }

  /// Write `entries` under `rootKey`, leaving every other key in the file alone.
  ///
  /// An entry of ours already there is updated rather than replaced, so keys a client or a
  /// person added to it survive. Anything else under that key is replaced outright — callers
  /// reach that only past `collisions`, or with the user's explicit say-so.
  public static func merged(
    into root: [String: Any], rootKey: String, entries: [String: [String: Any]],
    owns: Ownership
  ) -> [String: Any] {
    var root = root
    var servers = root[rootKey] as? [String: Any] ?? [:]
    for (key, entry) in entries {
      if let existing = servers[key] as? [String: Any], owns(key, existing) {
        servers[key] = existing.merging(entry) { _, new in new }
      } else {
        servers[key] = entry
      }
    }
    root[rootKey] = servers
    return root
  }

  /// Every entry of ours out of `rootKey`, and nothing else.
  ///
  /// The servers object is assigned back even when this empties it: an absent key and an
  /// empty one are different statements about a config, and this has no business inventing
  /// the difference.
  public static func unmerged(from root: [String: Any], rootKey: String, owns: Ownership)
    -> [String: Any]
  {
    var root = root
    guard var servers = root[rootKey] as? [String: Any] else { return root }
    let ours = servers.compactMap { key, value -> String? in
      guard let entry = value as? [String: Any], owns(key, entry) else { return nil }
      return key
    }
    for key in ours { servers.removeValue(forKey: key) }
    root[rootKey] = servers
    return root
  }
}
