import Foundation

/// A loopback MCP server, as a client config should name it.
public struct WiredServer: Hashable, Sendable {
  /// The key the entry is filed under. It becomes part of every tool name a model reads —
  /// `mcp__<key>__<tool>` — so it should be the app's short name and nothing more.
  public let key: String
  public let url: String
  public let token: String
  /// Appended to the config's file name for the backup of its previous contents.
  public let backupSuffix: String

  public init(key: String, url: String, token: String, backupSuffix: String? = nil) {
    self.key = key
    self.url = url
    self.token = token
    self.backupSuffix = backupSuffix ?? "\(key)-backup"
  }

  /// The entry at `key` is ours when it is filed under our key and reaches a loopback URL.
  ///
  /// Both halves. The key alone would claim a hand-written `armada` that runs something else;
  /// the URL alone would claim every other app on this package, since they all serve
  /// `http://127.0.0.1:<port>/mcp`. The port and token are deliberately not compared: an entry
  /// left behind by an old port or a regenerated token is ours, and it is the one most worth
  /// updating.
  public func owns(key: String, entry: [String: Any]) -> Bool {
    guard key == self.key, let url = entry["url"] as? String else { return false }
    return WiringMerge.isLoopback(url)
  }
}

public enum WiringStatus: Equatable, Sendable {
  case notInstalled
  case notConfigured
  case configured
  /// Ours, but reaching another port or carrying another token. Configure fixes it.
  case stale(String?)
  /// Somebody else's server is under our key. Carries where it points.
  case taken(String?)
  case unreadable(String)
}

public enum WiringError: LocalizedError, Equatable {
  /// Nothing was written. The recovery is a decision, not a retry: `configure(force:)`.
  case taken(client: String, key: String)

  public var errorDescription: String? {
    switch self {
    case .taken(let client, let key):
      return
        "\(client)'s config already has an entry named '\(key)' that points somewhere else. "
        + "Nothing was changed."
    }
  }
}

// MARK: - Operations

extension WiringClient {

  /// The entry this client is given, in the dialect its file speaks.
  ///
  /// Codex has no `type` — a `url` is what makes an entry streamable HTTP there — and its
  /// headers key takes a literal, which is what makes wiring it possible at all.
  public func entry(for server: WiredServer) -> [String: Any] {
    let headers = ["Authorization": "Bearer \(server.token)"]
    switch format {
    case .json: return ["type": "http", "url": server.url, "headers": headers]
    case .toml: return ["url": server.url, "http_headers": headers]
    }
  }

  /// Read from the file on every call, and cached nowhere: the file belongs to another
  /// application, and any cached answer is one it can make stale.
  public func status(of server: WiredServer) -> WiringStatus {
    guard isInstalled else { return .notInstalled }
    let servers: [String: Any]
    do { servers = try load().servers } catch { return .unreadable(error.localizedDescription) }
    switch WiringMerge.state(
      of: servers, key: server.key, expected: entry(for: server), owns: server.owns)
    {
    case .missing: return .notConfigured
    case .matches: return .configured
    case .stale(let found): return .stale(found)
    case .foreign(let found): return .taken(found)
    }
  }

  /// Whether the config holds an entry of ours at all, current or not.
  ///
  /// The gate for rewriting a config unasked — after a token is regenerated, say. Wiring a
  /// client is somebody's decision; keeping a wired one current is not a way to make it for
  /// them.
  public func isWired(_ server: WiredServer) -> Bool {
    guard let servers = try? load().servers else { return false }
    return servers.contains { key, value in
      guard let entry = value as? [String: Any] else { return false }
      return server.owns(key: key, entry: entry)
    }
  }

  /// Add or update our entry. Returns the backup's URL when the file existed and changed.
  ///
  /// `force` overwrites somebody else's entry under our key, and is the answer to
  /// `WiringError.taken` and nothing else.
  @discardableResult
  public func configure(_ server: WiredServer, force: Bool = false) throws -> URL? {
    try retryingIfChanged {
      let loaded = try load()
      if !force,
        !WiringMerge.collisions(servers: loaded.servers, keys: [server.key], owns: server.owns)
          .isEmpty
      {
        throw WiringError.taken(client: displayName, key: server.key)
      }
      let root = WiringMerge.merged(
        into: loaded.root, rootKey: rootKey, entries: [server.key: entry(for: server)],
        owns: server.owns)
      let written = (root[rootKey] as? [String: Any])?[server.key] as? [String: Any] ?? [:]
      return try save(
        loaded, root: root, upserting: [server.key: written], backupSuffix: server.backupSuffix)
    }
  }

  /// Every entry of ours out of the config. A file that does not exist is nothing to do.
  @discardableResult
  public func unwire(_ server: WiredServer) throws -> URL? {
    try retryingIfChanged {
      let loaded = try load()
      guard loaded.stamp != .absent else { return nil }
      let root = WiringMerge.unmerged(from: loaded.root, rootKey: rootKey, owns: server.owns)
      return try save(loaded, root: root, upserting: [:], backupSuffix: server.backupSuffix)
    }
  }

  // MARK: - The file

  private struct Loaded {
    let stamp: WiringFile.Stamp
    /// The whole JSON document, or `[rootKey: servers]` for TOML — which is what lets the
    /// merge above be the same merge for both.
    let root: [String: Any]
    let document: WiringTOML.Document?
    let rootKey: String

    var servers: [String: Any] { root[rootKey] as? [String: Any] ?? [:] }
  }

  /// The stamp is taken before the read, so it describes the bytes the change is computed from.
  private func load() throws -> Loaded {
    let stamp = WiringFile.stamp(of: configURL)
    switch format {
    case .json:
      let root = stamp == .absent ? [:] : try WiringFile.readJSON(configURL)
      return Loaded(stamp: stamp, root: root, document: nil, rootKey: rootKey)
    case .toml:
      let document = stamp == .absent ? WiringTOML.empty : try WiringTOML.read(configURL)
      return Loaded(
        stamp: stamp, root: [rootKey: document.servers], document: document, rootKey: rootKey)
    }
  }

  private func save(
    _ loaded: Loaded, root: [String: Any], upserting: [String: [String: Any]],
    backupSuffix: String
  ) throws -> URL? {
    switch format {
    case .json:
      // Compared as values before serialising. A client writes its file in its own key order
      // and this writes sorted, so byte equality would call an unchanged config changed and
      // reorder somebody's file on every pass.
      guard !NSDictionary(dictionary: root).isEqual(to: loaded.root) else { return nil }
      return try WiringFile.write(
        json: root, to: configURL, backupSuffix: backupSuffix, expecting: loaded.stamp)
    case .toml:
      let document = loaded.document ?? WiringTOML.empty
      let after = root[rootKey] as? [String: Any] ?? [:]
      let removed = Set(document.tables.keys).subtracting(after.keys)
      let text = WiringTOML.spliced(document, removing: removed, upserting: upserting)
      guard text != document.text else { return nil }
      return try WiringFile.write(
        Data(text.utf8), to: configURL, backupSuffix: backupSuffix, expecting: loaded.stamp)
    }
  }

  /// Once more when the file changed underneath, re-reading from the start — so the second pass
  /// re-runs the collision check against whatever arrived in the window. Twice, not until it
  /// succeeds: a file rewritten faster than this can read it is not a race worth re-entering.
  private func retryingIfChanged<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch WiringFile.WriteError.changedUnderneath(_) {
      return try body()
    }
  }
}
