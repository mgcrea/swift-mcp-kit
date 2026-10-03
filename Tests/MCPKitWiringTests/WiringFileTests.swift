import Foundation
import Testing

@testable import MCPKitWiring

/// A directory of its own per test, so suites run in parallel without sharing a config.
func scratchDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "mcpkit-wiring-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func permissions(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Suite("WiringFile")
struct WiringFileTests {

  @Test("A new file is created with its directory, at 0600, with no backup")
  func createsPrivately() throws {
    let url = try scratchDirectory().appending(path: "nested/config.json")
    let backup = try WiringFile.write(Data("{}".utf8), to: url, backupSuffix: "test-backup")
    #expect(backup == nil)
    #expect(try permissions(url) == 0o600)
  }

  /// The backup holds the previous bearer token, so it must not stay as readable as the file
  /// it was copied from.
  @Test("Replacing a file keeps its previous bytes in a 0600 backup")
  func backsUp() throws {
    let url = try scratchDirectory().appending(path: "config.json")
    try Data("old".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

    let backup = try #require(
      try WiringFile.write(Data("new".utf8), to: url, backupSuffix: "test-backup"))
    #expect(try String(contentsOf: backup, encoding: .utf8) == "old")
    #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    #expect(try permissions(backup) == 0o600)
    #expect(try permissions(url) == 0o600)
  }

  @Test("A write that changes nothing leaves no backup behind")
  func skipsNoOp() throws {
    let url = try scratchDirectory().appending(path: "config.json")
    try Data("same".utf8).write(to: url)
    #expect(try WiringFile.write(Data("same".utf8), to: url, backupSuffix: "test-backup") == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path + ".test-backup"))
  }

  @Test("A file changed since it was stamped is refused, and left as it is")
  func refusesChangedFile() throws {
    let url = try scratchDirectory().appending(path: "config.json")
    try Data("one".utf8).write(to: url)
    let stamp = WiringFile.stamp(of: url)
    try Data("two, and longer".utf8).write(to: url)

    #expect(throws: WiringFile.WriteError.changedUnderneath(url)) {
      try WiringFile.write(Data("three".utf8), to: url, backupSuffix: "b", expecting: stamp)
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == "two, and longer")
  }

  @Test("A file that appeared after an absent stamp is refused")
  func refusesAppearedFile() throws {
    let url = try scratchDirectory().appending(path: "config.json")
    let stamp = WiringFile.stamp(of: url)
    #expect(stamp == .absent)
    try Data("created meanwhile".utf8).write(to: url)

    #expect(throws: WiringFile.WriteError.changedUnderneath(url)) {
      try WiringFile.write(Data("ours".utf8), to: url, backupSuffix: "b", expecting: stamp)
    }
  }

  @Test("A JSON array is not a config")
  func refusesNonObject() throws {
    let url = try scratchDirectory().appending(path: "config.json")
    try Data("[1, 2]".utf8).write(to: url)
    #expect(throws: WiringFile.ReadError.notJSONObject(url)) { try WiringFile.readJSON(url) }
  }

  // MARK: - A config that is a symlink

  /// A config kept in a dotfiles repository and linked into place: `dotfiles/config.json` is
  /// the file, `config.json` beside it in the scratch directory is the path the client reads.
  private func linkedConfig(holding contents: String) throws -> (link: URL, file: URL) {
    let root = try scratchDirectory()
    let dotfiles = root.appending(path: "dotfiles", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    let file = dotfiles.appending(path: "config.json")
    let link = root.appending(path: "config.json")
    try Data(contents.utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    return (link, file)
  }

  @Test("A symlinked config is written through, and the link is left a link")
  func writesThroughSymlink() throws {
    let (link, file) = try linkedConfig(holding: "old")
    try WiringFile.write(
      Data("new".utf8), to: link, backupSuffix: "test-backup",
      expecting: WiringFile.stamp(of: link))

    #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == file.path)
    #expect(try permissions(file) == 0o600)
  }

  /// Beside the configured path, not beside the file: inside a dotfiles repository a stray
  /// backup holding a bearer token is one `git add .` from being published.
  @Test("The backup of a symlinked config is a copy of the old bytes, beside the link")
  func backsUpSymlinkTarget() throws {
    let (link, file) = try linkedConfig(holding: "old")
    let backup = try #require(
      try WiringFile.write(Data("new".utf8), to: link, backupSuffix: "test-backup"))

    #expect(backup == link.appendingPathExtension("test-backup"))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: backup.path)) == nil)
    #expect(try String(contentsOf: backup, encoding: .utf8) == "old")
    #expect(try permissions(backup) == 0o600)
    #expect(
      !FileManager.default.fileExists(
        atPath: file.appendingPathExtension("test-backup").path))
  }

  @Test("The stamp of a symlinked config is the file's, and moves when the file does")
  func stampsSymlinkTarget() throws {
    let (link, file) = try linkedConfig(holding: "one")
    #expect(WiringFile.stamp(of: link) == WiringFile.stamp(of: file))

    let before = WiringFile.stamp(of: link)
    try Data("two, and longer".utf8).write(to: file)
    #expect(WiringFile.stamp(of: link) != before)
    #expect(throws: WiringFile.WriteError.changedUnderneath(link)) {
      try WiringFile.write(Data("three".utf8), to: link, backupSuffix: "b", expecting: before)
    }
  }

  // MARK: - A config that reads as empty

  /// Empty is also what a config looks like halfway through another process rewriting it —
  /// truncate, then write.
  @Test("A config empty at first read and filled a moment later is read as what it became")
  func rereadsEmptyJSON() throws {
    let url = try scratchDirectory().appending(path: "config.json")
    try Data().write(to: url)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      try? Data(#"{"theirs":1}"#.utf8).write(to: url)
    }
    #expect(try WiringFile.readJSON(url)["theirs"] as? Int == 1)
  }

  @Test("A config that stays empty is still an empty object")
  func emptyStaysEmpty() throws {
    let url = try scratchDirectory().appending(path: "config.json")
    try Data().write(to: url)
    #expect(try WiringFile.readJSON(url).isEmpty)
  }

  @Test("A TOML config empty at first read and filled a moment later keeps what it became")
  func rereadsEmptyTOML() throws {
    let url = try scratchDirectory().appending(path: "config.toml")
    try Data().write(to: url)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      try? Data("model = \"theirs\"\n".utf8).write(to: url)
    }
    #expect(try WiringTOML.read(url).text == "model = \"theirs\"\n")
  }
}
