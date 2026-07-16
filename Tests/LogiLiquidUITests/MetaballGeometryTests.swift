import CoreGraphics
import XCTest

@testable import LogiLiquidUI

final class MetaballGeometryTests: XCTestCase {
  private let centerA = CGPoint(x: 0, y: 0)
  private let radiusA: CGFloat = 22
  private let centerB = CGPoint(x: 80, y: 0)
  private let radiusB: CGFloat = 28

  private func bridge(mergeProgress: Double) -> MetaballBridge? {
    MetaballGeometry.bridge(
      centerA: centerA,
      radiusA: radiusA,
      centerB: centerB,
      radiusB: radiusB,
      mergeProgress: mergeProgress
    )
  }

  func testContactPointsLieExactlyOnBothCircles() {
    let bridge = try! XCTUnwrap(bridge(mergeProgress: 0.6))
    let onA = [bridge.contactA1, bridge.contactA2]
    for point in onA {
      XCTAssertEqual(distance(point, centerA), radiusA, accuracy: 1e-6)
    }
    let onB = [bridge.contactB1, bridge.contactB2]
    for point in onB {
      XCTAssertEqual(distance(point, centerB), radiusB, accuracy: 1e-6)
    }
  }

  func testContactPairsAreMirroredAcrossTheAxis() {
    let bridge = try! XCTUnwrap(bridge(mergeProgress: 0.5))
    // The A→B axis here is the x-axis, so mirrored contact points share an x and
    // carry opposite y, and their midpoint sits on the axis (y == 0).
    XCTAssertEqual(bridge.contactA1.x, bridge.contactA2.x, accuracy: 1e-6)
    XCTAssertEqual(bridge.contactA1.y, -bridge.contactA2.y, accuracy: 1e-6)
    XCTAssertEqual(bridge.contactB1.x, bridge.contactB2.x, accuracy: 1e-6)
    XCTAssertEqual(bridge.contactB1.y, -bridge.contactB2.y, accuracy: 1e-6)
    // Controls ride the axis.
    XCTAssertEqual(bridge.controlA.y, 0, accuracy: 1e-6)
    XCTAssertEqual(bridge.controlB.y, 0, accuracy: 1e-6)
  }

  func testNeckWidthGrowsMonotonicallyWithMergeProgress() {
    let widths = stride(from: 0.1, through: 1.0, by: 0.1).map {
      bridge(mergeProgress: $0)!.neckWidth
    }
    for (lower, higher) in zip(widths, widths.dropFirst()) {
      XCTAssertGreaterThan(higher, lower)
    }
    // The neck never exceeds the smaller circle's diameter.
    XCTAssertLessThanOrEqual(widths.last!, min(radiusA, radiusB) + 1e-6)
  }

  func testConnectionRespectsThreshold() {
    XCTAssertFalse(bridge(mergeProgress: 0.0)!.isConnected)
    XCTAssertFalse(bridge(mergeProgress: 0.01)!.isConnected)
    XCTAssertTrue(bridge(mergeProgress: 0.5)!.isConnected)
    XCTAssertTrue(bridge(mergeProgress: 1.0)!.isConnected)
  }

  func testCoincidentCentersReturnNil() {
    XCTAssertNil(
      MetaballGeometry.bridge(
        centerA: centerA,
        radiusA: radiusA,
        centerB: centerA,
        radiusB: radiusB,
        mergeProgress: 0.5
      )
    )
  }

  func testBridgeIsOrientationIndependent() {
    // A diagonal axis must keep contacts on their circles and controls on-axis.
    let a = CGPoint(x: 10, y: 10)
    let b = CGPoint(x: 70, y: 90)
    let bridge = try! XCTUnwrap(
      MetaballGeometry.bridge(
        centerA: a, radiusA: radiusA, centerB: b, radiusB: radiusB, mergeProgress: 0.7)
    )
    XCTAssertEqual(distance(bridge.contactA1, a), radiusA, accuracy: 1e-6)
    XCTAssertEqual(distance(bridge.contactB2, b), radiusB, accuracy: 1e-6)

    // controlA lies on the A→B line: the cross product with the axis is ~0.
    let axis = CGPoint(x: b.x - a.x, y: b.y - a.y)
    let toControl = CGPoint(x: bridge.controlA.x - a.x, y: bridge.controlA.y - a.y)
    let cross = axis.x * toControl.y - axis.y * toControl.x
    XCTAssertEqual(cross, 0, accuracy: 1e-4)
  }

  private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    hypot(lhs.x - rhs.x, lhs.y - rhs.y)
  }
}
