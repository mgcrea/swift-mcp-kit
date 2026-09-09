import Foundation
import Security

/// The bearer token, kept in the Keychain.
///
/// Two properties matter more than the storage:
///
/// - **It is generated, never chosen.** 256 bits from the system CSPRNG. A user-chosen
///   token on a port any local process can reach is a password, and this is not a login.
/// - **A failure to read is not a failure to match.** `verdict(for:)` distinguishes "no"
///   from "I cannot tell", so a locked Keychain is reported as `503` rather than as a bad
///   credential the user is then told to regenerate.
public final class KeychainTokenStore: @unchecked Sendable {

  private let service: String
  private let account: String
  private let lock = NSLock()
  private var cached: String?

  public init(service: String, account: String = "mcp-server-token") {
    self.service = service
    self.account = account
  }

  /// The current token, minting one on first use.
  public func current() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    if let cached { return cached }
    if let stored = try read() {
      cached = stored
      return stored
    }
    let fresh = Self.mint()
    try write(fresh)
    cached = fresh
    return fresh
  }

  /// Replace the token. Any client holding the old one stops working, which is the point.
  @discardableResult
  public func regenerate() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    let fresh = Self.mint()
    try write(fresh)
    cached = fresh
    return fresh
  }

  /// Whether a presented token is the one on file.
  public func verdict(for presented: String?) -> TokenVerdict {
    guard let presented, !presented.isEmpty else { return .rejected }
    guard let expected = try? current() else { return .unavailable }
    return constantTimeEquals(presented, expected) ? .accepted(client: nil) : .rejected
  }

  // MARK: - Minting

  private static func mint() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    // There is no safe fallback. A token from a degraded source looks exactly like a good
    // one and is the whole security of the endpoint, so failing loudly here is the only
    // honest option.
    precondition(status == errSecSuccess, "The system CSPRNG failed; refusing to mint a token.")
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  // MARK: - Keychain

  public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
      "The keychain refused the request (status \(status))."
    }
  }

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private func read() throws -> String? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw KeychainError(status: status)
    }
    return String(data: data, encoding: .utf8)
  }

  private func write(_ token: String) throws {
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = Data(token.utf8)
    // The token is only useful while this Mac is unlocked and the app is running, so it
    // does not need to survive into a locked device and should not be in a backup.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }
}
