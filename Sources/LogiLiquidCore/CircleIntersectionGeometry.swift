import Foundation

/// Exact Euclidean intersection geometry for two circles. The interaction
/// machine uses this instead of a center-distance approximation when deciding
/// whether the moving bubble has crossed its configured overlap boundary.
public enum CircleIntersectionGeometry {
  public static func overlapArea(
    radiusA: Double,
    radiusB: Double,
    centerDistance: Double
  ) -> Double {
    guard radiusA.isFinite, radiusA > 0,
      radiusB.isFinite, radiusB > 0,
      centerDistance.isFinite, centerDistance >= 0
    else {
      return 0
    }

    let smallerRadius = min(radiusA, radiusB)
    if centerDistance <= abs(radiusA - radiusB) {
      return .pi * smallerRadius * smallerRadius
    }
    if centerDistance >= radiusA + radiusB {
      return 0
    }

    let distanceSquared = centerDistance * centerDistance
    let radiusASquared = radiusA * radiusA
    let radiusBSquared = radiusB * radiusB
    let angleA = acos(
      clamp(
        (distanceSquared + radiusASquared - radiusBSquared)
          / (2 * centerDistance * radiusA)
      )
    )
    let angleB = acos(
      clamp(
        (distanceSquared + radiusBSquared - radiusASquared)
          / (2 * centerDistance * radiusB)
      )
    )
    let radical =
      (-centerDistance + radiusA + radiusB)
      * (centerDistance + radiusA - radiusB)
      * (centerDistance - radiusA + radiusB)
      * (centerDistance + radiusA + radiusB)

    return
      radiusASquared * angleA
      + radiusBSquared * angleB
      - 0.5 * sqrt(max(radical, 0))
  }

  public static func overlapFractionOfCircleA(
    radiusA: Double,
    radiusB: Double,
    centerDistance: Double
  ) -> Double {
    guard radiusA.isFinite, radiusA > 0 else { return 0 }
    let circleAArea = Double.pi * radiusA * radiusA
    return min(
      max(
        overlapArea(
          radiusA: radiusA,
          radiusB: radiusB,
          centerDistance: centerDistance
        ) / circleAArea,
        0
      ),
      1
    )
  }

  private static func clamp(_ value: Double) -> Double {
    min(max(value, -1), 1)
  }
}
