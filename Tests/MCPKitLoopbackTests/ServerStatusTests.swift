import Foundation
import MCPKit
import Testing

@testable import MCPKitLoopback

@Suite("MCPStatus and MCPActivity")
struct ServerStatusTests {
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func status(
    isAvailable: Bool = true, isEnabled: Bool = true,
    state: LoopbackListener.State = .running(port: 8791),
    served: TimeInterval? = nil, refused: TimeInterval? = nil
  ) -> MCPStatus {
    MCPStatus(
      isAvailable: isAvailable, isEnabled: isEnabled, state: state,
      activity: MCPActivity(
        lastServed: served.map { now.addingTimeInterval(-$0) },
        lastTurnedAway: refused.map { now.addingTimeInterval(-$0) }),
      now: now)
  }

  @Test("Unavailable wins over the switch")
  func unavailableEvenWhenSwitchedOn() {
    #expect(status(isAvailable: false) == .unavailable)
    #expect(status(isAvailable: false, isEnabled: false) == .unavailable)
  }

  @Test("Switched off, it is off whatever the listener last said")
  func off() {
    #expect(status(isEnabled: false) == .off)
  }

  @Test("A failed listener says why")
  func failed() {
    #expect(status(state: .failed("Port in use")) == .failed("Port in use"))
  }

  @Test("Switched on but not bound yet is starting")
  func starting() {
    #expect(status(state: .stopped) == .starting)
  }

  @Test("Listening, with nothing heard yet")
  func listening() {
    #expect(status() == .listening(port: 8791))
  }

  @Test("A request within the window is an agent at work")
  func working() {
    #expect(status(served: 5) == .working(port: 8791))
    #expect(status(served: MCPStatus.workingWindow - 1) == .working(port: 8791))
    #expect(status(served: MCPStatus.workingWindow + 1) == .listening(port: 8791))
    #expect(status(served: 5).isWorking)
    #expect(!status().isWorking)
  }

  /// A client still holding a token Regenerate replaced: the one case where the status should
  /// say setup is wrong, rather than wait for somebody to wonder why the agent sees nothing.
  @Test("A token turned away since the last served request warns")
  func turnedAway() {
    #expect(status(refused: 30) == .turnedAway(port: 8791))
    #expect(status(served: 60, refused: 30) == .turnedAway(port: 8791))
  }

  @Test("A request served since the refusal clears the warning")
  func servedSinceRefusal() {
    #expect(status(served: 10, refused: 30) == .working(port: 8791))
    #expect(status(served: 300, refused: 600) == .listening(port: 8791))
  }

  @Test("Only a missing or wrong token counts as turned away")
  func onlyTokenRefusals() {
    #expect(MCPActivity.Kind(.refused(httpStatus: 401)) == .turnedAway)
    // A browser's page knocking with the wrong Origin, a bad path: nobody's agent.
    #expect(MCPActivity.Kind(.refused(httpStatus: 403)) == nil)
    #expect(MCPActivity.Kind(.refused(httpStatus: 404)) == nil)
  }

  /// Anything past the door was an agent holding the right token, whatever became of it.
  @Test("Every request past the token counts as served")
  func pastTheToken() {
    #expect(MCPActivity.Kind(.served) == .served)
    #expect(MCPActivity.Kind(.accepted) == .served)
    #expect(MCPActivity.Kind(.toolError) == .served)
    #expect(MCPActivity.Kind(.writeGateRefused) == .served)
    #expect(MCPActivity.Kind(.unknownTool) == .served)
    #expect(MCPActivity.Kind(.protocolError(.methodNotFound)) == .served)
  }

  @Test("Recording keeps the latest of each kind")
  func record() {
    var activity = MCPActivity()
    activity.record(.served, at: now)
    activity.record(.turnedAway, at: now.addingTimeInterval(1))
    activity.record(.served, at: now.addingTimeInterval(2))
    #expect(activity.lastServed == now.addingTimeInterval(2))
    #expect(activity.lastTurnedAway == now.addingTimeInterval(1))
  }
}
