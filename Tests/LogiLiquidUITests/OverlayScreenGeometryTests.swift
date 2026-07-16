import CoreGraphics
import XCTest

@testable import LogiLiquidUI

final class OverlayScreenGeometryTests: XCTestCase {
  private let accuracy: CGFloat = 1e-6

  private func makeDisplay(
    appKitFrame: CGRect,
    primaryHeight: CGFloat,
    scale: CGFloat = 2
  ) -> OverlayDisplay {
    OverlayDisplay(
      cgFrame: OverlayScreenGeometry.cgFrame(
        fromAppKit: appKitFrame,
        primaryDisplayHeight: primaryHeight
      ),
      appKitFrame: appKitFrame,
      backingScaleFactor: scale
    )
  }

  func testCGTopLeftPointConvertsToAppKitBottomLeft() {
    let point = CGPoint(x: 100, y: 50)
    let converted = OverlayScreenGeometry.appKitPoint(
      fromCGGlobal: point,
      primaryDisplayHeight: 1080
    )
    XCTAssertEqual(converted.x, 100, accuracy: accuracy)
    XCTAssertEqual(converted.y, 1030, accuracy: accuracy)
  }

  func testPrimaryDisplayCGFrameIsIdentityInBothSystems() {
    let appKit = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let cg = OverlayScreenGeometry.cgFrame(fromAppKit: appKit, primaryDisplayHeight: 1080)
    XCTAssertEqual(cg, appKit)
  }

  func testSecondaryDisplayFrameConversionIsInvertible() {
    let primaryHeight: CGFloat = 1080
    // A secondary display placed above-right of the primary in AppKit space.
    let appKit = CGRect(x: 1920, y: 200, width: 1440, height: 900)
    let cg = OverlayScreenGeometry.cgFrame(fromAppKit: appKit, primaryDisplayHeight: primaryHeight)
    // cgMinY = primaryHeight - appKitMaxY = 1080 - 1100 = -20 (it sits above).
    XCTAssertEqual(cg.minX, 1920, accuracy: accuracy)
    XCTAssertEqual(cg.minY, -20, accuracy: accuracy)
    XCTAssertEqual(cg.width, 1440, accuracy: accuracy)
    XCTAssertEqual(cg.height, 900, accuracy: accuracy)

    // The reflection is its own inverse: converting the CG frame back yields the
    // original AppKit frame.
    let roundTrip = OverlayScreenGeometry.cgFrame(
      fromAppKit: cg,
      primaryDisplayHeight: primaryHeight
    )
    XCTAssertEqual(roundTrip, appKit)
  }

  func testPlacementSelectsContainingDisplayAndComputesLocalOrigin() {
    let primaryHeight: CGFloat = 1080
    let primary = makeDisplay(
      appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      primaryHeight: primaryHeight
    )
    let secondary = makeDisplay(
      appKitFrame: CGRect(x: 1920, y: 0, width: 1440, height: 900),
      primaryHeight: primaryHeight
    )

    // A CG point clearly on the secondary display (x >= 1920).
    let point = CGPoint(x: 2000, y: 120)
    let placement = OverlayScreenGeometry.placement(
      forCGGlobalPoint: point,
      displays: [primary, secondary]
    )
    let resolved = try! XCTUnwrap(placement)
    XCTAssertEqual(resolved.display, secondary)
    // secondary cgFrame origin is (1920, 1080 - 900) = (1920, 180).
    XCTAssertEqual(resolved.localOrigin.x, 80, accuracy: accuracy)
    XCTAssertEqual(resolved.localOrigin.y, 120 - 180, accuracy: accuracy)
  }

  func testPlacementFallsBackToNearestDisplayWhenPointIsInDeadSpace() {
    let primaryHeight: CGFloat = 1080
    let primary = makeDisplay(
      appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      primaryHeight: primaryHeight
    )
    let secondary = makeDisplay(
      appKitFrame: CGRect(x: 1920, y: 0, width: 1440, height: 900),
      primaryHeight: primaryHeight
    )
    // A point just below the primary (primary CG bounds end at y = 1080) and well
    // to the left of the secondary (secondary CG bounds start at x = 1920), so the
    // nearest edge belongs to the primary.
    let point = CGPoint(x: 500, y: 1200)
    let placement = OverlayScreenGeometry.placement(
      forCGGlobalPoint: point,
      displays: [primary, secondary]
    )
    let resolved = try! XCTUnwrap(placement)
    XCTAssertEqual(resolved.display, primary)
  }

  func testPlacementIsNilWithoutDisplays() {
    XCTAssertNil(
      OverlayScreenGeometry.placement(forCGGlobalPoint: .zero, displays: [])
    )
  }

  func testRetinaBackingScaleIsPreserved() {
    let display = makeDisplay(
      appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      primaryHeight: 1080,
      scale: 2
    )
    XCTAssertEqual(display.backingScaleFactor, 2, accuracy: accuracy)
  }
}
