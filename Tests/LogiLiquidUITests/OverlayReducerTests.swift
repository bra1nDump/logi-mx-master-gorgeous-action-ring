import LogiLiquidCore
import XCTest

@testable import LogiLiquidUI

/// The reducer is exercised with real frames produced by the backend state
/// machine, so the visibility contract is proven against genuine transitions
/// rather than hand-built fixtures.
final class OverlayReducerTests: XCTestCase {
  private func makeMachine() -> RingInteractionMachine {
    try! RingInteractionMachine(configuration: .logiLiquidDefault)
  }

  private let origin = Vector2(x: 800, y: 450)

  func testShowsOnInvokeAndStaysHiddenForATerminalFrame() {
    var machine = makeMachine()
    let invoked = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    XCTAssertEqual(invoked.frame.phase, .invoked)

    var reducer = OverlayReducer()
    XCTAssertEqual(reducer.reduce(.frame(invoked.frame)), .show)
    XCTAssertTrue(reducer.isVisible)

    // A committed frame handed to a fresh reducer must not show the overlay.
    var other = makeMachine()
    _ = other.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    _ = other.handle(.pointerDelta(Vector2(x: 0, y: 70)))
    let latched = other.handle(.pointerDelta(Vector2(x: 0, y: 35)))
    XCTAssertEqual(latched.frame.phase, .latched)
    let committed = other.handle(.completeCommit)
    XCTAssertEqual(committed.frame.phase, .committed)

    var freshReducer = OverlayReducer()
    XCTAssertNil(freshReducer.reduce(.frame(committed.frame)))
    XCTAssertFalse(freshReducer.isVisible)
  }

  func testPanelReleaseDoesNotHide() {
    var machine = makeMachine()
    let invoked = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    let released = machine.handle(.panelRelease)
    XCTAssertEqual(released.frame.phase, .invoked)

    var reducer = OverlayReducer()
    XCTAssertEqual(reducer.reduce(.frame(invoked.frame)), .show)
    XCTAssertNil(reducer.reduce(.frame(released.frame)))
    XCTAssertTrue(reducer.isVisible)
  }

  func testLatchRemainsVisibleUntilTerminalCommitThenHidesExactlyOnce() {
    var machine = makeMachine()
    let invoked = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    let tracking = machine.handle(.pointerDelta(Vector2(x: 0, y: 70)))
    XCTAssertEqual(tracking.frame.phase, .tracking)
    let latched = machine.handle(.pointerDelta(Vector2(x: 0, y: 35)))
    XCTAssertEqual(latched.frame.phase, .latched)
    let committed = machine.handle(.completeCommit)
    XCTAssertEqual(committed.frame.phase, .committed)
    let idle = machine.handle(.reset)
    XCTAssertEqual(idle.frame.phase, .idle)

    var reducer = OverlayReducer()
    let effects = [
      reducer.reduce(.frame(invoked.frame)),
      reducer.reduce(.frame(tracking.frame)),
      reducer.reduce(.frame(latched.frame)),
      reducer.reduce(.frame(committed.frame)),
      reducer.reduce(.frame(idle.frame)),
    ]
    XCTAssertEqual(effects, [.show, nil, nil, .hide, nil])
    XCTAssertEqual(effects.filter { $0 == .hide }.count, 1)
    XCTAssertFalse(reducer.isVisible)
  }

  func testSecondSensePressCancelsAndHides() {
    var machine = makeMachine()
    let invoked = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    // A second Sense-panel press while open toggles the ring closed.
    let cancelled = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    XCTAssertEqual(cancelled.frame.phase, .cancelled)

    var reducer = OverlayReducer()
    XCTAssertEqual(reducer.reduce(.frame(invoked.frame)), .show)
    XCTAssertEqual(reducer.reduce(.frame(cancelled.frame)), .hide)
    XCTAssertFalse(reducer.isVisible)
  }

  func testDisconnectHidesExactlyOnce() {
    var machine = makeMachine()
    let invoked = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))

    var reducer = OverlayReducer()
    XCTAssertEqual(reducer.reduce(.frame(invoked.frame)), .show)
    XCTAssertEqual(reducer.reduce(.disconnected), .hide)
    XCTAssertNil(reducer.reduce(.disconnected))
    XCTAssertFalse(reducer.isVisible)
  }

  func testModelRetainedAfterHideForAnimatingOut() {
    var machine = makeMachine()
    let invoked = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))

    var reducer = OverlayReducer()
    _ = reducer.reduce(.frame(invoked.frame))
    _ = reducer.reduce(.disconnected)
    XCTAssertNotNil(reducer.model)
  }
}
