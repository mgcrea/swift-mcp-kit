import Foundation
import MCPKit

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// An MCP endpoint on 127.0.0.1, and nothing else.
///
/// ## The bind address is not configurable, ever
///
/// There is no `host` parameter and there must never be one. "Bind address" as a preference
/// is how `0.0.0.0` ends up in a support thread as a workaround, and every protection in
/// `RequestGate` assumes the socket is unreachable from another machine in the first place.
/// The port is a preference; the interface is not.
///
/// ## Threading
///
/// The accept loop runs on a dedicated `Thread` because `accept(2)` blocks, and a blocking
/// syscall on the main thread hangs the app on launch. Each connection also gets its own
/// dedicated thread, which then blocks waiting for the async handler to produce a response.
///
/// Blocking a thread on async work is normally a mistake; here it is safe *because the
/// thread is dedicated*. It belongs to no cooperative pool, so nothing else is starved by
/// it. The one rule that keeps it safe: the handler must never wait on this thread, and in
/// particular an app must never call into this server from the main actor and then have the
/// handler hop back to the main actor. Handlers take a snapshot and leave.
public final class LoopbackListener: @unchecked Sendable {

  public enum State: Sendable, Hashable {
    case stopped
    case running(port: Int)
    case failed(String)
  }

  private let server: MCPServer
  private let gate: RequestGate
  private let allowWrites: @Sendable () -> Bool
  private let budget = ConnectionBudget(limit: 64)

  private let lock = NSLock()
  private var socketFD: Int32 = -1
  private var acceptThread: Thread?
  private var _state: State = .stopped

  /// How long a connection may take to send its request, and to accept its response.
  /// Loopback has no excuse for either taking longer.
  private static let ioTimeout = timeval(tv_sec: 10, tv_usec: 0)

  public init(
    server: MCPServer, gate: RequestGate, allowWrites: @escaping @Sendable () -> Bool
  ) {
    self.server = server
    self.gate = gate
    self.allowWrites = allowWrites
  }

  public var state: State {
    lock.lock()
    defer { lock.unlock() }
    return _state
  }

  // MARK: - Lifecycle

  public func start(port: Int) {
    lock.lock()
    guard case .stopped = _state else {
      lock.unlock()
      return
    }
    lock.unlock()

    // A write to a socket the peer already closed raises SIGPIPE, whose default action is
    // to kill the process. An agent that cancels mid-request would otherwise terminate the
    // app.
    signal(SIGPIPE, SIG_IGN)

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return fail("Could not create a socket.") }

    // Survive a restart on the same port while an old socket is in TIME_WAIT. Deliberately
    // NOT SO_REUSEPORT, which would let a second process silently share the port and take
    // half the requests.
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    // INADDR_LOOPBACK. The one line in this file that must never become a variable.
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian

    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      close(fd)
      return fail(
        "Port \(port) is not available. Another app may be using it — try a different port.")
    }
    guard listen(fd, 32) == 0 else {
      close(fd)
      return fail("Could not listen on port \(port).")
    }

    lock.lock()
    socketFD = fd
    _state = .running(port: port)
    lock.unlock()

    let thread = Thread { [weak self] in self?.acceptLoop(fd) }
    thread.name = "mcp-kit.accept"
    thread.stackSize = 512 * 1024
    acceptThread = thread
    thread.start()
  }

  public func stop() {
    lock.lock()
    let fd = socketFD
    socketFD = -1
    _state = .stopped
    lock.unlock()
    // Closing the listening socket is what breaks the blocking `accept` in the loop.
    if fd >= 0 { close(fd) }
  }

  private func fail(_ message: String) {
    lock.lock()
    _state = .failed(message)
    lock.unlock()
  }

  // MARK: - Accepting

  private func acceptLoop(_ listeningFD: Int32) {
    while true {
      let connection = accept(listeningFD, nil, nil)
      guard connection >= 0 else {
        // The socket was closed by `stop()`, or the process is going down.
        lock.lock()
        let stillRunning = socketFD == listeningFD
        lock.unlock()
        if !stillRunning { return }
        continue
      }
      _ = fcntl(connection, F_SETFD, FD_CLOEXEC)

      // Budget first, thread second. The reverse order pays for the thread before deciding
      // it was not wanted, which is no limit at all under load.
      guard budget.acquire() else {
        write(
          connection,
          HTTPResponse(
            status: 503, headers: ["Retry-After": "1"], body: Data("busy".utf8)
          ).serialized)
        close(connection)
        continue
      }

      let thread = Thread { [weak self] in
        defer {
          close(connection)
          self?.budget.release()
        }
        self?.serve(connection)
      }
      thread.name = "mcp-kit.connection"
      thread.stackSize = 512 * 1024
      thread.start()
    }
  }

  private func serve(_ fd: Int32) {
    var timeout = Self.ioTimeout
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var buffer: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)

    while true {
      let read = recv(fd, &chunk, chunk.count, 0)
      if read <= 0 { return }
      buffer.append(contentsOf: chunk[0..<read])

      switch HTTPParser.parse(buffer) {
      case .incomplete:
        guard buffer.count <= HTTPParser.maxBodyBytes + 64 * 1024 else { return }
        continue
      case .malformed(let reason):
        write(
          fd,
          HTTPResponse.fault(
            MCPFault(httpStatus: 400, code: .parseError, message: reason)
          ).serialized)
        return
      case .complete(let head, let body):
        write(fd, respond(head: head, body: body).serialized)
        return
      }
    }
  }

  // MARK: - Answering

  private func respond(head: HTTPRequestHead, body: Data) -> HTTPResponse {
    if let refusal = gate.check(head) { return refusal }

    let request: MCPRequest
    switch Dialect.parse(headers: head.headers, body: body) {
    case .success(let parsed): request = parsed
    case .failure(let fault): return .fault(fault)
    }

    // Hop onto the cooperative pool for the handler and block *this* thread until it is
    // done. Safe only because this thread is dedicated to one connection and owns nothing
    // anybody else waits for. See the note on threading at the top of this file.
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResponseBox()
    let server = self.server
    let allowWrites = self.allowWrites()
    Task {
      box.value = await server.respond(to: request, allowWrites: allowWrites)
      semaphore.signal()
    }
    semaphore.wait()

    guard let response = box.value else {
      return .fault(
        MCPFault(httpStatus: 500, code: .internalError, message: "The handler returned nothing."))
    }
    guard let payload = response.body else {
      // A notification: 202 and no body, per the transport.
      return HTTPResponse(status: 202)
    }
    return HTTPResponse(
      status: response.httpStatus,
      headers: ["Content-Type": "application/json"],
      body: MCPJSON.data(payload))
  }

  private func write(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var sent = 0
      while sent < raw.count {
        let n = send(fd, base.advanced(by: sent), raw.count - sent, 0)
        if n <= 0 { return }
        sent += n
      }
    }
  }
}

/// A one-shot slot for handing a value off a `Task`. Guarded by the semaphore that the
/// waiting thread blocks on, which is what makes the unchecked conformance true.
private final class ResponseBox: @unchecked Sendable {
  var value: MCPResponse?
}
