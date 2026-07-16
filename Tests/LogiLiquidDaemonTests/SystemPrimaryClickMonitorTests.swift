import Foundation
import LogiLiquidDaemon
import XCTest

final class SystemPrimaryClickMonitorTests: XCTestCase {
  func testDoesNotPollOrPublishBeforeTrackingIsEnabled() throws {
    let provider = MutablePrimaryButtonStateProvider(isPressed: false)
    let recorder = PrimaryClickEventRecorder()
    let monitor = try SystemPrimaryClickMonitor(
      stateProvider: provider,
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

  func testHeldButtonDoesNotRetriggerUntilAnUpDownEdge() throws {
    let provider = MutablePrimaryButtonStateProvider(isPressed: false)
    let recorder = PrimaryClickEventRecorder()
    let monitor = try SystemPrimaryClickMonitor(
      stateProvider: provider,
      samplesPerSecond: 1_000
    )
    try monitor.start { event in
      recorder.append(event)
    }
    defer { monitor.stop() }

    monitor.setTracking(true)
    XCTAssertTrue(waitForPrimaryClickCondition { provider.callCount >= 1 })

    provider.setPressed(true)
    XCTAssertTrue(waitForPrimaryClickCondition { recorder.primaryClickCount == 1 })
    let callsWhileHeld = provider.callCount
    XCTAssertTrue(
      waitForPrimaryClickCondition { provider.callCount >= callsWhileHeld + 10 }
    )
    XCTAssertEqual(recorder.primaryClickCount, 1)

    provider.setPressed(false)
    let callsBeforeReleaseSample = provider.callCount
    XCTAssertTrue(
      waitForPrimaryClickCondition {
        provider.callCount > callsBeforeReleaseSample
      }
    )
    provider.setPressed(true)
    XCTAssertTrue(waitForPrimaryClickCondition { recorder.primaryClickCount == 2 })
  }

  func testEachTrackingSessionEstablishesANewButtonBaseline() throws {
    let provider = MutablePrimaryButtonStateProvider(isPressed: true)
    let recorder = PrimaryClickEventRecorder()
    let monitor = try SystemPrimaryClickMonitor(
      stateProvider: provider,
      samplesPerSecond: 1_000
    )
    try monitor.start { event in
      recorder.append(event)
    }
    defer { monitor.stop() }

    monitor.setTracking(true)
    XCTAssertTrue(waitForPrimaryClickCondition { provider.callCount >= 5 })
    XCTAssertEqual(recorder.primaryClickCount, 0)

    monitor.setTracking(false)
    XCTAssertTrue(waitForStablePrimaryButtonCallCount(provider))
    let callsWhileDisabled = provider.callCount
    provider.setPressed(false)
    Thread.sleep(forTimeInterval: 0.01)
    XCTAssertEqual(provider.callCount, callsWhileDisabled)

    monitor.setTracking(true)
    XCTAssertTrue(
      waitForPrimaryClickCondition { provider.callCount > callsWhileDisabled }
    )
    provider.setPressed(true)
    XCTAssertTrue(waitForPrimaryClickCondition { recorder.primaryClickCount == 1 })
  }

  func testRejectsNonPositiveAndNonFiniteSamplingRates() {
    for invalidRate in [0, -1, Double.nan, Double.infinity] {
      XCTAssertThrowsError(
        try SystemPrimaryClickMonitor(samplesPerSecond: invalidRate)
      ) { error in
        XCTAssertEqual(
          error as? MouseDaemonError,
          .invalidParameter(
            "Primary-click sampling frequency must be positive."
          )
        )
      }
    }
  }

  func testStopWaitsForPollingThreadAndPreventsFurtherSamples() throws {
    let provider = BlockingPrimaryButtonStateProvider(isPressed: false)
    let monitor = try SystemPrimaryClickMonitor(
      stateProvider: provider,
      samplesPerSecond: 1_000
    )
    try monitor.start { _ in }
    defer {
      provider.release()
      monitor.stop()
    }
    monitor.setTracking(true)
    XCTAssertTrue(provider.waitUntilEntered())

    let stopState = StopCompletionState()
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

private final class MutablePrimaryButtonStateProvider:
  PrimaryMouseButtonStateProviding, @unchecked Sendable
{
  private let lock = NSLock()
  private var isPressed: Bool
  private var calls = 0

  init(isPressed: Bool) {
    self.isPressed = isPressed
  }

  var callCount: Int {
    lock.withLock { calls }
  }

  func isPrimaryButtonPressed() throws -> Bool {
    lock.withLock {
      calls += 1
      return isPressed
    }
  }

  func setPressed(_ isPressed: Bool) {
    lock.withLock { self.isPressed = isPressed }
  }
}

private final class BlockingPrimaryButtonStateProvider:
  PrimaryMouseButtonStateProviding, @unchecked Sendable
{
  private let condition = NSCondition()
  private let isPressed: Bool
  private var calls = 0
  private var entered = false
  private var released = false

  init(isPressed: Bool) {
    self.isPressed = isPressed
  }

  var callCount: Int {
    condition.withLock { calls }
  }

  func isPrimaryButtonPressed() throws -> Bool {
    condition.lock()
    calls += 1
    entered = true
    condition.broadcast()
    while !released {
      condition.wait()
    }
    condition.unlock()
    return isPressed
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

private final class PrimaryClickEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [MouseDaemonPrimaryClickEvent] = []

  var events: [MouseDaemonPrimaryClickEvent] {
    lock.withLock { storage }
  }

  var primaryClickCount: Int {
    events.reduce(into: 0) { count, event in
      if case .primaryClick = event { count += 1 }
    }
  }

  func append(_ event: MouseDaemonPrimaryClickEvent) {
    lock.withLock { storage.append(event) }
  }
}

private final class StopCompletionState: @unchecked Sendable {
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

private func waitForPrimaryClickCondition(
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

private func waitForStablePrimaryButtonCallCount(
  _ provider: MutablePrimaryButtonStateProvider,
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
