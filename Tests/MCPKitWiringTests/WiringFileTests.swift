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
}
