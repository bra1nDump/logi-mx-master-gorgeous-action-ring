import CoreGraphics
import Foundation

/// The geometry of a liquid bridge fusing two circles, in the spirit of the
/// Dynamic Island. As `mergeProgress` rises the neck thickens until the two
/// shapes read as one continuous blob just before the backend auto-commits.
public struct MetaballBridge: Equatable, Sendable {
  /// The two points where the bridge meets circle A, mirrored across the A→B axis.
  public let contactA1: CGPoint
  public let contactA2: CGPoint
  /// The two points where the bridge meets circle B, mirrored across the axis.
  public let contactB1: CGPoint
  public let contactB2: CGPoint
  /// A control point on the axis near A that pulls the neck curve inward.
  public let controlA: CGPoint
  /// A control point on the axis near B that pulls the neck curve inward.
  public let controlB: CGPoint
  /// The width of the thinnest part of the neck, in points.
  public let neckWidth: CGFloat
  /// Whether a bridge should be drawn at all.
  public let isConnected: Bool
}

public enum MetaballGeometry {
  /// Builds the bridge between the moving bubble (A) and the target (B).
  ///
  /// - Parameters:
  ///   - mergeProgress: 0…1 fusion amount from the backend.
  ///   - connectThreshold: minimum progress at which a bridge appears.
  /// - Returns: `nil` when the shapes are coincident (no meaningful axis) so the
  ///   caller can fall back to a single circle.
  public static func bridge(
    centerA: CGPoint,
    radiusA: CGFloat,
    centerB: CGPoint,
    radiusB: CGFloat,
    mergeProgress: Double,
    connectThreshold: Double = 0.02
  ) -> MetaballBridge? {
    let dx = centerB.x - centerA.x
    let dy = centerB.y - centerA.y
    let distance = (dx * dx + dy * dy).squareRoot()
    guard distance > 1e-6 else { return nil }

    let progress = CGFloat(min(max(mergeProgress, 0), 1))
    let axis = CGPoint(x: dx / distance, y: dy / distance)
    let perpendicular = CGPoint(x: -axis.y, y: axis.x)

    // The neck grows from a thin thread to nearly the smaller circle's width.
    let smallerRadius = min(radiusA, radiusB)
    let neckWidth = smallerRadius * (0.35 + 0.65 * progress)
    let halfNeck = neckWidth / 2

    // Contact points sit where a chord of half-neck height meets each circle.
    let angleA = asin(min(1, halfNeck / radiusA))
    let angleB = asin(min(1, halfNeck / radiusB))

    func point(
      from center: CGPoint,
      radius: CGFloat,
      alongAxisSign axisSign: CGFloat,
      perpendicularSign: CGFloat,
      angle: CGFloat
    ) -> CGPoint {
      let along = axisSign * radius * cos(angle)
      let across = perpendicularSign * radius * sin(angle)
      return CGPoint(
        x: center.x + along * axis.x + across * perpendicular.x,
        y: center.y + along * axis.y + across * perpendicular.y
      )
    }

    let contactA1 = point(
      from: centerA, radius: radiusA, alongAxisSign: 1, perpendicularSign: 1, angle: angleA)
    let contactA2 = point(
      from: centerA, radius: radiusA, alongAxisSign: 1, perpendicularSign: -1, angle: angleA)
    let contactB1 = point(
      from: centerB, radius: radiusB, alongAxisSign: -1, perpendicularSign: 1, angle: angleB)
    let contactB2 = point(
      from: centerB, radius: radiusB, alongAxisSign: -1, perpendicularSign: -1, angle: angleB)

    // Controls ride the axis, easing outward from the contacts toward the waist
    // as the merge deepens so the neck stays taut, then relaxes.
    let contactAReach = radiusA * cos(angleA)
    let contactBReach = radiusB * cos(angleB)
    let waist = distance / 2
    let controlAReach = contactAReach + (waist - contactAReach) * (0.35 + 0.5 * progress)
    let controlBReach = contactBReach + (waist - contactBReach) * (0.35 + 0.5 * progress)
    let controlA = CGPoint(
      x: centerA.x + axis.x * controlAReach,
      y: centerA.y + axis.y * controlAReach
    )
    let controlB = CGPoint(
      x: centerB.x - axis.x * controlBReach,
      y: centerB.y - axis.y * controlBReach
    )

    return MetaballBridge(
      contactA1: contactA1,
      contactA2: contactA2,
      contactB1: contactB1,
      contactB2: contactB2,
      controlA: controlA,
      controlB: controlB,
      neckWidth: neckWidth,
      isConnected: mergeProgress > connectThreshold
    )
  }
}
