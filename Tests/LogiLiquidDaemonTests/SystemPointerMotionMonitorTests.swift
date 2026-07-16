import Foundation
import LogiLiquidCore
import LogiLiquidDaemon
import LogiLiquidService
import XCTest

final class SystemPointerMotionMonitorTests: XCTestCase {
  func testDoesNotPollOrPublishBeforeTrackingIsEnabled() throws {
    let provider = MutableCursorPositionProvider(position: .zero)
    let recorder = PointerMotionEventRecorder()
    let monitor = try SystemPointerMotionMonitor(
      positionProvider: provider,
      samplesPerSecond: 1_000
    )
    try monitor.start { event in
      recorder.append(event)
    }

    Thread.sleep(forTimeInterval: 0.03)
    monitor.stop()

    XCTAssertEqual(provider.callCount, 0)
    XCTAssertTrue(recorder.events.isEmpty)
  }

  func testPublishesRelativeDeltasAfterEstablishingBaseline() throws {
    let provider = MutableCursorPositionProvider(
      position: Vector2(x: 10, y: 20)
    )
    let recorder = PointerMotionEventRecorder()
    let monitor = try SystemPointerMotionMonitor(
      positionProvider: provider,
      samplesPerSecond: 1_000
    )
    try monitor.start { event in
      recorder.append(event)
    }
    defer { monitor.stop() }

    monitor.setTracking(true)
    XCTAssertTrue(waitForPointerMotionCondition { provider.callCount >= 1 })
    XCTAssertTrue(recorder.deltas.isEmpty)

    provider.setPosition(Vector2(x: 13, y: 16))
    XCTAssertTrue(waitForPointerMotionCondition { recorder.deltas.count == 1 })
    XCTAssertEqual(recorder.deltas, [Vector2(x: 3, y: -4)])
  }

  func testEachTrackingSessionEstablishesANewPositionBaseline() throws {
    let provider = MutableCursorPositionProvider(position: .zero)
    let recorder = PointerMotionEventRecorder()
    let monitor = try SystemPointerMotionMonitor(
      positionProvider: provider,
      samplesPerSecond: 1_000
    )
    try monitor.start { event in
      recorder.append(event)
    }
    defer { monitor.stop() }

    monitor.setTracking(true)
    XCTAssertTrue(waitForPointerMotionCondition { provider.callCount >= 5 })
    monitor.setTracking(false)
    XCTAssertTrue(waitForStableCursorCallCount(provider))
    let callsWhileDisabled = provider.callCount

    provider.setPosition(Vector2(x: 1_000, y: 1_000))
    Thread.sleep(forTimeInterval: 0.01)
    XCTAssertEqual(provider.callCount, callsWhileDisabled)

    monitor.setTracking(true)
    XCTAssertTrue(
      waitForPointerMotionCondition { provider.callCount > callsWhileDisabled }
    )
    XCTAssertTrue(recorder.deltas.isEmpty)

    provider.setPosition(Vector2(x: 1_002, y: 1_003))
    XCTAssertTrue(waitForPointerMotionCondition { recorder.deltas.count == 1 })
    XCTAssertEqual(recorder.deltas, [Vector2(x: 2, y: 3)])
  }

  func testRejectsNonPositiveAndNonFiniteSamplingRates() {
    for invalidRate in [0, -1, Double.nan, Double.infinity] {
      XCTAssertThrowsError(
        try SystemPointerMotionMonitor(samplesPerSecond: invalidRate)
      ) { error in
        XCTAssertEqual(
          error as? MouseDaemonError,
          .invalidParameter("Pointer sampling frequency must be positive.")
        )
      }
    }
  }

  func testStopWaitsForPollingThreadAndPreventsFurtherSamples() throws {
    let provider = BlockingCursorPositionProvider(position: .zero)
    let monitor = try SystemPointerMotionMonitor(
      positionProvider: provider,
      samplesPerSecond: 1_000
    )
    try monitor.start { _ in }
    defer {
      provider.release()
      monitor.stop()
    }
    monitor.setTracking(true)
    XCTAssertTrue(provider.waitUntilEntered())

    let stopState = PointerStopCompletionState()
    DispatchQueue.global().async {
      stopState.markStarted()
      monitor.stop()
      stopState.markReturned()
    }
    XCTAssertTrue(stopState.waitUntilStarted())
    Thread.sleep(forTimeInterval: 0.02)
    XCTAssertFalse(stopState.hasReturned)

    provider.release()
    XCTAssertTrue(stopState.waitUntilReturned())
    let stoppedCallCount = provider.callCount

    monitor.setTracking(true)
    Thread.sleep(forTimeInterval: 0.02)
    XCTAssertEqual(provider.callCount, stoppedCallCount)
  }
}

private final class MutableCursorPositionProvider:
  CursorPositionProviding, @unchecked Sendable
{
  private let lock = NSLock()
  private var position: Vector2
  private var calls = 0

  init(position: Vector2) {
    self.position = position
  }

  var callCount: Int {
    lock.withLock { calls }
  }

  func currentPosition() throws -> Vector2 {
    lock.withLock {
      calls += 1
      return position
    }
  }

  func setPosition(_ position: Vector2) {
    lock.withLock { self.position = position }
  }
}

private final class BlockingCursorPositionProvider:
  CursorPositionProviding, @unchecked Sendable
{
  private let condition = NSCondition()
  private let position: Vector2
  private var calls = 0
  private var entered = false
  private var released = false

  init(position: Vector2) {
    self.position = position
  }

  var callCount: Int {
    condition.withLock { calls }
  }

  func currentPosition() throws -> Vector2 {
    condition.lock()
    calls += 1
    entered = true
    condition.broadcast()
    while !released {
      condition.wait()
    }
    condition.unlock()
    return position
  }

  func waitUntilEntered(timeout: TimeInterval = 1) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !entered {
      guard condition.wait(until: deadline) else { return entered }
    }
    return true
  }

  func release() {
    condition.withLock {
      released = true
      condition.broadcast()
    }
  }
}

private final class PointerMotionEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [MouseDaemonPointerMotionEvent] = []

  var events: [MouseDaemonPointerMotionEvent] {
    lock.withLock { storage }
  }

  var deltas: [Vector2] {
    events.compactMap { event in
      if case .pointerDelta(let delta) = event { return delta }
      return nil
    }
  }

  func append(_ event: MouseDaemonPointerMotionEvent) {
    lock.withLock { storage.append(event) }
  }
}

private final class PointerStopCompletionState: @unchecked Sendable {
  private let condition = NSCondition()
  private var started = false
  private var returned = false

  var hasReturned: Bool {
    condition.withLock { returned }
  }

  func markStarted() {
    condition.withLock {
      started = true
      condition.broadcast()
    }
  }

  func markReturned() {
    condition.withLock {
      returned = true
      condition.broadcast()
    }
  }

  func waitUntilStarted(timeout: TimeInterval = 1) -> Bool {
    wait(timeout: timeout) { started }
  }

  func waitUntilReturned(timeout: TimeInterval = 1) -> Bool {
    wait(timeout: timeout) { returned }
  }

  private func wait(
    timeout: TimeInterval,
    until predicate: () -> Bool
  ) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !predicate() {
      guard condition.wait(until: deadline) else { return predicate() }
    }
    return true
  }
}

private func waitForPointerMotionCondition(
  timeout: TimeInterval = 1,
  _ condition: () -> Bool
) -> Bool {
  let deadline = Date(timeIntervalSinceNow: timeout)
  repeat {
    if condition() { return true }
    Thread.sleep(forTimeInterval: 0.001)
  } while Date() < deadline
  return condition()
}

private func waitForStableCursorCallCount(
  _ provider: MutableCursorPositionProvider,
  stableFor: TimeInterval = 0.02,
  timeout: TimeInterval = 1
) -> Bool {
  let deadline = Date(timeIntervalSinceNow: timeout)
  var lastCount = provider.callCount
  var stableSince = Date()
  repeat {
    Thread.sleep(forTimeInterval: 0.001)
    let callCount = provider.callCount
    if callCount != lastCount {
      lastCount = callCount
      stableSince = Date()
    } else if Date().timeIntervalSince(stableSince) >= stableFor {
      return true
    }
  } while Date() < deadline
  return false
}
