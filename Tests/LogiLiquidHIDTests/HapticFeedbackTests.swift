import XCTest

@testable import LogiLiquidHID

final class HapticFeedbackTests: XCTestCase {
  func testPlayWaveformBuildsFeatureFunctionFourWithoutTouchingHardware() throws {
    let request = try HapticFeedback.playWaveformRequest(
      featureIndex: 0x1C,
      waveformID: 0x07
    )

    XCTAssertEqual(
      Array(request.bytes.prefix(5)),
      [0x11, 0xFF, 0x1C, 0x4A, 0x07]
    )
    XCTAssertTrue(request.parameters.dropFirst().allSatisfy { $0 == 0 })
  }
}
