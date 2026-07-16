import Darwin
import Foundation
import XCTest

@testable import LogiLiquidControl

final class UnixControlTransportTests: XCTestCase {
  func testRequestResponseRoundTripUsesStableEnvelope() throws {
    let fixture = try Fixture { request in
      XCTAssertEqual(request.method, .status)
      XCTAssertEqual(request.params, ["verbose": true])
      return ["state": "ready", "pid": .integer(42)]
    }
    defer { fixture.close() }

    let response = try fixture.client.request(
      method: .status,
      params: ["verbose": true],
      requestID: "round-trip"
    )

    XCTAssertEqual(response.schemaVersion, LogiLiquidControlProtocol.schemaVersion)
    XCTAssertEqual(response.requestID, "round-trip")
    XCTAssertEqual(response.result, ["state": "ready", "pid": .integer(42)])
    XCTAssertNil(response.error)

    let encoded = try JSONEncoder().encode(response)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    XCTAssertEqual(Set(object.keys), ["schemaVersion", "requestID", "result", "error"])
    XCTAssertTrue(object["error"] is NSNull)
  }

  func testMalformedAndOversizeFramesReturnOnlyStructuredNDJSONErrors() throws {
    let fixture = try Fixture(maximumFrameBytes: 256) { _ in .null }
    defer { fixture.close() }

    do {
      let connection = try fixture.rawConnection(maximumFrameBytes: 1_024)
      defer { connection.close() }
      try connection.sendRaw(Data("not-json\n".utf8))
      let frame = try XCTUnwrap(connection.readFrame())
      let response = try JSONDecoder().decode(ControlResponse.self, from: frame)
      XCTAssertEqual(response.requestID, "")
      XCTAssertEqual(response.error?.code, "invalid_request")
    }

    do {
      let connection = try fixture.rawConnection(maximumFrameBytes: 1_024)
      defer { connection.close() }
      var oversized = Data(repeating: UInt8(ascii: "x"), count: 257)
      oversized.append(0x0A)
      try connection.sendRaw(oversized)
      let frame = try XCTUnwrap(connection.readFrame())
      let response = try JSONDecoder().decode(ControlResponse.self, from: frame)
      XCTAssertEqual(response.error?.code, "frame_too_large")
      XCTAssertNil(try connection.readFrame())
    }
  }

  func testConcurrentClientsAreSerializedThroughOneHandlerQueue() throws {
    let probe = SerializationProbe()
    let fixture = try Fixture { request in
      probe.enter()
      defer { probe.leave() }
      usleep(20_000)
      return ["request": .string(request.requestID)]
    }
    defer { fixture.close() }

    let group = DispatchGroup()
    for index in 0..<10 {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        defer { group.leave() }
        do {
          let response = try fixture.client.request(
            method: .doctor,
            requestID: "request-\(index)"
          )
          if response.error == nil {
            probe.recordSuccess()
          }
        } catch {
          probe.recordFailure()
        }
      }
    }

    XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(probe.successCount, 10)
    XCTAssertEqual(probe.failureCount, 0)
    XCTAssertEqual(probe.peakActiveCount, 1)
  }

  func testFollowAcknowledgementThenReceivesNDJSONEvents() throws {
    let fixture = try Fixture { request in
      ["following": .string(request.method.rawValue)]
    }
    defer { fixture.close() }

    let subscription = try fixture.client.subscribe(
      method: .eventsFollow,
      requestID: "event-stream"
    )
    XCTAssertEqual(
      subscription.acknowledgement.result,
      ["following": "events.follow"]
    )
    XCTAssertTrue(waitUntil { fixture.server.activeSubscriptionCount == 1 })

    fixture.server.publish(
      stream: .events,
      event: "ring.invoked",
      payload: ["source": "simulation"]
    )
    XCTAssertEqual(
      try subscription.next(),
      ControlEvent(
        requestID: "event-stream",
        event: "ring.invoked",
        payload: ["source": "simulation"]
      )
    )
  }

  func testDisconnectRemovesSubscriptionsAndConnections() throws {
    let fixture = try Fixture { _ in .null }
    defer { fixture.close() }

    let subscription = try fixture.client.subscribe(method: .reportsFollow)
    XCTAssertTrue(
      waitUntil {
        fixture.server.activeSubscriptionCount == 1
          && fixture.server.activeConnectionCount == 1
      })

    subscription.cancel()

    XCTAssertTrue(
      waitUntil {
        fixture.server.activeSubscriptionCount == 0
          && fixture.server.activeConnectionCount == 0
      })
  }

  func testStalledStreamIsDroppedWithoutBlockingPublishOrShutdownCleanup() throws {
    let writerGate = StreamWriterGate()
    let fixture = try Fixture(
      maximumPendingStreamFrames: 1,
      beforeStreamSend: { writerGate.blockUntilReleased() },
      handler: { _ in .null }
    )
    defer {
      writerGate.release()
      fixture.close()
    }

    let subscription = try fixture.client.subscribe(
      method: .reportsFollow,
      requestID: "stalled-reports"
    )
    defer { subscription.cancel() }
    XCTAssertTrue(waitUntil { fixture.server.activeSubscriptionCount == 1 })

    let firstPublishReturned = expectation(description: "first publish returned")
    DispatchQueue.global(qos: .userInitiated).async {
      fixture.server.publish(
        stream: .reports,
        event: "hid.report",
        payload: ["sequence": 1]
      )
      firstPublishReturned.fulfill()
    }
    wait(for: [firstPublishReturned], timeout: 0.5)
    XCTAssertTrue(writerGate.waitUntilBlocked(timeout: 0.5))

    let overflowPublishReturned = expectation(description: "overflow publish returned")
    DispatchQueue.global(qos: .userInitiated).async {
      fixture.server.publish(
        stream: .reports,
        event: "hid.report",
        payload: ["sequence": 2]
      )
      overflowPublishReturned.fulfill()
    }
    wait(for: [overflowPublishReturned], timeout: 0.5)

    XCTAssertTrue(
      waitUntil {
        fixture.server.activeSubscriptionCount == 0
          && fixture.server.activeConnectionCount == 0
      }
    )

    let shutdownCleanupReached = expectation(description: "shutdown cleanup reached")
    DispatchQueue.global(qos: .userInitiated).async {
      fixture.server.stop()
      shutdownCleanupReached.fulfill()
    }
    wait(for: [shutdownCleanupReached], timeout: 0.5)
    XCTAssertFalse(fixture.server.isRunning)
  }

  func testSocketDirectoryAndEndpointArePrivateAndStaleSocketIsRecovered() throws {
    let directory = URL(
      filePath: "/tmp/logi-liquid-control-\(UUID().uuidString.prefix(8))",
      directoryHint: .isDirectory
    )
    let socketURL =
      directory
      .appending(path: "private", directoryHint: .isDirectory)
      .appending(path: "control.sock", directoryHint: .notDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(
      at: socketURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let stale = try createUnixSocket()
    try bindUnixSocket(stale, path: socketURL.path)
    Darwin.close(stale)

    let server = UnixControlServer(socketURL: socketURL) { _ in .null }
    try server.start()
    defer { server.stop() }

    var directoryInfo = stat()
    var socketInfo = stat()
    XCTAssertEqual(lstat(socketURL.deletingLastPathComponent().path, &directoryInfo), 0)
    XCTAssertEqual(lstat(socketURL.path, &socketInfo), 0)
    XCTAssertEqual(directoryInfo.st_mode & 0o777, 0o700)
    XCTAssertEqual(socketInfo.st_mode & 0o777, 0o600)
    XCTAssertEqual(directoryInfo.st_uid, getuid())
    XCTAssertEqual(socketInfo.st_uid, getuid())

    let secondServer = UnixControlServer(socketURL: socketURL) { _ in .null }
    XCTAssertThrowsError(try secondServer.start()) { error in
      XCTAssertEqual(
        error as? ControlTransportError,
        .socketAlreadyInUse(socketURL.path)
      )
    }
  }
}

private final class Fixture: @unchecked Sendable {
  let directory: URL
  let socketURL: URL
  let server: UnixControlServer
  let client: UnixControlClient

  init(
    maximumFrameBytes: Int = LogiLiquidControlProtocol.defaultMaximumFrameBytes,
    maximumPendingStreamFrames: Int =
      UnixControlServer.defaultMaximumPendingStreamFrames,
    beforeStreamSend: @escaping @Sendable () -> Void = {},
    handler: @escaping UnixControlServer.Handler
  ) throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    socketURL =
      directory
      .appending(path: "run", directoryHint: .isDirectory)
      .appending(path: "control.sock", directoryHint: .notDirectory)
    server = UnixControlServer(
      socketURL: socketURL,
      maximumFrameBytes: maximumFrameBytes,
      maximumPendingStreamFrames: maximumPendingStreamFrames,
      beforeStreamSend: beforeStreamSend,
      handler: handler
    )
    client = UnixControlClient(
      socketURL: socketURL,
      maximumFrameBytes: maximumFrameBytes
    )
    try server.start()
  }

  func rawConnection(maximumFrameBytes: Int) throws -> SocketFrameIO {
    let fileDescriptor = try createUnixSocket()
    do {
      try connectUnixSocket(fileDescriptor, path: socketURL.path)
      return try SocketFrameIO(
        fileDescriptor: fileDescriptor,
        maximumFrameBytes: maximumFrameBytes
      )
    } catch {
      Darwin.close(fileDescriptor)
      throw error
    }
  }

  func close() {
    server.stop()
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class StreamWriterGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var blocked = false
  private var released = false

  func blockUntilReleased() {
    condition.lock()
    blocked = true
    condition.broadcast()
    while !released {
      condition.wait()
    }
    condition.unlock()
  }

  func waitUntilBlocked(timeout: TimeInterval) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    while !blocked {
      guard condition.wait(until: deadline) else { return blocked }
    }
    return true
  }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
}

private final class SerializationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private var peak = 0
  private var successes = 0
  private var failures = 0

  var peakActiveCount: Int { locked { peak } }
  var successCount: Int { locked { successes } }
  var failureCount: Int { locked { failures } }

  func enter() {
    locked {
      active += 1
      peak = max(peak, active)
    }
  }

  func leave() {
    locked { active -= 1 }
  }

  func recordSuccess() {
    locked { successes += 1 }
  }

  func recordFailure() {
    locked { failures += 1 }
  }

  @discardableResult
  private func locked<Result>(_ body: () -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private func waitUntil(
  timeout: TimeInterval = 2,
  condition: () -> Bool
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  repeat {
    if condition() { return true }
    usleep(5_000)
  } while Date() < deadline
  return condition()
}
