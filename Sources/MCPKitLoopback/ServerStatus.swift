import Foundation
import MCPKit

/// When an agent last reached the server, and when one was last turned away for its token.
///
/// Not a connection: each request stands alone over loopback HTTP, so there is no session to
/// call connected. When the last request came is the honest version of it. Fed from the
/// listener's `AuditSink`, which runs on a connection's thread; the app hops to wherever its
/// copy lives before calling `record`.
public struct MCPActivity: Equatable, Sendable {
  public var lastServed: Date?
  public var lastTurnedAway: Date?

  public init(lastServed: Date? = nil, lastTurnedAway: Date? = nil) {
    self.lastServed = lastServed
    self.lastTurnedAway = lastTurnedAway
  }

  public enum Kind: Equatable, Sendable {
    /// Past the token, whatever became of it: an agent holding the right one asked.
    case served
    /// No token, or not the current one: a client set up before a Regenerate.
    case turnedAway

    /// `nil` for a refusal that says nothing about anybody's setup: a web page knocking with
    /// its own Origin, a wrong path or method.
    public init?(_ outcome: AuditOutcome) {
      switch outcome {
      case .refused(httpStatus: 401): self = .turnedAway
      case .refused: return nil
      case .served, .accepted, .toolError, .writeGateRefused, .unknownTool, .protocolError:
        self = .served
      }
    }
  }

  public mutating func record(_ kind: Kind, at date: Date) {
    switch kind {
    case .served: lastServed = date
    case .turnedAway: lastTurnedAway = date
    }
  }
}

/// What an app shows of its server at a glance: from its switch, whether the server is
/// available at all (a purchase, a platform), the listener, and what it heard.
public enum MCPStatus: Equatable, Sendable {
  /// The app does not offer the server here: not bought, say.
  case unavailable
  case off
  /// Switched on, and not bound yet.
  case starting
  case listening(port: Int)
  /// A request served within `workingWindow`.
  case working(port: Int)
  /// The latest request with a token was turned away for it, and none was served since.
  case turnedAway(port: Int)
  case failed(String)

  /// Long enough to span an agent thinking between two calls.
  public static let workingWindow: TimeInterval = 60

  public init(
    isAvailable: Bool, isEnabled: Bool, state: LoopbackListener.State, activity: MCPActivity,
    now: Date
  ) {
    guard isAvailable else {
      self = .unavailable
      return
    }
    guard isEnabled else {
      self = .off
      return
    }
    switch state {
    case .stopped:
      self = .starting
    case .failed(let message):
      self = .failed(message)
    case .running(let port):
      if let refused = activity.lastTurnedAway,
        activity.lastServed.map({ $0 < refused }) ?? true
      {
        self = .turnedAway(port: port)
      } else if let served = activity.lastServed,
        now.timeIntervalSince(served) <= Self.workingWindow
      {
        self = .working(port: port)
      } else {
        self = .listening(port: port)
      }
    }
  }

  public var isWorking: Bool {
    if case .working = self { return true }
    return false
  }
}
