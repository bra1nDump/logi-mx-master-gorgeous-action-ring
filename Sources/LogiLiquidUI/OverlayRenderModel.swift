import CoreGraphics
import LogiLiquidCore

/// One drawable target, derived from a backend `RingTarget`. All geometry is
/// relative to the interaction origin and shares the backend's `y`-down space.
public struct OverlayTargetModel: Equatable, Sendable, Identifiable {
  /// A stable identity for `glassEffectID` and SwiftUI diffing. It is derived
  /// from the backend's globally stable target index, so it never collides even
  /// if an action name appears in two resolved zones.
  public let id: String
  public let actionName: String
  public let zone: CardinalZone
  public let presentation: OverlayTargetPresentation
  /// Offset from the origin, in points, `y` increasing downward.
  public let offset: CGPoint
  /// `true` when this is the currently selected target.
  public let isCurrent: Bool

  public init(
    id: String,
    actionName: String,
    zone: CardinalZone,
    presentation: OverlayTargetPresentation,
    offset: CGPoint,
    isCurrent: Bool
  ) {
    self.id = id
    self.actionName = actionName
    self.zone = zone
    self.presentation = presentation
    self.offset = offset
    self.isCurrent = isCurrent
  }
}

/// An immutable, framework-independent snapshot the SwiftUI overlay renders. It
/// contains only what the view needs: it drops cursor, haptic, and action-to-run
/// intents, which the UI must never act on.
public struct OverlayRenderModel: Equatable, Sendable {
  public let phase: RingInteractionPhase
  /// The interaction origin in CoreGraphics global coordinates, used to place
  /// the overlay on the correct display.
  public let cgOrigin: CGPoint
  public let targets: [OverlayTargetModel]
  /// The moving bubble's offset from the origin, in points, `y`-down.
  public let bubbleOffset: CGPoint
  /// 0…1 fusion progress toward the current target; drives the metaball bridge.
  public let mergeProgress: Double
  /// 0…1 approach toward the current target; drives gradual selection lighting.
  public let approachProgress: Double
  /// The id of the current target, or `nil` when nothing is selected.
  public let currentTargetID: String?

  /// Explicit presentation initializer used by deterministic native renderers.
  /// Production event handling continues to use `init(frame:)` below.
  public init(
    phase: RingInteractionPhase,
    cgOrigin: CGPoint,
    targets: [OverlayTargetModel],
    bubbleOffset: CGPoint,
    mergeProgress: Double,
    approachProgress: Double = 0,
    currentTargetID: String?
  ) {
    self.phase = phase
    self.cgOrigin = cgOrigin
    self.targets = targets
    self.bubbleOffset = bubbleOffset
    self.mergeProgress = mergeProgress
    self.approachProgress = approachProgress
    self.currentTargetID = currentTargetID
  }

  public init(frame: RingFrame) {
    phase = frame.phase
    cgOrigin = CGPoint(x: frame.origin.x, y: frame.origin.y)

    let currentIndex = frame.currentTarget?.index
    targets = frame.targetVectors.map { target in
      OverlayTargetModel(
        id: Self.identifier(forTargetIndex: target.index),
        actionName: target.actionName,
        zone: target.zone,
        presentation: OverlayTargetSymbols.presentation(forActionNamed: target.actionName),
        offset: CGPoint(x: target.vectorFromOrigin.x, y: target.vectorFromOrigin.y),
        isCurrent: target.index == currentIndex
      )
    }
    bubbleOffset = CGPoint(x: frame.movingBubbleOffset.x, y: frame.movingBubbleOffset.y)
    mergeProgress = frame.mergeProgress
    approachProgress = frame.approachProgress
    currentTargetID = currentIndex.map(Self.identifier(forTargetIndex:))
  }

  private static func identifier(forTargetIndex index: Int) -> String {
    "target-\(index)"
  }
}
