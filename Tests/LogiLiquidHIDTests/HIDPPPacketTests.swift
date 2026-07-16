import XCTest

@testable import LogiLiquidHID

final class HIDPPPacketTests: XCTestCase {
  func testRootProtocolVersionEncodesOneLongReport() throws {
    let packet = try HIDPPPacket.rootProtocolVersion(
      ping: (0x52, 0x4D, 0x50)
    )

    XCTAssertEqual(packet.bytes.count, 20)
    XCTAssertEqual(
      Array(packet.bytes.prefix(7)),
      [0x11, 0xFF, 0x00, 0x1A, 0x52, 0x4D, 0x50]
    )
    XCTAssertTrue(packet.bytes.suffix(13).allSatisfy { $0 == 0 })
  }

  func testRootFeatureEncodesFeatureIDBigEndian() throws {
    let packet = try HIDPPPacket.rootFeature(0x1B04)

    XCTAssertEqual(
      Array(packet.bytes.prefix(7)),
      [0x11, 0xFF, 0x00, 0x0A, 0x1B, 0x04, 0x00]
    )
  }

  func testLongResponseRoundTripsWithoutLosingPadding() throws {
    let bytes: [UInt8] =
      [
        0x11, 0xFF, 0x1E, 0x2A,
        0x01, 0x02, 0x03,
      ] + Array(repeating: 0, count: 13)

    let packet = try HIDPPPacket(bytes: bytes)
    XCTAssertEqual(packet.deviceIndex, 0xFF)
    XCTAssertEqual(packet.featureIndex, 0x1E)
    XCTAssertEqual(packet.functionID, 0x02)
    XCTAssertEqual(packet.softwareID, 0x0A)
    XCTAssertEqual(Array(packet.parameters.prefix(3)), [1, 2, 3])
    XCTAssertEqual(packet.bytes, bytes)
  }

  func testDeviceErrorReportThrowsTypedError() throws {
    let packet = try HIDPPPacket(
      bytes: [
        0x11, 0xFF, 0xFF, 0x1E,
        0x3A, 0x08,
      ] + Array(repeating: 0, count: 14))

    XCTAssertTrue(packet.isErrorResponse)
    XCTAssertThrowsError(try packet.requireSuccess()) { error in
      XCTAssertEqual(
        error as? HIDPPPacketError,
        .deviceError(
          code: 0x08,
          featureIndex: 0x1E,
          functionSoftwareByte: 0x3A
        )
      )
    }
  }

  func testMalformedReportsAndNibblesAreRejected() {
    XCTAssertThrowsError(try HIDPPPacket(bytes: [0x11, 0xFF])) {
      XCTAssertEqual($0 as? HIDPPPacketError, .invalidLength(2))
    }
    XCTAssertThrowsError(
      try HIDPPPacket(bytes: [0x10] + Array(repeating: 0, count: 19))
    ) {
      XCTAssertEqual($0 as? HIDPPPacketError, .invalidReportID(0x10))
    }
    XCTAssertThrowsError(
      try HIDPPPacket(featureIndex: 0, functionID: 0x10)
    ) {
      XCTAssertEqual(
        $0 as? HIDPPPacketError,
        .nibbleOutOfRange(name: "functionID", value: 0x10)
      )
    }
    XCTAssertThrowsError(
      try HIDPPPacket(
        featureIndex: 0,
        functionID: 0,
        parameters: Array(repeating: 0, count: 17)
      )
    ) {
      XCTAssertEqual($0 as? HIDPPPacketError, .parametersTooLong(17))
    }
  }
}
