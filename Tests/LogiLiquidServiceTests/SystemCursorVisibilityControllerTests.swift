import Foundation
import XCTest

@testable import LogiLiquidService

final class SystemCursorVisibilityControllerTests: XCTestCase {
  func testBackgroundConnectionCapabilityResolvesOnThisMacOS() {
    XCTAssertNoThrow(
      try MacOSCursorVisibilitySystem().enableBackgroundCursorControl()
    )
  }

  func testDuplicateHideAndRestoreRemainExactlyBalanced() throws {
    let system = RecordingCursorVisibilitySystem()
    let controller = SystemCursorVisibilityController(system: system)

    try controller.hideCursor()
    try controller.hideCursor()
    try controller.restoreCursor()
    try controller.restoreCursor()

    XCTAssertEqual(system.operations, [.enableBackground, .hide, .show])
  }

  func testEachNewHideCycleReassertsBackgroundConnectionProperty() throws {
    let system = RecordingCursorVisibilitySystem()
    let controller = SystemCursorVisibilityController(system: system)

    try controller.hideCursor()
    try controller.restoreCursor()
    try controller.hideCursor()
    try controller.restoreCursor()

    XCTAssertEqual(
      system.operations,
      [.enableBackground, .hide, .show, .enableBackground, .hide, .show]
    )
  }

  func testConnectionOrHideFailureNeverCreatesShowOwnership() {
    for failure in [CursorSystemFailure.enableBackground, .hide] {
      let system = RecordingCursorVisibilitySystem(failure: failure)
      var controller: SystemCursorVisibilityController? =
        SystemCursorVisibilityController(system: system)

      XCTAssertThrowsError(try controller?.hideCursor())
      XCTAssertNoThrow(try controller?.restoreCursor())
      controller = nil

      XCTAssertFalse(system.operations.contains(.show))
    }
  }

  func testShowFailureRetainsOwnershipSoRestorationCanRetry() throws {
    let system = RecordingCursorVisibilitySystem(failure: .showOnce)
    let controller = SystemCursorVisibilityController(system: system)

    try controller.hideCursor()
    XCTAssertThrowsError(try controller.restoreCursor())
    try controller.restoreCursor()
    try controller.restoreCursor()

    XCTAssertEqual(
      system.operations,
      [.enableBackground, .hide, .show, .show]
    )
  }

  func testDeinitRestoresOnlyAnOwnedSuccessfulHide() throws {
    let system = RecordingCursorVisibilitySystem()
    var controller: SystemCursorVisibilityController? =
      SystemCursorVisibilityController(system: system)

    try controller?.hideCursor()
    controller = nil

    XCTAssertEqual(system.operations, [.enableBackground, .hide, .show])
  }
}

private enum CursorSystemOperation: Equatable {
  case enableBackground
  case hide
  case show
}

private enum CursorSystemFailure: Error, Equatable {
  case enableBackground
  case hide
  case showOnce
}

private final class RecordingCursorVisibilitySystem:
  SystemCursorVisibilitySystem, @unchecked Sendable
{
  private let lock = NSLock()
  private var storedOperations: [CursorSystemOperation] = []
  private var failure: CursorSystemFailure?

  init(failure: CursorSystemFailure? = nil) {
    self.failure = failure
  }

  var operations: [CursorSystemOperation] {
    lock.withLock { storedOperations }
  }

  func enableBackgroundCursorControl() throws {
    try lock.withLock {
      storedOperations.append(.enableBackground)
      if failure == .enableBackground {
        throw failure!
      }
    }
  }

  func hideCursor() throws {
    try lock.withLock {
      storedOperations.append(.hide)
      if failure == .hide {
        throw failure!
      }
    }
  }

  func showCursor() throws {
    try lock.withLock {
      storedOperations.append(.show)
      if failure == .showOnce {
        failure = nil
        throw CursorSystemFailure.showOnce
      }
    }
  }
}
