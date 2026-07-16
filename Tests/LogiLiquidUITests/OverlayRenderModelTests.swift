import CoreGraphics
import LogiLiquidCore
import XCTest

@testable import LogiLiquidUI

final class OverlayRenderModelTests: XCTestCase {
  private func makeMachine() -> RingInteractionMachine {
    try! RingInteractionMachine(configuration: .logiLiquidDefault)
  }

  private let origin = Vector2(x: 800, y: 450)

  func testMovingBubbleIsExactlyTwentyPercentSmallerThanTargets() {
    XCTAssertEqual(
      OverlayTheme.movingBubbleDiameter,
      OverlayTheme.targetBubbleDiameter * 0.8,
      accuracy: 1e-6
    )
    XCTAssertEqual(
      OverlayTheme.movingBubbleDiameter,
      CGFloat(RingInteractionProfile.defaultMovingBubbleRadius * 2),
      accuracy: 1e-6
    )
    XCTAssertEqual(
      OverlayTheme.targetBubbleDiameter,
      CGFloat(RingInteractionProfile.defaultTargetBubbleRadius * 2),
      accuracy: 1e-6
    )
    XCTAssertEqual(
      OverlayTheme.selectedTargetScale,
      1,
      "selection emphasis must not change visible overlap geometry"
    )
    XCTAssertGreaterThan(
      RingInteractionTiming.cursorRestorationDelay,
      OverlayTheme.dismissalDuration
    )
  }

  func testInvokedFrameExposesOnlyPopulatedTargetsWithNoSelection() {
    var machine = makeMachine()
    let invoked = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    let model = OverlayRenderModel(frame: invoked.frame)

    // Default layout: top 1, right 2, left 3, bottom empty → 6 targets total.
    XCTAssertEqual(model.targets.count, 6)
    // The empty bottom placeholder never becomes a target.
    XCTAssertFalse(model.targets.contains { $0.zone == .bottom })
    XCTAssertNil(model.currentTargetID)
    XCTAssertEqual(model.cgOrigin, CGPoint(x: 800, y: 450))
    XCTAssertEqual(Set(model.targets.map(\.id)).count, model.targets.count)

    let spotify = try! XCTUnwrap(model.targets.first { $0.actionName == "Play Spotify" })
    XCTAssertEqual(spotify.zone, .top)
    // Top zone points up: y is negative in the backend's y-down space.
    XCTAssertLessThan(spotify.offset.y, 0)
    XCTAssertEqual(spotify.offset.x, 0, accuracy: 1e-6)
    XCTAssertTrue(spotify.presentation.isKnownDefault)

    let leftTargets = model.targets.filter { $0.zone == .left }
    XCTAssertEqual(leftTargets.count, 3)
    for (first, second) in zip(leftTargets, leftTargets.dropFirst()) {
      let centerDistance = hypot(
        first.offset.x - second.offset.x,
        first.offset.y - second.offset.y
      )
      let occupiedDistance =
        OverlayTheme.targetBubbleDiameter / 2
        + (OverlayTheme.targetBubbleDiameter * OverlayTheme.selectedTargetScale) / 2
      XCTAssertGreaterThanOrEqual(
        centerDistance - occupiedDistance,
        12,
        "default left targets need a visible gap even beside the enlarged selection"
      )
    }
  }

  func testTrackingFrameFlagsCurrentTargetAndMergeProgress() {
    var machine = makeMachine()
    _ = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    let tracking = machine.handle(.pointerDelta(Vector2(x: 0, y: -70)))
    XCTAssertEqual(tracking.frame.phase, .tracking)

    let model = OverlayRenderModel(frame: tracking.frame)
    XCTAssertGreaterThan(model.mergeProgress, 0)
    let current = try! XCTUnwrap(model.targets.first { $0.isCurrent })
    XCTAssertEqual(current.actionName, "Play Spotify")
    XCTAssertEqual(model.currentTargetID, current.id)
    XCTAssertEqual(model.targets.filter(\.isCurrent).count, 1)
    XCTAssertEqual(model.bubbleOffset, CGPoint(x: 0, y: -70))
  }

  func testLatchedFramePinsBubbleInsideTargetUntilTerminalCompletion() {
    var machine = makeMachine()
    _ = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    _ = machine.handle(.pointerDelta(Vector2(x: 0, y: -70)))

    let latched = machine.handle(.pointerDelta(Vector2(x: 0, y: -35)))
    XCTAssertEqual(latched.frame.phase, .latched)
    let model = OverlayRenderModel(frame: latched.frame)
    let current = try! XCTUnwrap(model.targets.first { $0.isCurrent })
    XCTAssertEqual(model.bubbleOffset, current.offset)
    XCTAssertEqual(model.mergeProgress, 1)
    XCTAssertEqual(model.currentTargetID, current.id)

    let committed = machine.handle(.completeCommit)
    XCTAssertEqual(committed.frame.phase, .committed)
  }
}
