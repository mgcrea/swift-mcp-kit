import Foundation

/// Reading and writing a client's config file, which belongs to another application.
///
/// Ported from Bastion, where it was `ClientWiringMerge` and Cupertino carried a copy. Four
/// properties every write here holds, because the file is somebody else's: every unrelated key
/// survives, the previous contents are recoverable, a crash mid-write cannot leave a truncated
/// file, and a change computed from bytes that have since been replaced is refused rather than
/// landed.
public enum WiringFile {

  public enum ReadError: LocalizedError, Equatable {
    case notJSONObject(URL)

    public var errorDescription: String? {
      switch self {
      case .notJSONObject(let url):
        return "\(url.lastPathComponent) is not a JSON object; leaving it alone"
      }
    }
  }

  public enum WriteError: LocalizedError, Equatable {
    /// The file moved on between the read and the swap, so the change in hand was computed
    /// from bytes that are no longer there.
    case changedUnderneath(URL)

    public var errorDescription: String? {
      switch self {
      case .changedUnderneath(let url):
        return "\(url.lastPathComponent) changed while it was being read; nothing was written"
      }
    }
  }

  /// An empty file reads as an empty object: it is what some clients leave behind, and
  /// refusing it would make a client unconfigurable for want of two braces.
  public static func readJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    if data.isEmpty { return [:] }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ReadError.notJSONObject(url)
    }
    return object
  }

  /// What a file looked like when the caller read it.
  ///
  /// Size and modification date rather than a hash: the only question is "did anything touch
  /// it", which two `stat` fields answer for free. `absent` is a state, not an error — a file
  /// created in the window between read and write is precisely what this exists to catch.
  public enum Stamp: Equatable, Sendable {
    case absent
    case present(size: Int, modified: Date)
  }

  /// `FileManager`, not `URL.resourceValues`: an `NSURL` caches the values it was already asked
  /// for, so two stamps taken from one `URL` around a write come back identical and the
  /// precondition silently passes.
  public static func stamp(of url: URL) -> Stamp {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
    else { return .absent }
    return .present(size: size, modified: modified)
  }

  /// Backup, temp file beside the target, swap. Returns the backup's URL when one was made.
  ///
  /// `expecting` narrows a race rather than closing it: a process holding its own copy of the
  /// file — Claude Code for the length of a session, the ChatGPT app on launch — still wins by
  /// writing after this. Nothing short of a lock neither side takes would change that.
  ///
  /// The file ends at 0600, and so does its backup. Every entry this package writes carries a
  /// bearer token, and a copy inherits the mode of what it copied: a backup of a world-readable
  /// config would otherwise keep the previous token readable, somewhere nobody thinks to look.
  @discardableResult
  public static func write(
    _ data: Data, to url: URL, backupSuffix: String, expecting: Stamp? = nil
  ) throws -> URL? {
    let fm = FileManager.default

    // Before the backup: a write that is not going to happen must not leave one behind.
    if let expecting, stamp(of: url) != expecting { throw WriteError.changedUnderneath(url) }
    // Neither must a write that changes nothing — a new backup, a new mtime, and a client
    // told to reload, for no reason.
    if let current = try? Data(contentsOf: url), current == data { return nil }

    var backup: URL?
    if fm.fileExists(atPath: url.path) {
      let copy = url.appendingPathExtension(backupSuffix)
      try? fm.removeItem(at: copy)
      try fm.copyItem(at: url, to: copy)
      try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
      backup = copy
    } else {
      try fm.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    let temp = url.deletingLastPathComponent()
      .appendingPathComponent(".mcpkit-\(UUID().uuidString).tmp")
    try data.write(to: temp, options: .atomic)
    do {
      _ = try fm.replaceItemAt(url, withItemAt: temp)
    } catch {
      // `replaceItemAt` consumes the temp on success only.
      try? fm.removeItem(at: temp)
      throw error
    }
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return backup
  }

  /// The JSON half: serialise, then write the bytes.
  @discardableResult
  public static func write(
    json root: [String: Any], to url: URL, backupSuffix: String, expecting: Stamp? = nil
  ) throws -> URL? {
    try write(
      JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      to: url, backupSuffix: backupSuffix, expecting: expecting)
  }
}
