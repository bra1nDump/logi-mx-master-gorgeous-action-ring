import Foundation

/// A relative two-dimensional vector in screen points. Positive x is right and
/// positive y is down, matching AppKit's flipped overlay coordinate space.
public struct Vector2: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  public static let zero = Vector2(x: 0, y: 0)

  public var magnitude: Double {
    hypot(x, y)
  }

  public func distance(to other: Vector2) -> Double {
    (self - other).magnitude
  }

  public static func + (lhs: Vector2, rhs: Vector2) -> Vector2 {
    Vector2(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
  }

  public static func - (lhs: Vector2, rhs: Vector2) -> Vector2 {
    Vector2(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
  }
}

public struct RingTarget: Codable, Equatable, Sendable {
  public let actionName: String
  /// Stable index across all visible targets in top/right/bottom/left order.
  public let index: Int
  public let zone: CardinalZone
  /// Stable zero-based order within `zone`.
  public let zoneIndex: Int
  public let vectorFromOrigin: Vector2

  public init(
    actionName: String,
    index: Int,
    zone: CardinalZone,
    zoneIndex: Int,
    vectorFromOrigin: Vector2
  ) {
    self.actionName = actionName
    self.index = index
    self.zone = zone
    self.zoneIndex = zoneIndex
    self.vectorFromOrigin = vectorFromOrigin
  }
}

/// Render metadata is retained even when a zone has no actionable target.
public struct RingZoneLayout: Codable, Equatable, Sendable {
  public let zone: CardinalZone
  public let actionNames: [String]
  public let isPlaceholder: Bool

  public init(zone: CardinalZone, actionNames: [String], isPlaceholder: Bool) {
    self.zone = zone
    self.actionNames = actionNames
    self.isPlaceholder = isPlaceholder
  }
}

public struct RingLayout: Codable, Equatable, Sendable {
  public let origin: Vector2
  public let zones: [RingZoneLayout]
  public let targets: [RingTarget]

  /// Each zone owns a count-aware fan centered on its cardinal direction.
  /// Two-action zones keep a broad 60-degree read, while denser zones expand
  /// toward an 80-degree ceiling to preserve useful center-to-center spacing.
  /// Actions remain equally spaced and retain configuration order.
  public init(zones actionZones: RingZones, radius: Double) throws {
    guard radius.isFinite, radius > 0 else {
      throw RingLayoutError.invalidRadius(radius)
    }
    guard
      actionZones.actionNamesClockwise.allSatisfy({
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      throw RingLayoutError.emptyActionName
    }

    origin = .zero
    zones = CardinalZone.clockwiseOrder.map { zone in
      let names = actionZones[zone]
      return RingZoneLayout(
        zone: zone,
        actionNames: names,
        isPlaceholder: zone == .bottom && names.isEmpty
      )
    }

    var builtTargets: [RingTarget] = []
    builtTargets.reserveCapacity(actionZones.actionCount)
    for zone in CardinalZone.clockwiseOrder {
      let names = actionZones[zone]
      for (zoneIndex, actionName) in names.enumerated() {
        let angle = Self.angle(
          for: zone,
          index: zoneIndex,
          count: names.count,
          radius: radius
        )
        builtTargets.append(
          RingTarget(
            actionName: actionName,
            index: builtTargets.count,
            zone: zone,
            zoneIndex: zoneIndex,
            vectorFromOrigin: Vector2(
              x: radius * cos(angle),
              y: radius * sin(angle)
            )
          )
        )
      }
    }
    targets = builtTargets
  }

  /// Compatibility initializer for v1 callers and scenarios.
  public init(actionNames: [String], radius: Double) throws {
    try self.init(
      zones: RingZones(migratingLegacyRing: actionNames),
      radius: radius
    )
  }

  private static func angle(
    for zone: CardinalZone,
    index: Int,
    count: Int,
    radius: Double
  ) -> Double {
    let center: Double
    switch zone {
    case .top: center = -.pi / 2
    case .right: center = 0
    case .bottom: center = .pi / 2
    case .left: center = .pi
    }

    guard count > 1 else { return center }
    // Convert the preferred physical separation into an angular step at this
    // radius. A 60-degree floor keeps two-action zones visually directional;
    // the 80-degree ceiling keeps every fan recognizably inside its cardinal
    // neighborhood even when agents configure more actions than comfortably fit.
    let preferredAdjacentCenterDistance = 72.0
    let halfChordRatio = min(preferredAdjacentCenterDistance / (2 * radius), 1)
    let preferredStep = 2 * asin(halfChordRatio)
    let minimumFanWidth = Double.pi / 3
    let maximumFanWidth = 4 * Double.pi / 9
    let fanWidth = min(
      maximumFanWidth,
      max(minimumFanWidth, preferredStep * Double(count - 1))
    )
    return center - (fanWidth / 2) + (Double(index) * fanWidth / Double(count - 1))
  }
}

public enum RingLayoutError: Error, Equatable, Sendable {
  case invalidRadius(Double)
  case emptyActionName
}
