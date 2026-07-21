import Foundation

/// Timing shared by the daemon and overlay so cursor restoration cannot race
/// ahead of the terminal UI animation.
public enum RingInteractionTiming {
  /// Time the exact-overlap latch remains onscreen while the bubble is sucked
  /// into its target.
  public static let latchedSuctionDuration: TimeInterval = 0.22
  /// Time the terminal overlay takes to fade after suction.
  public static let overlayDismissalDuration: TimeInterval = 0.14
  /// A small IPC margin ensures the overlay has received and finished its
  /// terminal animation before the system cursor returns.
  public static let cursorRestorationDelay: TimeInterval =
    overlayDismissalDuration + 0.04
}

public enum RingInteractionThresholds {
  /// Fraction of the cursor-driven bubble that must overlap a target before
  /// the target takes control and commits its action.
  public static let latchOverlapFraction = 0.35
}

public struct RingInteractionProfile: Codable, Equatable, Sendable {
  public static let defaultMovingBubbleRadius = 22.4
  public static let defaultTargetBubbleRadius = 28.0

  /// Distance from the origin to each action center.
  public let ringRadius: Double
  /// Movement inside this radius does not select a direction.
  public let targetingDeadZone: Double
  /// Center-to-center distance at which the visual liquid merge begins.
  public let mergeStartDistance: Double
  /// Radius of the cursor-driven bubble used for overlap latching.
  public let movingBubbleRadius: Double
  /// Radius of each stationary action target used for overlap latching.
  public let targetBubbleRadius: Double

  public static let `default` = try! RingInteractionProfile(
    ringRadius: 108,
    targetingDeadZone: 8,
    mergeStartDistance: 64,
    movingBubbleRadius: defaultMovingBubbleRadius,
    targetBubbleRadius: defaultTargetBubbleRadius
  )

  public init(
    ringRadius: Double,
    targetingDeadZone: Double,
    mergeStartDistance: Double,
    movingBubbleRadius: Double = Self.defaultMovingBubbleRadius,
    targetBubbleRadius: Double = Self.defaultTargetBubbleRadius
  ) throws {
    guard ringRadius.isFinite, ringRadius > 0 else {
      throw RingInteractionProfileError.invalidRingRadius(ringRadius)
    }
    guard targetingDeadZone.isFinite, targetingDeadZone >= 0 else {
      throw RingInteractionProfileError.invalidTargetingDeadZone(targetingDeadZone)
    }
    guard mergeStartDistance.isFinite, mergeStartDistance > 0 else {
      throw RingInteractionProfileError.invalidMergeStartDistance(mergeStartDistance)
    }
    guard movingBubbleRadius.isFinite, movingBubbleRadius > 0 else {
      throw RingInteractionProfileError.invalidMovingBubbleRadius(movingBubbleRadius)
    }
    guard targetBubbleRadius.isFinite, targetBubbleRadius > 0 else {
      throw RingInteractionProfileError.invalidTargetBubbleRadius(targetBubbleRadius)
    }
    guard movingBubbleRadius <= targetBubbleRadius else {
      throw RingInteractionProfileError.movingBubbleLargerThanTarget(
        moving: movingBubbleRadius,
        target: targetBubbleRadius
      )
    }

    self.ringRadius = ringRadius
    self.targetingDeadZone = targetingDeadZone
    self.mergeStartDistance = mergeStartDistance
    self.movingBubbleRadius = movingBubbleRadius
    self.targetBubbleRadius = targetBubbleRadius
  }
}

public enum RingInteractionProfileError: Error, Equatable, Sendable {
  case invalidRingRadius(Double)
  case invalidTargetingDeadZone(Double)
  case invalidMergeStartDistance(Double)
  case invalidMovingBubbleRadius(Double)
  case invalidTargetBubbleRadius(Double)
  case movingBubbleLargerThanTarget(moving: Double, target: Double)
}

public enum RingInteractionPhase: String, Codable, Equatable, Sendable {
  case idle
  case invoked
  case tracking
  case latched
  case committed
  case cancelled
}

public enum RingInput: Equatable, Sendable {
  /// Compatibility trigger when application identity is unavailable.
  case invoke(origin: Vector2)
  /// Sense Panel press. Pressing again while open toggles the ring closed.
  case panelTrigger(
    origin: Vector2,
    frontmostApplication: FrontmostApplicationContext
  )
  /// Sense Panel release is intentionally non-terminal: this is a click menu,
  /// not a press-and-hold menu.
  case panelRelease
  case pointerDelta(Vector2)
  /// Dismisses an active ring before latch. It cannot bypass overlap latching.
  case primaryClick
  /// Deterministically completes a previously latched suction transition.
  case completeCommit
  case escape
  case dismiss
  /// Compatibility alias for an explicit dismissal.
  case cancel
  case reset

  public static var invokeAtOrigin: RingInput {
    .invoke(origin: .zero)
  }

  public static func panelTriggerAtOrigin(
    frontmostApplication: FrontmostApplicationContext = .unknown
  ) -> RingInput {
    .panelTrigger(origin: .zero, frontmostApplication: frontmostApplication)
  }
}

public enum CursorVisibilityIntent: String, Codable, Equatable, Sendable {
  case none
  case hide
  case restore
}

public enum HapticIntent: Equatable, Sendable {
  case none
  case play(waveformID: UInt8)
}

public struct ActionInvocation: Equatable, Sendable {
  public let name: String
  public let action: ConfiguredAction
  public let zone: CardinalZone
  public let frontmostApplication: FrontmostApplicationContext

  public init(
    name: String,
    action: ConfiguredAction,
    zone: CardinalZone = .top,
    frontmostApplication: FrontmostApplicationContext = .unknown
  ) {
    self.name = name
    self.action = action
    self.zone = zone
    self.frontmostApplication = frontmostApplication
  }
}

extension ActionInvocation: Codable {
  private enum CodingKeys: String, CodingKey {
    case name
    case action
    case zone
    case frontmostApplication
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      name: try container.decode(String.self, forKey: .name),
      action: try container.decode(ConfiguredAction.self, forKey: .action),
      zone: try container.decodeIfPresent(CardinalZone.self, forKey: .zone) ?? .top,
      frontmostApplication: try container.decodeIfPresent(
        FrontmostApplicationContext.self,
        forKey: .frontmostApplication
      ) ?? .unknown
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(action, forKey: .action)
    try container.encode(zone, forKey: .zone)
    try container.encode(frontmostApplication, forKey: .frontmostApplication)
  }
}

/// A complete, renderable snapshot. All geometry is relative to `origin`, which
/// the UI may place at the hidden cursor's invocation point.
public struct RingFrame: Codable, Equatable, Sendable {
  public let phase: RingInteractionPhase
  public let origin: Vector2
  public let frontmostApplication: FrontmostApplicationContext
  public let zoneLayouts: [RingZoneLayout]
  public let targetVectors: [RingTarget]
  public let accumulatedPointerDelta: Vector2
  public let movingBubbleOffset: Vector2
  public let currentTarget: RingTarget?
  public let mergeProgress: Double
  /// 0…1 approach of the moving bubble toward the current target: 0 at the
  /// invocation origin, 1 once fused. Drives gradual selection lighting.
  public let approachProgress: Double
}

/// One pure state transition plus the one-shot effects an outer process performs.
public struct RingTransition: Codable, Equatable, Sendable {
  public let frame: RingFrame
  public let cursorVisibilityIntent: CursorVisibilityIntent
  public let hapticIntent: HapticIntent
  public let actionToPerform: ActionInvocation?
}

extension RingFrame {
  private enum CodingKeys: String, CodingKey {
    case phase
    case origin
    case frontmostApplication
    case zoneLayouts
    case targetVectors
    case accumulatedPointerDelta
    case movingBubbleOffset
    case currentTarget
    case mergeProgress
    case approachProgress
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    phase = try container.decode(RingInteractionPhase.self, forKey: .phase)
    origin = try container.decode(Vector2.self, forKey: .origin)
    frontmostApplication =
      try container.decodeIfPresent(
        FrontmostApplicationContext.self,
        forKey: .frontmostApplication
      ) ?? .unknown
    zoneLayouts = try container.decode([RingZoneLayout].self, forKey: .zoneLayouts)
    targetVectors = try container.decode([RingTarget].self, forKey: .targetVectors)
    accumulatedPointerDelta = try container.decode(
      Vector2.self,
      forKey: .accumulatedPointerDelta
    )
    movingBubbleOffset = try container.decode(Vector2.self, forKey: .movingBubbleOffset)
    currentTarget = try container.decodeIfPresent(RingTarget.self, forKey: .currentTarget)
    mergeProgress = try container.decode(Double.self, forKey: .mergeProgress)
    // Tolerates frames recorded before approach lighting existed.
    approachProgress = try container.decodeIfPresent(Double.self, forKey: .approachProgress) ?? 0
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(phase, forKey: .phase)
    try container.encode(origin, forKey: .origin)
    try container.encode(frontmostApplication, forKey: .frontmostApplication)
    try container.encode(zoneLayouts, forKey: .zoneLayouts)
    try container.encode(targetVectors, forKey: .targetVectors)
    try container.encode(accumulatedPointerDelta, forKey: .accumulatedPointerDelta)
    try container.encode(movingBubbleOffset, forKey: .movingBubbleOffset)
    if let currentTarget {
      try container.encode(currentTarget, forKey: .currentTarget)
    } else {
      try container.encodeNil(forKey: .currentTarget)
    }
    try container.encode(mergeProgress, forKey: .mergeProgress)
    try container.encode(approachProgress, forKey: .approachProgress)
  }
}

extension RingTransition {
  private enum CodingKeys: String, CodingKey {
    case frame
    case cursorVisibilityIntent
    case hapticIntent
    case actionToPerform
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    frame = try container.decode(RingFrame.self, forKey: .frame)
    cursorVisibilityIntent = try container.decode(
      CursorVisibilityIntent.self,
      forKey: .cursorVisibilityIntent
    )
    hapticIntent = try container.decode(HapticIntent.self, forKey: .hapticIntent)
    actionToPerform = try container.decodeIfPresent(
      ActionInvocation.self,
      forKey: .actionToPerform
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(frame, forKey: .frame)
    try container.encode(cursorVisibilityIntent, forKey: .cursorVisibilityIntent)
    try container.encode(hapticIntent, forKey: .hapticIntent)
    if let actionToPerform {
      try container.encode(actionToPerform, forKey: .actionToPerform)
    } else {
      try container.encodeNil(forKey: .actionToPerform)
    }
  }
}

extension RingInput: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case origin
    case delta
    case frontmostApplication
  }

  private enum Kind: String, Codable {
    case invoke
    case panelTrigger
    case panelRelease
    case pointerDelta
    case primaryClick
    case completeCommit
    case escape
    case dismiss
    case cancel
    case reset
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .invoke:
      self = .invoke(origin: try container.decode(Vector2.self, forKey: .origin))
    case .panelTrigger:
      self = .panelTrigger(
        origin: try container.decode(Vector2.self, forKey: .origin),
        frontmostApplication: try container.decodeIfPresent(
          FrontmostApplicationContext.self,
          forKey: .frontmostApplication
        ) ?? .unknown
      )
    case .panelRelease:
      self = .panelRelease
    case .pointerDelta:
      self = .pointerDelta(try container.decode(Vector2.self, forKey: .delta))
    case .primaryClick:
      self = .primaryClick
    case .completeCommit:
      self = .completeCommit
    case .escape:
      self = .escape
    case .dismiss:
      self = .dismiss
    case .cancel:
      self = .cancel
    case .reset:
      self = .reset
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .invoke(let origin):
      try container.encode(Kind.invoke, forKey: .type)
      try container.encode(origin, forKey: .origin)
    case .panelTrigger(let origin, let frontmostApplication):
      try container.encode(Kind.panelTrigger, forKey: .type)
      try container.encode(origin, forKey: .origin)
      try container.encode(frontmostApplication, forKey: .frontmostApplication)
    case .panelRelease:
      try container.encode(Kind.panelRelease, forKey: .type)
    case .pointerDelta(let delta):
      try container.encode(Kind.pointerDelta, forKey: .type)
      try container.encode(delta, forKey: .delta)
    case .primaryClick:
      try container.encode(Kind.primaryClick, forKey: .type)
    case .completeCommit:
      try container.encode(Kind.completeCommit, forKey: .type)
    case .escape:
      try container.encode(Kind.escape, forKey: .type)
    case .dismiss:
      try container.encode(Kind.dismiss, forKey: .type)
    case .cancel:
      try container.encode(Kind.cancel, forKey: .type)
    case .reset:
      try container.encode(Kind.reset, forKey: .type)
    }
  }
}

extension HapticIntent: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case waveformID
  }

  private enum Kind: String, Codable {
    case none
    case play
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .none:
      self = .none
    case .play:
      self = .play(waveformID: try container.decode(UInt8.self, forKey: .waveformID))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .none:
      try container.encode(Kind.none, forKey: .type)
    case .play(let waveformID):
      try container.encode(Kind.play, forKey: .type)
      try container.encode(waveformID, forKey: .waveformID)
    }
  }
}

/// A deterministic, clock-free interaction state machine. It owns no UI, event
/// tap, HID connection, process execution, or persistence.
public struct RingInteractionMachine: Sendable {
  public private(set) var phase: RingInteractionPhase = .idle

  private let configuration: MouseConfiguration
  private let profile: RingInteractionProfile
  private var layout: RingLayout
  private var activeActions: [String: ConfiguredAction] = [:]
  private var frontmostApplication = FrontmostApplicationContext.unknown
  private var invocationOrigin = Vector2.zero
  private var accumulatedPointerDelta = Vector2.zero
  private var movingBubbleOffset = Vector2.zero
  private var currentTarget: RingTarget?
  private var mergeProgress = 0.0
  private var approachProgress = 0.0

  public init(
    configuration: MouseConfiguration,
    profile: RingInteractionProfile = .default
  ) throws {
    try configuration.validate()
    self.configuration = configuration
    self.profile = profile
    layout = try RingLayout(zones: RingZones(), radius: profile.ringRadius)
  }

  @discardableResult
  public mutating func handle(_ input: RingInput) -> RingTransition {
    switch input {
    case .invoke(let origin):
      return trigger(at: origin, frontmostApplication: .unknown)
    case .panelTrigger(let origin, let frontmostApplication):
      return trigger(at: origin, frontmostApplication: frontmostApplication)
    case .panelRelease:
      return transition()
    case .pointerDelta(let delta):
      return move(by: delta)
    case .primaryClick:
      return primaryClick()
    case .completeCommit:
      return completeCommit()
    case .escape, .dismiss, .cancel:
      return cancel()
    case .reset:
      return reset()
    }
  }

  private mutating func trigger(
    at origin: Vector2,
    frontmostApplication context: FrontmostApplicationContext
  ) -> RingTransition {
    if phase == .invoked || phase == .tracking {
      return cancel()
    }
    if phase == .committed || phase == .cancelled {
      clearInteraction()
    }
    guard phase == .idle, origin.x.isFinite, origin.y.isFinite else {
      return transition()
    }

    // Configuration was validated at initialization and is immutable thereafter.
    let resolved = try! configuration.resolved(for: context)
    layout = try! RingLayout(zones: resolved.zones, radius: profile.ringRadius)
    activeActions = resolved.actions
    frontmostApplication = resolved.context
    invocationOrigin = origin

    guard !layout.targets.isEmpty else {
      return transition()
    }

    phase = .invoked
    return transition(cursor: .hide)
  }

  private mutating func move(by delta: Vector2) -> RingTransition {
    guard phase == .invoked || phase == .tracking,
      delta.x.isFinite,
      delta.y.isFinite
    else {
      return transition()
    }

    guard delta != .zero else {
      return transition()
    }

    phase = .tracking
    accumulatedPointerDelta = accumulatedPointerDelta + delta
    movingBubbleOffset = accumulatedPointerDelta
    updateTargetAndMerge()

    guard hasReachedLatchOverlap else {
      return transition()
    }
    return latchCurrentTarget()
  }

  private mutating func primaryClick() -> RingTransition {
    guard phase == .invoked || phase == .tracking else {
      return transition()
    }
    return cancel()
  }

  private mutating func latchCurrentTarget() -> RingTransition {
    guard let target = currentTarget,
      let action = activeActions[target.actionName]
    else {
      return transition()
    }

    phase = .latched
    movingBubbleOffset = target.vectorFromOrigin
    mergeProgress = 1
    approachProgress = 1
    return transition(
      haptic: .play(waveformID: 0),
      action: ActionInvocation(
        name: target.actionName,
        action: action,
        zone: target.zone,
        frontmostApplication: frontmostApplication
      )
    )
  }

  private mutating func completeCommit() -> RingTransition {
    guard phase == .latched else {
      return transition()
    }

    phase = .committed
    return transition(cursor: .restore)
  }

  private mutating func cancel() -> RingTransition {
    guard phase == .invoked || phase == .tracking || phase == .latched else {
      return transition()
    }
    phase = .cancelled
    return transition(cursor: .restore)
  }

  private mutating func reset() -> RingTransition {
    guard phase == .committed || phase == .cancelled else {
      return transition()
    }
    clearInteraction()
    return transition()
  }

  private mutating func clearInteraction() {
    phase = .idle
    activeActions = [:]
    frontmostApplication = .unknown
    invocationOrigin = .zero
    accumulatedPointerDelta = .zero
    movingBubbleOffset = .zero
    currentTarget = nil
    mergeProgress = 0
    approachProgress = 0
  }

  private mutating func updateTargetAndMerge() {
    guard accumulatedPointerDelta.magnitude >= profile.targetingDeadZone else {
      currentTarget = nil
      mergeProgress = 0
      approachProgress = 0
      return
    }

    currentTarget = layout.targets.min { lhs, rhs in
      let leftDistance = accumulatedPointerDelta.distance(to: lhs.vectorFromOrigin)
      let rightDistance = accumulatedPointerDelta.distance(to: rhs.vectorFromOrigin)
      if leftDistance == rightDistance {
        return lhs.index < rhs.index
      }
      return leftDistance < rightDistance
    }

    guard let currentTarget else {
      mergeProgress = 0
      approachProgress = 0
      return
    }

    let distance = accumulatedPointerDelta.distance(to: currentTarget.vectorFromOrigin)
    mergeProgress = min(max(1 - (distance / profile.mergeStartDistance), 0), 1)
    approachProgress = min(max(1 - (distance / profile.ringRadius), 0), 1)
  }

  /// Fraction of the moving bubble's area currently covered by the selected
  /// target. Keeping this as the single latch authority prevents presentation
  /// effects from silently changing the interaction threshold.
  private var currentMovingBubbleOverlapFraction: Double {
    guard let currentTarget else { return 0 }
    let movingArea = .pi * profile.movingBubbleRadius * profile.movingBubbleRadius
    guard movingArea > 0 else { return 0 }
    let centerDistance = accumulatedPointerDelta.distance(
      to: currentTarget.vectorFromOrigin
    )
    return CircleIntersectionGeometry.overlapArea(
      radiusA: profile.movingBubbleRadius,
      radiusB: profile.targetBubbleRadius,
      centerDistance: centerDistance
    ) / movingArea
  }

  private var hasReachedLatchOverlap: Bool {
    currentMovingBubbleOverlapFraction >= RingInteractionThresholds.latchOverlapFraction
  }

  private func transition(
    cursor: CursorVisibilityIntent = .none,
    haptic: HapticIntent = .none,
    action: ActionInvocation? = nil
  ) -> RingTransition {
    RingTransition(
      frame: RingFrame(
        phase: phase,
        origin: invocationOrigin,
        frontmostApplication: frontmostApplication,
        zoneLayouts: layout.zones,
        targetVectors: layout.targets,
        accumulatedPointerDelta: accumulatedPointerDelta,
        movingBubbleOffset: movingBubbleOffset,
        currentTarget: currentTarget,
        mergeProgress: mergeProgress,
        approachProgress: approachProgress
      ),
      cursorVisibilityIntent: cursor,
      hapticIntent: haptic,
      actionToPerform: action
    )
  }
}
