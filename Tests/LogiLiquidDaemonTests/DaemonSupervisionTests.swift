import Dispatch
import Foundation
import XCTest

@testable import LogiLiquidDaemon

final class DaemonSupervisionTests: XCTestCase {
  func testGateDeliversDeviceFailureOnceAndTimesOutAfterReset() {
    let gate = DaemonSupervisorGate()
    gate.signalDeviceFailure("device gone")
    gate.signalDeviceFailure("second failure is ignored")
    XCTAssertEqual(gate.wait(timeout: 0.1), .deviceFailure("device gone"))

    gate.reset()
    XCTAssertEqual(gate.wait(timeout: 0.05), .timeout)
  }

  func testShutdownLatchesAcrossResetAndWinsOverDeviceFailure() {
    let gate = DaemonSupervisorGate()
    gate.signalDeviceFailure("device gone")
    gate.signalShutdown()
    XCTAssertEqual(gate.wait(timeout: 0.1), .signal)

    // A reconnect cycle must never clear a pending shutdown.
    gate.reset()
    XCTAssertEqual(gate.wait(timeout: 0.1), .signal)
  }

  func testGateWakesBlockedWaiter() {
    let gate = DaemonSupervisorGate()
    let woke = expectation(description: "waiter woke")
    Thread.detachNewThread {
      XCTAssertEqual(gate.wait(), .deviceFailure("late failure"))
      woke.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.05)
    gate.signalDeviceFailure("late failure")
    wait(for: [woke], timeout: 2)
  }

  func testWakeInterruptsRetryWaitExactlyOnce() {
    let gate = DaemonSupervisorGate()
    _ = gate.signalWake()
    let latestGeneration = gate.signalWake()
    XCTAssertEqual(gate.wait(timeout: 0.1), .wake(latestGeneration))
    XCTAssertEqual(gate.wait(timeout: 0.05), .timeout)
    XCTAssertTrue(gate.consumeWakeRetry())
    XCTAssertFalse(gate.consumeWakeRetry())
  }

  func testSuccessfulWakeRecoveryClearsImmediateRetry() {
    let gate = DaemonSupervisorGate()
    let generation = gate.signalWake()
    XCTAssertEqual(gate.wait(timeout: 0.1), .wake(generation))
    gate.clearWakeRetry(generation: generation)
    XCTAssertFalse(gate.consumeWakeRetry())
  }

  func testOldProbeSuccessCannotClearNewerWakeRetry() {
    let gate = DaemonSupervisorGate()
    let oldGeneration = gate.signalWake()
    let newGeneration = gate.signalWake()
    gate.clearWakeRetry(generation: oldGeneration)
    XCTAssertEqual(gate.wait(timeout: 0.1), .wake(newGeneration))
    XCTAssertTrue(gate.consumeWakeRetry())
  }

  func testShutdownAndDeviceFailureTakePriorityOverWake() {
    let failed = DaemonSupervisorGate()
    let failedWake = failed.signalWake()
    failed.signalDeviceFailure("device gone")
    XCTAssertEqual(failed.wait(timeout: 0.1), .deviceFailure("device gone"))
    failed.reset()
    XCTAssertEqual(failed.wait(timeout: 0.1), .wake(failedWake))

    let stopped = DaemonSupervisorGate()
    _ = stopped.signalWake()
    stopped.signalShutdown()
    XCTAssertEqual(stopped.wait(timeout: 0.1), .signal)
  }

  func testSystemPowerMonitorForwardsAndCoalescesNotifications() {
    let center = NotificationCenter()
    let sleep = Notification.Name("test.system-sleep")
    let wake = Notification.Name("test.system-wake")
    let slept = expectation(description: "sleep delivered")
    slept.assertForOverFulfill = true
    let delivered = expectation(description: "wake delivered")
    delivered.assertForOverFulfill = true
    let monitor = SystemPowerMonitor(
      notificationCenter: center,
      sleepNotifications: [sleep],
      wakeNotifications: [wake],
      onSleep: { slept.fulfill() },
      onWake: { delivered.fulfill() }
    )
    monitor.start()
    center.post(name: sleep, object: nil)
    center.post(name: sleep, object: nil)
    center.post(name: wake, object: nil)
    center.post(name: wake, object: nil)
    wait(for: [slept, delivered], timeout: 2)
    monitor.stop()
  }

  func testSystemPowerMonitorShutdownIsBoundedWhileCallbackIsInFlight() {
    let center = NotificationCenter()
    let sleep = Notification.Name("test.blocked-sleep")
    let sleepEntered = expectation(description: "sleep callback entered")
    let notificationReturned = expectation(description: "notification post returned")
    let allowSleepToFinish = DispatchSemaphore(value: 0)
    let monitor = SystemPowerMonitor(
      notificationCenter: center,
      sleepNotifications: [sleep],
      wakeNotifications: [],
      onSleep: {
        sleepEntered.fulfill()
        allowSleepToFinish.wait()
      },
      onWake: {}
    )
    XCTAssertTrue(monitor.start())

    DispatchQueue.global().async {
      center.post(name: sleep, object: nil)
      notificationReturned.fulfill()
    }
    wait(for: [sleepEntered, notificationReturned], timeout: 2)
    XCTAssertFalse(monitor.stop(timeout: 0.05))
    allowSleepToFinish.signal()
  }

  func testSystemPowerMonitorSerializesSleepBeforeWake() {
    let center = NotificationCenter()
    let sleep = Notification.Name("test.serial-sleep")
    let wake = Notification.Name("test.serial-wake")
    let sleepEntered = expectation(description: "sleep callback entered")
    let wakeDelivered = expectation(description: "wake callback delivered")
    let postsFinished = expectation(description: "notification posts finished")
    postsFinished.expectedFulfillmentCount = 2
    let allowSleepToFinish = DispatchSemaphore(value: 0)
    let recorder = PowerEventRecorder()
    let monitor = SystemPowerMonitor(
      notificationCenter: center,
      sleepNotifications: [sleep],
      wakeNotifications: [wake],
      onSleep: {
        recorder.append("sleep")
        sleepEntered.fulfill()
        allowSleepToFinish.wait()
      },
      onWake: {
        recorder.append("wake")
        wakeDelivered.fulfill()
      }
    )
    XCTAssertTrue(monitor.start())

    DispatchQueue.global().async {
      center.post(name: sleep, object: nil)
      postsFinished.fulfill()
    }
    wait(for: [sleepEntered], timeout: 2)
    DispatchQueue.global().async {
      center.post(name: wake, object: nil)
      postsFinished.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertEqual(recorder.events, ["sleep"])

    allowSleepToFinish.signal()
    wait(for: [wakeDelivered, postsFinished], timeout: 2)
    XCTAssertEqual(recorder.events, ["sleep", "wake"])
    XCTAssertTrue(monitor.stop())
  }

  func testSystemAndScreenPowerNotificationsRemainIndependentAndOrdered() {
    let center = NotificationCenter()
    let screenSleep = Notification.Name("test.screen-sleep")
    let systemSleep = Notification.Name("test.system-sleep")
    let screenWake = Notification.Name("test.screen-wake")
    let systemWake = Notification.Name("test.system-wake")
    let delivered = expectation(description: "all domain events delivered")
    delivered.expectedFulfillmentCount = 4
    let recorder = PowerEventRecorder()
    let monitor = SystemPowerMonitor(
      notificationCenter: center,
      screenSleepNotifications: [screenSleep],
      systemSleepNotifications: [systemSleep],
      screenWakeNotifications: [screenWake],
      systemWakeNotifications: [systemWake],
      onScreenSleep: {
        recorder.append("screen-sleep")
        delivered.fulfill()
      },
      onSystemSleep: {
        recorder.append("system-sleep")
        delivered.fulfill()
      },
      onScreenWake: {
        recorder.append("screen-wake")
        delivered.fulfill()
      },
      onSystemWake: {
        recorder.append("system-wake")
        delivered.fulfill()
      }
    )
    XCTAssertTrue(monitor.start())

    center.post(name: screenSleep, object: nil)
    center.post(name: systemSleep, object: nil)
    center.post(name: systemWake, object: nil)
    center.post(name: screenWake, object: nil)
    wait(for: [delivered], timeout: 2)
    XCTAssertEqual(
      recorder.events,
      ["screen-sleep", "system-sleep", "system-wake", "screen-wake"]
    )
    XCTAssertTrue(monitor.stop())
  }

  func testBackoffDoublesToCapAndResets() {
    var backoff = DaemonRetryBackoff(initial: 1, maximum: 10)
    XCTAssertEqual(backoff.next(), 1)
    XCTAssertEqual(backoff.next(), 2)
    XCTAssertEqual(backoff.next(), 4)
    XCTAssertEqual(backoff.next(), 8)
    XCTAssertEqual(backoff.next(), 10)
    XCTAssertEqual(backoff.next(afterWake: true), 0)
    XCTAssertEqual(backoff.next(), 10, "an immediate wake retry must not consume backoff")
    XCTAssertEqual(backoff.next(), 10)
    backoff.reset()
    XCTAssertEqual(backoff.next(), 1)
  }

  func testDeviceAbsenceIsRecoverableAndWrongDeviceIsNot() {
    // Waiting fixes these: the mouse is asleep, disconnected, or half-awake.
    XCTAssertFalse(MouseDaemonError.noMXMaster4.preventsAutomaticDeviceRecovery)
    XCTAssertFalse(
      MouseDaemonError.diversionRecoveryDeviceIdentityUnavailable
        .preventsAutomaticDeviceRecovery
    )
    XCTAssertFalse(
      MouseDaemonError.restorationFailed("half-awake bring-up")
        .preventsAutomaticDeviceRecovery
    )
    XCTAssertFalse(MouseDaemonError.notRunning.preventsAutomaticDeviceRecovery)

    // Waiting never fixes these.
    XCTAssertTrue(
      MouseDaemonError.diversionRecoveryDeviceIdentityMismatch
        .preventsAutomaticDeviceRecovery
    )
    XCTAssertTrue(
      MouseDaemonError.diversionRecoveryDeviceMismatch(expected: 1, actual: 2)
        .preventsAutomaticDeviceRecovery
    )
    XCTAssertTrue(
      MouseDaemonError.unsupportedJournalVersion(9).preventsAutomaticDeviceRecovery
    )
    XCTAssertTrue(
      MouseDaemonError.unsafePath("/tmp/x").preventsAutomaticDeviceRecovery
    )
    XCTAssertTrue(
      MouseDaemonError.invalidParameter("x").preventsAutomaticDeviceRecovery
    )
    XCTAssertTrue(
      MouseDaemonError.selectedDeviceUnavailable(7).preventsAutomaticDeviceRecovery
    )
    XCTAssertTrue(MouseDaemonError.alreadyRunning.preventsAutomaticDeviceRecovery)
  }
}

private final class PowerEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var events: [String] {
    lock.withLock { storage }
  }

  func append(_ event: String) {
    lock.withLock { storage.append(event) }
  }
}
