import Foundation

/// A hard ceiling on concurrent connections, acquired **before** a thread is created.
///
/// The ordering is the whole point. A server that spawns the thread and then decides it is
/// over budget has already paid for the thread, so a flood costs exactly as much as if
/// there were no limit at all.
final class ConnectionBudget: @unchecked Sendable {
  private let limit: Int
  private var inFlight = 0
  private let lock = NSLock()

  init(limit: Int) { self.limit = limit }

  /// Take a slot, or `false` when there is none.
  func acquire() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard inFlight < limit else { return false }
    inFlight += 1
    return true
  }

  func release() {
    lock.lock()
    defer { lock.unlock() }
    inFlight = max(0, inFlight - 1)
  }

  var current: Int {
    lock.lock()
    defer { lock.unlock() }
    return inFlight
  }
}
