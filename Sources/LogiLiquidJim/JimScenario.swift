import CoreGraphics
import LogiLiquidCore
import LogiLiquidUI

/// Stable, representative checkpoints rendered by Jim.
public enum JimSnapshotState: String, Codable, CaseIterable, Sendable {
  case invoked
  case targeting
  case latchedSuctionThreshold = "latched-suction-threshold"
  case committed

  public var fileName: String {
    "\(rawValue).png"
  }
}

/// A model produced through the real interaction machine, plus the transition
/// retained for tests and agent diagnostics.
public struct JimScenario: Sendable {
  public let state: JimSnapshotState
  public let transition: RingTransition
  public let model: OverlayRenderModel

  public init(
    state: JimSnapshotState,
    transition: RingTransition
  ) {
    self.state = state
    self.transition = transition
    self.model = OverlayRenderModel(frame: transition.frame)
  }

  public static func make(
    _ state: JimSnapshotState,
    logicalSize: CGSize
  ) throws -> JimScenario {
    let origin = Vector2(
      x: Double(logicalSize.width / 2),
      y: Double(logicalSize.height / 2)
    )
    var machine = try RingInteractionMachine(configuration: .logiLiquidDefault)
    let invoked = machine.handle(
      .panelTrigger(
        origin: origin,
        frontmostApplication: FrontmostApplicationContext(
          bundleID: "com.apple.dt.Xcode",
          localizedName: "Xcode"
        )
      )
    )

    switch state {
    case .invoked:
      return JimScenario(state: state, transition: invoked)

    case .targeting:
      let profile = RingInteractionProfile.default
      // Stay 75% of the merge-start distance from the top target, producing
      // exactly 0.25 merge progress independently of the current ring radius.
      let targetingY = -(profile.ringRadius - (0.75 * profile.mergeStartDistance))
      let targeting = machine.handle(
        .pointerDelta(Vector2(x: 0, y: targetingY))
      )
      return JimScenario(state: state, transition: targeting)

    case .latchedSuctionThreshold:
      let latched = machine.handle(
        .pointerDelta(Vector2(x: 0, y: latchThresholdPointerY()))
      )
      return JimScenario(state: state, transition: latched)

    case .committed:
      _ = machine.handle(
        .pointerDelta(Vector2(x: 0, y: latchThresholdPointerY()))
      )
      let committed = machine.handle(.completeCommit)
      return JimScenario(state: state, transition: committed)
    }
  }

  /// Solves Core's exact moving-circle overlap boundary. A tiny inward
  /// epsilon makes the representative frame deterministically cross the latch
  /// despite floating-point rounding, while remaining visually at the threshold.
  private static func latchThresholdPointerY() -> Double {
    let profile = RingInteractionProfile.default
    let targetArea =
      RingInteractionThresholds.latchOverlapFraction * Double.pi
      * profile.movingBubbleRadius * profile.movingBubbleRadius
    var overlappingDistance = abs(
      profile.targetBubbleRadius - profile.movingBubbleRadius
    )
    var separatedDistance = profile.targetBubbleRadius + profile.movingBubbleRadius
    for _ in 0..<80 {
      let candidate = (overlappingDistance + separatedDistance) / 2
      let overlap = CircleIntersectionGeometry.overlapArea(
        radiusA: profile.movingBubbleRadius,
        radiusB: profile.targetBubbleRadius,
        centerDistance: candidate
      )
      if overlap >= targetArea {
        overlappingDistance = candidate
      } else {
        separatedDistance = candidate
      }
    }
    let centerDistance = overlappingDistance - 0.000_001
    return -(profile.ringRadius - centerDistance)
  }
}
