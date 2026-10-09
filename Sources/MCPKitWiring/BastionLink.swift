import Foundation

#if os(macOS)
  import AppKit
#elseif targetEnvironment(macCatalyst)
  import UIKit
#endif

/// Handing a loopback server to Bastion, which then stands in front of it: the token kept in
/// its Keychain rather than in every client's config, each call a line in its Activity window,
/// and its own write switch over the tools named in `writeTools`.
///
/// A link rather than a file write, because the app on the other end of a file write would be
/// Bastion's own configuration, which a sandboxed app cannot reach and no app should edit
/// behind Bastion's back. A link is something a sandboxed app may open, and it asks: Bastion
/// shows what it was handed and adds nothing until the person confirms.
///
/// Both ends use this type, the app to build the link and Bastion to read it, so the two cannot
/// drift apart on a field name.
public struct BastionLink: Hashable, Sendable {
  public static let scheme = "bastion"
  public static let action = "add-server"
  /// The version of the link's fields. A reader refuses a version it does not know rather than
  /// guess at what a newer field meant.
  public static let version = 1

  /// Bastion's own bundle identifiers, release first. A link is opened only in one of these:
  /// any app may claim the `bastion` scheme, and the link carries a token.
  public static let bundleIdentifiers = ["io.mgcrea.bastion", "io.mgcrea.bastion.debug"]

  /// Where somebody who has not heard of Bastion finds out what it is.
  public static let website = URL(string: "https://bastion.mgcrea.io")!

  /// The server's id in Bastion: kebab case, and part of every tool name a model reads through
  /// it, so the app's short name and nothing more.
  public let id: String
  /// What Bastion's window calls it.
  public let displayName: String
  /// `http://127.0.0.1:<port>/mcp`. Loopback by its literal address only, as Bastion requires:
  /// `localhost` can be made to resolve elsewhere.
  public let url: String
  /// The bearer token, which Bastion sends as `Authorization: Bearer <token>`.
  public let token: String
  /// One line on what the server does.
  public let summary: String?
  /// The tools that change data, which Bastion holds back while its write switch is off.
  public let writeTools: [String]

  public init(
    id: String, displayName: String, url: String, token: String, summary: String? = nil,
    writeTools: [String] = []
  ) {
    self.id = id
    self.displayName = displayName
    self.url = url
    self.token = token
    self.summary = summary
    self.writeTools = writeTools
  }

  /// The link for a server already described for the other clients.
  public init(
    _ server: WiredServer, displayName: String, summary: String? = nil, writeTools: [String] = []
  ) {
    self.init(
      id: server.key, displayName: displayName, url: server.url, token: server.token,
      summary: summary, writeTools: writeTools)
  }

  /// What is wrong with a link, in words the confirmation sheet can show.
  public enum Problem: Error, Equatable, Sendable, LocalizedError {
    case notABastionLink
    case unknownVersion(String?)
    case missing(String)
    case badID(String)
    case notLoopback(String)

    public var errorDescription: String? {
      switch self {
      case .notABastionLink: "This is not a link for adding a server to Bastion."
      case .unknownVersion(let version):
        "The link is from a newer version of the app (\(version ?? "no version")). Update Bastion."
      case .missing(let field): "The link has no \(field)."
      case .badID(let id): "“\(id)” is not a server id: lowercase letters, digits and dashes."
      case .notLoopback(let url):
        "\(url) is not a server on this Mac. Only http://127.0.0.1 or http://[::1] are added this way."
      }
    }
  }

  /// `bastion://add-server?v=1&id=…&name=…&url=…&token=…&summary=…&write_tools=a,b`
  public var link: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = Self.action
    var items = [
      URLQueryItem(name: "v", value: String(Self.version)),
      URLQueryItem(name: "id", value: id),
      URLQueryItem(name: "name", value: displayName),
      URLQueryItem(name: "url", value: url),
      URLQueryItem(name: "token", value: token),
    ]
    if let summary { items.append(URLQueryItem(name: "summary", value: summary)) }
    if !writeTools.isEmpty {
      items.append(URLQueryItem(name: "write_tools", value: writeTools.joined(separator: ",")))
    }
    components.queryItems = items
    // `URLQueryItem` leaves `+`, `&` and `=` inside a value alone; a token or a summary may hold
    // any of them, and a reader would split on them.
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return components.url!
  }

  /// Reads a link back, refusing anything Bastion should not be asked to add.
  public init(link: URL) throws(Problem) {
    guard let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == Self.scheme, components.host == Self.action
    else { throw .notABastionLink }
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? {
      items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
    guard value("v") == String(Self.version) else { throw .unknownVersion(value("v")) }
    guard let id = value("id") else { throw .missing("server id") }
    guard Self.isID(id) else { throw .badID(id) }
    guard let url = value("url") else { throw .missing("server URL") }
    guard Self.isLiteralLoopback(url) else { throw .notLoopback(url) }
    guard let token = value("token") else { throw .missing("token") }
    self.init(
      id: id, displayName: value("name") ?? id, url: url, token: token,
      summary: value("summary"),
      writeTools: value("write_tools")?.split(separator: ",").map(String.init) ?? [])
  }

  static func isID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64 && !id.hasPrefix("-") && !id.hasSuffix("-")
      && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
  }

  /// http or https to `127.0.0.1` or `[::1]` with a port: never `localhost`, which a hosts file
  /// can point anywhere.
  static func isLiteralLoopback(_ url: String) -> Bool {
    guard let components = URLComponents(string: url),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      components.port != nil, components.user == nil, components.password == nil
    else { return false }
    return ["127.0.0.1", "::1", "[::1]"].contains(components.host ?? "")
  }

  #if os(macOS) || targetEnvironment(macCatalyst)
    /// Where Bastion is installed, the release build before a development one.
    @MainActor
    public static var installedApplication: URL? {
      bundleIdentifiers.lazy.compactMap(Workspace.application(bundleIdentifier:)).first
    }

    /// Opens the link in Bastion itself, and only there, which then asks the person before
    /// adding anything. Throws when Bastion is not installed.
    @MainActor
    public func open() async throws {
      let notInstalled = Self.failure("Bastion is not installed on this Mac.")
      #if os(macOS)
        guard let application = Self.installedApplication else { throw notInstalled }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(
          [link], withApplicationAt: application, configuration: configuration)
      #else
        // UIKit cannot name the app a link opens in: it goes to whichever app claimed the
        // scheme. So it is opened only when that app is one of Bastion's, since it carries the
        // token.
        let installed = Self.bundleIdentifiers.compactMap(Workspace.application(bundleIdentifier:))
        guard !installed.isEmpty else { throw notInstalled }
        guard let handler = Workspace.application(toOpen: link),
          installed.contains(where: { $0.standardizedFileURL == handler.standardizedFileURL })
        else {
          throw Self.failure(
            "Another app on this Mac opens bastion links, so the link, which carries the token, "
              + "was not opened.")
        }
        guard await UIApplication.shared.open(link) else {
          throw Self.failure("Bastion did not open the link.")
        }
      #endif
    }

    private static func failure(_ message: String) -> CocoaError {
      CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: message])
    }
  #endif
}
