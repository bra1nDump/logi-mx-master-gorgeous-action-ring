import Foundation
import XCTest

@testable import LogiLiquidCore

final class RingLayoutTests: XCTestCase {
  func testEmptyActionsKeepFourZoneRecordsAndBottomPlaceholderWithoutCircle() throws {
    let layout = try RingLayout(zones: RingZones(), radius: 120)
    XCTAssertEqual(layout.origin, .zero)
    XCTAssertEqual(layout.targets, [])
    XCTAssertEqual(layout.zones.map(\.zone), [.top, .right, .bottom, .left])
    XCTAssertEqual(layout.zones.map(\.actionNames), [[], [], [], []])
    XCTAssertEqual(
      layout.zones.map(\.isPlaceholder),
      [false, false, true, false]
    )
  }

  func testRequestedOneTopTwoRightThreeLeftFanWithinCardinalSectors() throws {
    let layout = try RingLayout(
      zones: RingZones(
        top: ["Spotify"],
        right: ["Telegram", "ChatGPT"],
        bottom: [],
        left: ["Record", "Capture", "Aqua"]
      ),
      radius: 100
    )

    XCTAssertEqual(
      layout.targets.map(\.actionName),
      ["Spotify", "Telegram", "ChatGPT", "Record", "Capture", "Aqua"]
    )
    XCTAssertEqual(
      layout.targets.map(\.zone),
      [.top, .right, .right, .left, .left, .left]
    )
    XCTAssertEqual(layout.targets.map(\.zoneIndex), [0, 0, 1, 0, 1, 2])
    XCTAssertEqual(layout.targets.map(\.index), [0, 1, 2, 3, 4, 5])

    assertVector(layout.targets[0].vectorFromOrigin, x: 0, y: -100)
    assertVector(layout.targets[1].vectorFromOrigin, x: 86.602_540, y: -50)
    assertVector(layout.targets[2].vectorFromOrigin, x: 86.602_540, y: 50)
    assertVector(layout.targets[3].vectorFromOrigin, x: -76.604_444, y: -64.278_761)
    assertVector(layout.targets[4].vectorFromOrigin, x: -100, y: 0)
    assertVector(layout.targets[5].vectorFromOrigin, x: -76.604_444, y: 64.278_761)

    let bottom = try XCTUnwrap(layout.zones.first { $0.zone == .bottom })
    XCTAssertTrue(bottom.actionNames.isEmpty)
    XCTAssertTrue(bottom.isPlaceholder)
  }

  func testArbitraryCountIsEquallySpacedInsideItsZoneFan() throws {
    let layout = try RingLayout(
      zones: RingZones(right: ["A", "B", "C", "D", "E"]),
      radius: 137
    )
    let angles = layout.targets.map {
      atan2($0.vectorFromOrigin.y, $0.vectorFromOrigin.x)
    }

    XCTAssertEqual(try XCTUnwrap(angles.first), -2 * .pi / 9, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(angles.last), 2 * .pi / 9, accuracy: 0.000_001)
    for target in layout.targets {
      XCTAssertEqual(target.vectorFromOrigin.magnitude, 137, accuracy: 0.000_001)
      XCTAssertEqual(target.zone, .right)
    }
    for index in 1..<angles.count {
      XCTAssertEqual(angles[index] - angles[index - 1], .pi / 9, accuracy: 0.000_001)
    }
  }

  func testThreeTargetZoneExpandsToMaintainPreferredCenterSpacing() throws {
    let radius = 108.0
    let twoTargets = try RingLayout(
      zones: RingZones(left: ["A", "B"]),
      radius: radius
    ).targets
    let threeTargets = try RingLayout(
      zones: RingZones(left: ["A", "B", "C"]),
      radius: radius
    ).targets

    XCTAssertEqual(angularSpan(twoTargets), .pi / 3, accuracy: 0.000_001)
    XCTAssertGreaterThan(angularSpan(threeTargets), angularSpan(twoTargets))
    for (first, second) in zip(threeTargets, threeTargets.dropFirst()) {
      XCTAssertEqual(
        first.vectorFromOrigin.distance(to: second.vectorFromOrigin),
        72,
        accuracy: 0.000_001
      )
    }
  }

  func testPopulatedBottomIsNoLongerPlaceholder() throws {
    let layout = try RingLayout(
      zones: RingZones(bottom: ["Context Action"]),
      radius: 80
    )
    let bottom = try XCTUnwrap(layout.zones.first { $0.zone == .bottom })
    XCTAssertFalse(bottom.isPlaceholder)
    XCTAssertEqual(bottom.actionNames, ["Context Action"])
    XCTAssertEqual(layout.targets.first?.zone, .bottom)
    assertVector(try XCTUnwrap(layout.targets.first).vectorFromOrigin, x: 0, y: 80)
  }

  func testLegacyFourActionInitializerMapsToCardinals() throws {
    let layout = try RingLayout(
      actionNames: ["Top", "Right", "Bottom", "Left"],
      radius: 80
    )
    XCTAssertEqual(layout.targets.map(\.zone), [.top, .right, .bottom, .left])
    assertVector(layout.targets[0].vectorFromOrigin, x: 0, y: -80)
    assertVector(layout.targets[1].vectorFromOrigin, x: 80, y: 0)
    assertVector(layout.targets[2].vectorFromOrigin, x: 0, y: 80)
    assertVector(layout.targets[3].vectorFromOrigin, x: -80, y: 0)
  }

  func testLayoutRejectsInvalidRadiusAndPlaceholderActionName() {
    XCTAssertThrowsError(try RingLayout(zones: RingZones(top: ["A"]), radius: 0)) { error in
      XCTAssertEqual(error as? RingLayoutError, .invalidRadius(0))
    }
    XCTAssertThrowsError(
      try RingLayout(zones: RingZones(left: ["A", " "]), radius: 100)
    ) { error in
      XCTAssertEqual(error as? RingLayoutError, .emptyActionName)
    }
  }

  private func assertVector(
    _ vector: Vector2,
    x: Double,
    y: Double,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(vector.x, x, accuracy: 0.000_001, file: file, line: line)
    XCTAssertEqual(vector.y, y, accuracy: 0.000_001, file: file, line: line)
  }

  private func angularSpan(_ targets: [RingTarget]) -> Double {
    let first = try! XCTUnwrap(targets.first).vectorFromOrigin
    let last = try! XCTUnwrap(targets.last).vectorFromOrigin
    let cosine = (first.x * last.x + first.y * last.y) / (first.magnitude * last.magnitude)
    return acos(min(max(cosine, -1), 1))
  }
}
