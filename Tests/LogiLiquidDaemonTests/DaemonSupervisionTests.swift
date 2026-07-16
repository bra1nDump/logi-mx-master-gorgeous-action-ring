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

  func testBackoffDoublesToCapAndResets() {
    var backoff = DaemonRetryBackoff(initial: 1, maximum: 10)
    XCTAssertEqual(backoff.next(), 1)
    XCTAssertEqual(backoff.next(), 2)
    XCTAssertEqual(backoff.next(), 4)
    XCTAssertEqual(backoff.next(), 8)
    XCTAssertEqual(backoff.next(), 10)
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
