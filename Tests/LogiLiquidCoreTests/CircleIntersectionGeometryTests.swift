import Foundation
import XCTest

@testable import LogiLiquidCore

final class CircleIntersectionGeometryTests: XCTestCase {
  func testDisjointTangentAndContainedCirclesUseExactLimitAreas() {
    XCTAssertEqual(
      CircleIntersectionGeometry.overlapArea(
        radiusA: 2,
        radiusB: 3,
        centerDistance: 5
      ),
      0
    )
    XCTAssertEqual(
      CircleIntersectionGeometry.overlapArea(
        radiusA: 2,
        radiusB: 3,
        centerDistance: 1
      ),
      .pi * 4,
      accuracy: 1e-12
    )
    XCTAssertEqual(
      CircleIntersectionGeometry.overlapFractionOfCircleA(
        radiusA: 2,
        radiusB: 3,
        centerDistance: 0
      ),
      1,
      accuracy: 1e-12
    )
  }

  func testEqualCircleLensMatchesClosedForm() {
    let radius = 10.0
    let area = CircleIntersectionGeometry.overlapArea(
      radiusA: radius,
      radiusB: radius,
      centerDistance: radius
    )
    let expected =
      (2 * .pi / 3 - sqrt(3) / 2) * radius * radius
    XCTAssertEqual(area, expected, accuracy: 1e-10)
  }

  func testDefaultBubbleGeometryCrossesLatchAreaAtExactBoundary() {
    let movingRadius = RingInteractionProfile.defaultMovingBubbleRadius
    let targetRadius = RingInteractionProfile.defaultTargetBubbleRadius
    // Independently solved root of the exact two-circle lens equation for the
    // shared 22.4/28 geometry.
    let latchAreaDistance = 30.49246920667748

    XCTAssertEqual(
      CircleIntersectionGeometry.overlapFractionOfCircleA(
        radiusA: movingRadius,
        radiusB: targetRadius,
        centerDistance: latchAreaDistance
      ),
      RingInteractionThresholds.latchOverlapFraction,
      accuracy: 1e-12
    )
    XCTAssertLessThan(
      CircleIntersectionGeometry.overlapFractionOfCircleA(
        radiusA: movingRadius,
        radiusB: targetRadius,
        centerDistance: latchAreaDistance + 0.000_001
      ),
      RingInteractionThresholds.latchOverlapFraction
    )
    XCTAssertGreaterThan(
      CircleIntersectionGeometry.overlapFractionOfCircleA(
        radiusA: movingRadius,
        radiusB: targetRadius,
        centerDistance: latchAreaDistance - 0.000_001
      ),
      RingInteractionThresholds.latchOverlapFraction
    )
  }

  func testInvalidGeometryCannotAccidentallyLatch() {
    for area in [
      CircleIntersectionGeometry.overlapArea(
        radiusA: 0,
        radiusB: 1,
        centerDistance: 0
      ),
      CircleIntersectionGeometry.overlapArea(
        radiusA: 1,
        radiusB: .nan,
        centerDistance: 0
      ),
      CircleIntersectionGeometry.overlapArea(
        radiusA: 1,
        radiusB: 1,
        centerDistance: -1
      ),
    ] {
      XCTAssertEqual(area, 0)
    }
  }
}
