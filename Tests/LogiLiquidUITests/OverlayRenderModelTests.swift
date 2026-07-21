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
    XCTAssertLessThanOrEqual(OverlayTheme.presentationDuration, 0.06)
    XCTAssertGreaterThan(
      RingInteractionTiming.cursorRestorationDelay,
      OverlayTheme.dismissalDuration
    )
  }

  func testInvokedFrameExposesOnlyPopulatedTargetsWithNoSelection() {
    var machine = makeMachine()
    let invoked = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    let model = OverlayRenderModel(frame: invoked.frame)

    // Default layout: right 3, bottom 1, left 3, top empty → 7 targets total.
    XCTAssertEqual(model.targets.count, 7)
    // The empty top zone never becomes a target.
    XCTAssertFalse(model.targets.contains { $0.zone == .top })
    XCTAssertNil(model.currentTargetID)
    XCTAssertEqual(model.cgOrigin, CGPoint(x: 800, y: 450))
    XCTAssertEqual(Set(model.targets.map(\.id)).count, model.targets.count)

    let voice = try! XCTUnwrap(model.targets.first { $0.actionName == "Aqua Voice" })
    XCTAssertEqual(voice.zone, .left)
    XCTAssertLessThan(voice.offset.x, 0)
    XCTAssertTrue(voice.presentation.isKnownDefault)

    let missionControl = try! XCTUnwrap(
      model.targets.first { $0.actionName == "Mission Control" }
    )
    XCTAssertEqual(missionControl.zone, .bottom)
    // Bottom zone points down: y is positive in the backend's y-down space.
    XCTAssertGreaterThan(missionControl.offset.y, 0)
    XCTAssertEqual(missionControl.offset.x, 0, accuracy: 1e-6)
    XCTAssertTrue(missionControl.presentation.isKnownDefault)

    let rightTargets = model.targets.filter { $0.zone == .right }
    XCTAssertEqual(rightTargets.count, 3)
    // The right-zone middle action sits exactly on the horizontal axis.
    let twitter = try! XCTUnwrap(rightTargets.first { $0.actionName == "Twitter" })
    XCTAssertEqual(twitter.offset.y, 0, accuracy: 1e-6)
    XCTAssertGreaterThan(twitter.offset.x, 0)

    let leftTargets = model.targets.filter { $0.zone == .left }
    XCTAssertEqual(leftTargets.count, 3)
    XCTAssertEqual(
      leftTargets.map(\.actionName),
      ["CleanShot Record", "CleanShot Capture", "Aqua Voice"]
    )
    XCTAssertEqual(leftTargets.map(\.offset.y), leftTargets.map(\.offset.y).sorted())
    for (first, second) in zip(leftTargets, leftTargets.dropFirst()) {
      let centerDistance = hypot(
        first.offset.x - second.offset.x,
        first.offset.y - second.offset.y
      )
      let occupiedDistance = OverlayTheme.targetBubbleDiameter
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
    let tracking = machine.handle(.pointerDelta(Vector2(x: 0, y: 70)))
    XCTAssertEqual(tracking.frame.phase, .tracking)

    let model = OverlayRenderModel(frame: tracking.frame)
    XCTAssertGreaterThan(model.mergeProgress, 0)
    let current = try! XCTUnwrap(model.targets.first { $0.isCurrent })
    XCTAssertEqual(current.actionName, "Mission Control")
    XCTAssertEqual(model.currentTargetID, current.id)
    XCTAssertEqual(model.targets.filter(\.isCurrent).count, 1)
    XCTAssertEqual(model.bubbleOffset, CGPoint(x: 0, y: 70))

    // Approach lighting tracks proximity: 70 of 108 points closed.
    XCTAssertEqual(model.approachProgress, 1 - (38.0 / 108.0), accuracy: 1e-6)
  }

  func testLatchedFramePinsBubbleInsideTargetUntilTerminalCompletion() {
    var machine = makeMachine()
    _ = machine.handle(.panelTrigger(origin: origin, frontmostApplication: .unknown))
    _ = machine.handle(.pointerDelta(Vector2(x: 0, y: 70)))

    let latched = machine.handle(.pointerDelta(Vector2(x: 0, y: 35)))
    XCTAssertEqual(latched.frame.phase, .latched)
    let model = OverlayRenderModel(frame: latched.frame)
    let current = try! XCTUnwrap(model.targets.first { $0.isCurrent })
    XCTAssertEqual(model.bubbleOffset, current.offset)
    XCTAssertEqual(model.mergeProgress, 1)
    XCTAssertEqual(model.approachProgress, 1)
    XCTAssertEqual(model.currentTargetID, current.id)

    let committed = machine.handle(.completeCommit)
    XCTAssertEqual(committed.frame.phase, .committed)
  }
}
