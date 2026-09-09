import Foundation

/// What became of one request.
public enum AuditOutcome: Sendable, Hashable {
  /// An ordinary answer.
  case served
  /// A notification, acknowledged with no body.
  case accepted
  /// The tool ran and reported a failure of its own.
  case toolError
  /// A gated tool was called while writes were off. The line worth having: it says an agent
  /// tried, which a plain `toolError` would bury among ordinary failures.
  case writeGateRefused
  case unknownTool
  /// The frame never reached a tool — bad version, header mismatch, unknown method.
  case protocolError(MCPErrorCode)
  /// Refused by the transport before the protocol saw it: bad host, bad origin, no token.
  case refused(httpStatus: Int)
}

/// One line about one request.
///
/// Note what this type **cannot** carry: arguments, or any part of a request body. That is
/// the point of it being a type rather than a closure over the frame. A tool that takes a
/// secret — a token, a key, a password — must be auditable without the audit becoming the
/// place that secret finally gets written down, and the only reliable way to guarantee that
/// is for the argument never to be reachable from here.
public struct AuditEntry: Sendable, Hashable {

  /// The JSON-RPC method, when the frame parsed far enough to have one.
  public let method: String?
  /// The tool, prompt or resource addressed. A name, never a value.
  public let name: String?
  /// Who the **token** said this was. Authenticated, and therefore usable.
  public let client: String?
  /// Who the request said it was, from `_meta`.
  ///
  /// Self-reported and trivially forged, so it is kept apart from `client` rather than
  /// merged into it. Useful for telling two editors apart in a log; never an input to a
  /// decision.
  public let declaredClient: String?
  public let protocolVersion: MCPVersion?
  public let outcome: AuditOutcome
  public let durationMs: Int

  public init(
    method: String?, name: String?, client: String?, declaredClient: String?,
    protocolVersion: MCPVersion?, outcome: AuditOutcome, durationMs: Int
  ) {
    self.method = method
    self.name = name
    self.client = client
    self.declaredClient = declaredClient
    self.protocolVersion = protocolVersion
    self.outcome = outcome
    self.durationMs = durationMs
  }
}

/// Where audit lines go. Called once per request, on the connection's own thread, so it must
/// not block for long and must be safe to call concurrently.
public typealias AuditSink = @Sendable (AuditEntry) -> Void
