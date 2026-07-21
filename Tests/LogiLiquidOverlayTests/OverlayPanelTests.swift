import AppKit
import XCTest

@testable import LogiLiquidOverlay

@MainActor
final class OverlayPanelTests: XCTestCase {
  func testPanelUsesFullscreenAllSpacesConfiguration() {
    let panel = OverlayPanel(contentView: NSView()) {}
    defer { panel.retire() }

    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.styleMask.contains(.borderless))
    XCTAssertEqual(panel.level, .screenSaver)
    XCTAssertTrue(panel.isFloatingPanel)
    XCTAssertTrue(panel.worksWhenModal)
    XCTAssertFalse(panel.hidesOnDeactivate)
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    XCTAssertTrue(panel.collectionBehavior.contains(.transient))
    XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
    XCTAssertFalse(panel.collectionBehavior.contains(.stationary))
  }

  func testOnlySleepNotificationsInvalidateTheCurrentInteraction() {
    let invalidatingChanges: Set<OverlayWindowEnvironmentChange> = [
      .screensSleeping,
      .systemSleeping,
    ]

    for change in OverlayWindowEnvironmentChange.allCases {
      XCTAssertEqual(
        change.invalidatesInteraction,
        invalidatingChanges.contains(change),
        "unexpected invalidation policy for \(change.rawValue)"
      )
    }
  }

  func testOnlySpaceAndScreenChangesRefreshPresentation() {
    let refreshingChanges: Set<OverlayWindowEnvironmentChange> = [
      .activeSpace,
      .screenParameters,
    ]

    for change in OverlayWindowEnvironmentChange.allCases {
      XCTAssertEqual(
        change.refreshesPresentation,
        refreshingChanges.contains(change),
        "unexpected presentation-refresh policy for \(change.rawValue)"
      )
    }
  }
}
