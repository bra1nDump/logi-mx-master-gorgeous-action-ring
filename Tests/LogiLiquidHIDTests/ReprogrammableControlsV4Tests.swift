import XCTest

@testable import LogiLiquidHID

final class ReprogrammableControlsV4Tests: XCTestCase {
  private let featureIndex: UInt8 = 0x1E

  func testRequestBuildersUseDocumentedFunctionIDs() throws {
    let count = try ReprogrammableControlsV4.getCountRequest(
      featureIndex: featureIndex
    )
    let info = try ReprogrammableControlsV4.controlInfoRequest(
      featureIndex: featureIndex,
      index: 7
    )
    let reporting = try ReprogrammableControlsV4.getReportingRequest(
      featureIndex: featureIndex,
      controlID: 0x01A0
    )

    XCTAssertEqual(count.functionID, 0)
    XCTAssertEqual(info.functionID, 1)
    XCTAssertEqual(info.parameters[0], 7)
    XCTAssertEqual(reporting.functionID, 2)
    XCTAssertEqual(Array(reporting.parameters.prefix(3)), [0x01, 0xA0, 0])
  }

  func testTemporaryRawXYPreservesUnsupportedForceFlagAndRemap() throws {
    let original = state(
      diverted: false,
      persistentlyDiverted: true,
      rawXY: false,
      forceRawXY: false,
      remappedTo: 0x00C3,
      analytics: true,
      rawWheel: true
    )
    let packet = try ReprogrammableControlsV4.setReportingRequest(
      featureIndex: featureIndex,
      controlID: 0x01A0,
      change: .temporaryRawXY(preserving: original)
    )

    XCTAssertEqual(packet.functionID, 3)
    XCTAssertEqual(
      Array(packet.parameters.prefix(6)),
      [0x01, 0xA0, 0x33, 0x00, 0xC3, 0x00]
    )
  }

  func testRestorationBuilderWritesEveryPreviouslyObservedFieldExactly() throws {
    let original = state(
      diverted: false,
      persistentlyDiverted: true,
      rawXY: false,
      forceRawXY: true,
      remappedTo: 0x00C3,
      analytics: false,
      rawWheel: true
    )
    let packet = try ReprogrammableControlsV4.setReportingRequest(
      featureIndex: featureIndex,
      controlID: 0x01A0,
      change: .restoring(original)
    )

    // Primary flags 0xEE:
    // temp valid/off, persistent valid/on, rawXY valid/off, force valid/on.
    // Secondary flags 0x0E: analytics valid/off, raw wheel valid/on.
    XCTAssertEqual(
      Array(packet.parameters.prefix(6)),
      [0x01, 0xA0, 0xEE, 0x00, 0xC3, 0x0E]
    )
  }

  func testControlInfoCombinesPrimaryAndAdditionalCapabilityBytes() throws {
    let response = try packet(
      functionID: 1,
      parameters: [
        0x01, 0xA0,
        0x00, 0xD7,
        0x30,
        0x04,
        0x02,
        0x80,
        0x03,
      ]
    )
    let info = try ReprogrammableControlsV4.parseControlInfo(
      from: response,
      index: 9
    )

    XCTAssertEqual(info.index, 9)
    XCTAssertEqual(info.controlID, 0x01A0)
    XCTAssertEqual(info.taskID, 0x00D7)
    XCTAssertEqual(info.capabilities.rawValue, 0x0330)
    XCTAssertTrue(info.capabilities.contains(.reprogrammable))
    XCTAssertTrue(info.capabilities.contains(.divertable))
    XCTAssertTrue(info.capabilities.contains(.rawXY))
    XCTAssertTrue(info.capabilities.contains(.forceRawXY))
    XCTAssertEqual(info.position, 4)
    XCTAssertEqual(info.group, 2)
    XCTAssertEqual(info.groupMask, 0x80)
  }

  func testReportingStateDecodesValueBitsAndRemap() throws {
    let response = try packet(
      functionID: 2,
      parameters: [0x01, 0xA0, 0x55, 0x00, 0xC3, 0x05]
    )
    let state = try ReprogrammableControlsV4.parseReportingState(
      from: response,
      expectedControlID: 0x01A0
    )

    XCTAssertTrue(state.diverted)
    XCTAssertTrue(state.persistentlyDiverted)
    XCTAssertTrue(state.rawXY)
    XCTAssertTrue(state.forceRawXY)
    XCTAssertEqual(state.remappedTo, 0x00C3)
    XCTAssertTrue(state.analyticsKeyEvents)
    XCTAssertTrue(state.rawWheel)
  }

  func testPressedControlEventsDecodeUpToFourCIDsAndRelease() throws {
    let down = try packet(
      functionID: 0,
      softwareID: 0,
      parameters: [0x01, 0xA0, 0x00, 0xC3, 0, 0]
    )
    let released = try packet(
      functionID: 0,
      softwareID: 0,
      parameters: [0, 0]
    )

    XCTAssertEqual(
      ReprogrammableControlsV4.parseEvent(
        from: down,
        featureIndex: featureIndex
      ),
      .pressedControlIDs([0x01A0, 0x00C3])
    )
    XCTAssertEqual(
      ReprogrammableControlsV4.parseEvent(
        from: released,
        featureIndex: featureIndex
      ),
      .pressedControlIDs([])
    )
  }

  func testRawXYEventDecodesSignedBigEndianDeltas() throws {
    let event = try packet(
      functionID: 1,
      softwareID: 0,
      parameters: [0xFF, 0xFB, 0x00, 0x0C]
    )

    XCTAssertEqual(
      ReprogrammableControlsV4.parseEvent(
        from: event,
        featureIndex: featureIndex
      ),
      .rawXY(dx: -5, dy: 12)
    )
  }

  func testEventParserIgnoresResponsesAndOtherFeatures() throws {
    let response = try packet(
      functionID: 0,
      softwareID: HIDPPPacket.defaultSoftwareID,
      parameters: [0x01, 0xA0]
    )
    let other = try HIDPPPacket(
      featureIndex: 0x22,
      functionID: 0,
      softwareID: 0,
      parameters: [0x01, 0xA0]
    )

    XCTAssertNil(
      ReprogrammableControlsV4.parseEvent(
        from: response,
        featureIndex: featureIndex
      )
    )
    XCTAssertNil(
      ReprogrammableControlsV4.parseEvent(
        from: other,
        featureIndex: featureIndex
      )
    )
  }

  private func state(
    diverted: Bool,
    persistentlyDiverted: Bool,
    rawXY: Bool,
    forceRawXY: Bool,
    remappedTo: UInt16?,
    analytics: Bool,
    rawWheel: Bool
  ) -> ControlReportingState {
    ControlReportingState(
      controlID: 0x01A0,
      diverted: diverted,
      persistentlyDiverted: persistentlyDiverted,
      rawXY: rawXY,
      forceRawXY: forceRawXY,
      remappedTo: remappedTo,
      analyticsKeyEvents: analytics,
      rawWheel: rawWheel
    )
  }

  private func packet(
    functionID: UInt8,
    softwareID: UInt8 = HIDPPPacket.defaultSoftwareID,
    parameters: [UInt8]
  ) throws -> HIDPPPacket {
    try HIDPPPacket(
      featureIndex: featureIndex,
      functionID: functionID,
      softwareID: softwareID,
      parameters: parameters
    )
  }
}
