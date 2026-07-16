import Foundation

public struct ReprogrammableControlCapabilities: OptionSet, Codable, Sendable {
  public let rawValue: UInt16

  public init(rawValue: UInt16) {
    self.rawValue = rawValue
  }

  public static let mouse = Self(rawValue: 1 << 0)
  public static let functionKey = Self(rawValue: 1 << 1)
  public static let hotkey = Self(rawValue: 1 << 2)
  public static let fnToggle = Self(rawValue: 1 << 3)
  public static let reprogrammable = Self(rawValue: 1 << 4)
  public static let divertable = Self(rawValue: 1 << 5)
  public static let persistentlyDivertable = Self(rawValue: 1 << 6)
  public static let virtualControl = Self(rawValue: 1 << 7)
  public static let rawXY = Self(rawValue: 1 << 8)
  public static let forceRawXY = Self(rawValue: 1 << 9)
  public static let analyticsKeyEvents = Self(rawValue: 1 << 10)
  public static let rawWheel = Self(rawValue: 1 << 11)
}

public struct ReprogrammableControlInfo: Codable, Equatable, Sendable {
  public let index: UInt8
  public let controlID: UInt16
  public let taskID: UInt16
  public let capabilities: ReprogrammableControlCapabilities
  public let position: UInt8
  public let group: UInt8
  public let groupMask: UInt8
}

public struct ControlReportingState: Codable, Equatable, Sendable {
  public let controlID: UInt16
  public let diverted: Bool
  public let persistentlyDiverted: Bool
  public let rawXY: Bool
  public let forceRawXY: Bool
  public let remappedTo: UInt16?
  public let analyticsKeyEvents: Bool
  public let rawWheel: Bool

  public init(
    controlID: UInt16,
    diverted: Bool,
    persistentlyDiverted: Bool,
    rawXY: Bool,
    forceRawXY: Bool,
    remappedTo: UInt16?,
    analyticsKeyEvents: Bool,
    rawWheel: Bool
  ) {
    self.controlID = controlID
    self.diverted = diverted
    self.persistentlyDiverted = persistentlyDiverted
    self.rawXY = rawXY
    self.forceRawXY = forceRawXY
    self.remappedTo = remappedTo
    self.analyticsKeyEvents = analyticsKeyEvents
    self.rawWheel = rawWheel
  }
}

/// Optional booleans map to HID++ value/valid bit pairs. Nil leaves that
/// setting untouched. The remap target has no validity bit, so callers must
/// preserve the current target when changing unrelated settings.
public struct ControlReportingChange: Codable, Equatable, Sendable {
  public var diverted: Bool?
  public var persistentlyDiverted: Bool?
  public var rawXY: Bool?
  public var forceRawXY: Bool?
  public var remappedTo: UInt16?
  public var analyticsKeyEvents: Bool?
  public var rawWheel: Bool?

  public init(
    diverted: Bool? = nil,
    persistentlyDiverted: Bool? = nil,
    rawXY: Bool? = nil,
    forceRawXY: Bool? = nil,
    remappedTo: UInt16? = nil,
    analyticsKeyEvents: Bool? = nil,
    rawWheel: Bool? = nil
  ) {
    self.diverted = diverted
    self.persistentlyDiverted = persistentlyDiverted
    self.rawXY = rawXY
    self.forceRawXY = forceRawXY
    self.remappedTo = remappedTo
    self.analyticsKeyEvents = analyticsKeyEvents
    self.rawWheel = rawWheel
  }

  /// Enables only volatile diversion and raw-XY reporting while preserving the
  /// current remap target. The physical MX Master 4 Sense Panel advertises raw
  /// XY but not forced raw XY; the latter belongs to its virtual gesture
  /// control. Persistent and unsupported reporting flags remain untouched.
  public static func temporaryRawXY(
    preserving state: ControlReportingState
  ) -> Self {
    Self(
      diverted: true,
      rawXY: true,
      remappedTo: state.remappedTo
    )
  }

  /// Writes every reportable field back to the value observed before the
  /// temporary diversion. This is intentionally stronger than merely clearing
  /// two bits: it restores a user's pre-existing Options+/firmware mapping.
  public static func restoring(_ state: ControlReportingState) -> Self {
    Self(
      diverted: state.diverted,
      persistentlyDiverted: state.persistentlyDiverted,
      rawXY: state.rawXY,
      forceRawXY: state.forceRawXY,
      remappedTo: state.remappedTo,
      analyticsKeyEvents: state.analyticsKeyEvents,
      rawWheel: state.rawWheel
    )
  }
}

public enum ReprogrammableControlsEvent: Codable, Equatable, Sendable {
  /// The up-to-four diverted controls currently held. An empty list is the
  /// release notification.
  case pressedControlIDs([UInt16])
  case rawXY(dx: Int16, dy: Int16)
}

public enum ReprogrammableControlsError:
  Error, Equatable, CustomStringConvertible, LocalizedError, Sendable
{
  case malformedResponse(operation: String)
  case responseControlMismatch(expected: UInt16, actual: UInt16)
  case sensePanelNotAdvertised
  case sensePanelNotDivertable(ReprogrammableControlCapabilities)
  case sensePanelDoesNotSupportRawXY(ReprogrammableControlCapabilities)
  case sensePanelDoesNotSupportForceRawXY(ReprogrammableControlCapabilities)
  case snapshotBelongsToAnotherDevice
  case diversionVerificationFailed(ControlReportingState)
  case restoreVerificationFailed(
    expected: ControlReportingState,
    actual: ControlReportingState
  )

  public var description: String {
    switch self {
    case .malformedResponse(let operation):
      "malformed Reprogrammable Controls V4 response for \(operation)"
    case .responseControlMismatch(let expected, let actual):
      String(
        format: "control response mismatch: expected 0x%04X, got 0x%04X",
        expected,
        actual
      )
    case .sensePanelNotAdvertised:
      "the device did not advertise MX Master 4 Sense Panel control 0x01A0"
    case .sensePanelNotDivertable(let capabilities):
      String(
        format: "Sense Panel is not divertable (capabilities 0x%04X)",
        capabilities.rawValue
      )
    case .sensePanelDoesNotSupportRawXY(let capabilities):
      String(
        format: "Sense Panel does not advertise raw XY (capabilities 0x%04X)",
        capabilities.rawValue
      )
    case .sensePanelDoesNotSupportForceRawXY(let capabilities):
      String(
        format: "Sense Panel does not advertise forced raw XY (capabilities 0x%04X)",
        capabilities.rawValue
      )
    case .snapshotBelongsToAnotherDevice:
      "Sense Panel restoration snapshot belongs to another HID device"
    case .diversionVerificationFailed(let actual):
      "Sense Panel did not enter temporary raw-XY diversion; read back \(actual)"
    case .restoreVerificationFailed(let expected, let actual):
      "Sense Panel reporting restoration did not stick; expected \(expected), got \(actual)"
    }
  }

  public var errorDescription: String? { description }
}

public enum ReprogrammableControlsV4 {
  public static let featureID = HIDPPFeatureID.reprogrammableControlsV4
  public static let sensePanelControlID: UInt16 = 0x01A0

  public static func getCountRequest(
    featureIndex: UInt8,
    deviceIndex: UInt8 = HIDPPPacket.directBluetoothDeviceIndex,
    softwareID: UInt8 = HIDPPPacket.defaultSoftwareID
  ) throws -> HIDPPPacket {
    try HIDPPPacket(
      deviceIndex: deviceIndex,
      featureIndex: featureIndex,
      functionID: 0x00,
      softwareID: softwareID
    )
  }

  public static func controlInfoRequest(
    featureIndex: UInt8,
    index: UInt8,
    deviceIndex: UInt8 = HIDPPPacket.directBluetoothDeviceIndex,
    softwareID: UInt8 = HIDPPPacket.defaultSoftwareID
  ) throws -> HIDPPPacket {
    try HIDPPPacket(
      deviceIndex: deviceIndex,
      featureIndex: featureIndex,
      functionID: 0x01,
      softwareID: softwareID,
      parameters: [index]
    )
  }

  public static func getReportingRequest(
    featureIndex: UInt8,
    controlID: UInt16,
    deviceIndex: UInt8 = HIDPPPacket.directBluetoothDeviceIndex,
    softwareID: UInt8 = HIDPPPacket.defaultSoftwareID
  ) throws -> HIDPPPacket {
    let bytes = controlID.bigEndianBytes
    return try HIDPPPacket(
      deviceIndex: deviceIndex,
      featureIndex: featureIndex,
      functionID: 0x02,
      softwareID: softwareID,
      parameters: [bytes.high, bytes.low, 0]
    )
  }

  public static func setReportingRequest(
    featureIndex: UInt8,
    controlID: UInt16,
    change: ControlReportingChange,
    deviceIndex: UInt8 = HIDPPPacket.directBluetoothDeviceIndex,
    softwareID: UInt8 = HIDPPPacket.defaultSoftwareID
  ) throws -> HIDPPPacket {
    let controlBytes = controlID.bigEndianBytes
    let remapBytes = (change.remappedTo ?? 0).bigEndianBytes
    var primaryFlags: UInt8 = 0
    var secondaryFlags: UInt8 = 0

    encode(change.diverted, valueBit: 0, validBit: 1, into: &primaryFlags)
    encode(
      change.persistentlyDiverted,
      valueBit: 2,
      validBit: 3,
      into: &primaryFlags
    )
    encode(change.rawXY, valueBit: 4, validBit: 5, into: &primaryFlags)
    encode(
      change.forceRawXY,
      valueBit: 6,
      validBit: 7,
      into: &primaryFlags
    )
    encode(
      change.analyticsKeyEvents,
      valueBit: 0,
      validBit: 1,
      into: &secondaryFlags
    )
    encode(
      change.rawWheel,
      valueBit: 2,
      validBit: 3,
      into: &secondaryFlags
    )

    return try HIDPPPacket(
      deviceIndex: deviceIndex,
      featureIndex: featureIndex,
      functionID: 0x03,
      softwareID: softwareID,
      parameters: [
        controlBytes.high,
        controlBytes.low,
        primaryFlags,
        remapBytes.high,
        remapBytes.low,
        secondaryFlags,
      ]
    )
  }

  public static func parseCount(from response: HIDPPPacket) throws -> UInt8 {
    try response.requireSuccess()
    return response.parameters[0]
  }

  public static func parseControlInfo(
    from response: HIDPPPacket,
    index: UInt8
  ) throws -> ReprogrammableControlInfo {
    try response.requireSuccess()
    let parameters = response.parameters
    let capabilities = UInt16(parameters[4]) | (UInt16(parameters[8]) << 8)
    return ReprogrammableControlInfo(
      index: index,
      controlID: UInt16(bigEndianHigh: parameters[0], low: parameters[1]),
      taskID: UInt16(bigEndianHigh: parameters[2], low: parameters[3]),
      capabilities: ReprogrammableControlCapabilities(
        rawValue: capabilities
      ),
      position: parameters[5],
      group: parameters[6],
      groupMask: parameters[7]
    )
  }

  public static func parseReportingState(
    from response: HIDPPPacket,
    expectedControlID: UInt16? = nil
  ) throws -> ControlReportingState {
    try response.requireSuccess()
    let parameters = response.parameters
    let controlID = UInt16(
      bigEndianHigh: parameters[0],
      low: parameters[1]
    )
    if let expectedControlID, controlID != expectedControlID {
      throw ReprogrammableControlsError.responseControlMismatch(
        expected: expectedControlID,
        actual: controlID
      )
    }
    let remap = UInt16(
      bigEndianHigh: parameters[3],
      low: parameters[4]
    )
    return ControlReportingState(
      controlID: controlID,
      diverted: parameters[2] & (1 << 0) != 0,
      persistentlyDiverted: parameters[2] & (1 << 2) != 0,
      rawXY: parameters[2] & (1 << 4) != 0,
      forceRawXY: parameters[2] & (1 << 6) != 0,
      remappedTo: remap == 0 ? nil : remap,
      analyticsKeyEvents: parameters[5] & (1 << 0) != 0,
      rawWheel: parameters[5] & (1 << 2) != 0
    )
  }

  /// Decodes only unsolicited events (software ID zero) from the selected
  /// feature/device. Command responses and unrelated reports return nil.
  public static func parseEvent(
    from packet: HIDPPPacket,
    featureIndex: UInt8,
    deviceIndex: UInt8 = HIDPPPacket.directBluetoothDeviceIndex
  ) -> ReprogrammableControlsEvent? {
    guard packet.deviceIndex == deviceIndex,
      packet.featureIndex == featureIndex,
      packet.softwareID == 0
    else {
      return nil
    }

    switch packet.functionID {
    case 0:
      var controlIDs: [UInt16] = []
      for offset in stride(from: 0, to: 8, by: 2) {
        let controlID = UInt16(
          bigEndianHigh: packet.parameters[offset],
          low: packet.parameters[offset + 1]
        )
        if controlID == 0 {
          break
        }
        controlIDs.append(controlID)
      }
      return .pressedControlIDs(controlIDs)

    case 1:
      let dx = Int16(
        bitPattern: UInt16(
          bigEndianHigh: packet.parameters[0],
          low: packet.parameters[1]
        ))
      let dy = Int16(
        bitPattern: UInt16(
          bigEndianHigh: packet.parameters[2],
          low: packet.parameters[3]
        ))
      return .rawXY(dx: dx, dy: dy)

    default:
      return nil
    }
  }

  private static func encode(
    _ value: Bool?,
    valueBit: UInt8,
    validBit: UInt8,
    into byte: inout UInt8
  ) {
    guard let value else { return }
    byte |= 1 << validBit
    if value {
      byte |= 1 << valueBit
    }
  }
}

public struct SensePanelDiversionSnapshot: Codable, Equatable, Sendable {
  public let deviceRegistryID: UInt64
  public let featureIndex: UInt8
  public let control: ReprogrammableControlInfo
  public let originalReporting: ControlReportingState

  public init(
    deviceRegistryID: UInt64,
    featureIndex: UInt8,
    control: ReprogrammableControlInfo,
    originalReporting: ControlReportingState
  ) {
    self.deviceRegistryID = deviceRegistryID
    self.featureIndex = featureIndex
    self.control = control
    self.originalReporting = originalReporting
  }

  /// IORegistry entry IDs are connection-instance identifiers. Once a durable
  /// journal has independently matched the same physical device, recovery can
  /// safely address that device through its current registry entry while
  /// retaining the exact reporting state captured before the crash.
  public func rebinding(
    toDeviceRegistryID deviceRegistryID: UInt64,
    featureIndex: UInt8,
    control: ReprogrammableControlInfo
  ) -> SensePanelDiversionSnapshot {
    SensePanelDiversionSnapshot(
      deviceRegistryID: deviceRegistryID,
      featureIndex: featureIndex,
      control: control,
      originalReporting: originalReporting
    )
  }
}

extension HIDPPDeviceSession {
  public func reprogrammableControlCount(
    featureIndex: UInt8,
    timeoutMilliseconds: Int32 = 1_000
  ) throws -> UInt8 {
    let request = try ReprogrammableControlsV4.getCountRequest(
      featureIndex: featureIndex
    )
    let response = try transact(
      request,
      timeoutMilliseconds: timeoutMilliseconds
    )
    return try ReprogrammableControlsV4.parseCount(from: response)
  }

  public func reprogrammableControlInfo(
    featureIndex: UInt8,
    index: UInt8,
    timeoutMilliseconds: Int32 = 1_000
  ) throws -> ReprogrammableControlInfo {
    let request = try ReprogrammableControlsV4.controlInfoRequest(
      featureIndex: featureIndex,
      index: index
    )
    let response = try transact(
      request,
      timeoutMilliseconds: timeoutMilliseconds
    )
    return try ReprogrammableControlsV4.parseControlInfo(
      from: response,
      index: index
    )
  }

  public func controlReportingState(
    featureIndex: UInt8,
    controlID: UInt16,
    timeoutMilliseconds: Int32 = 1_000
  ) throws -> ControlReportingState {
    let request = try ReprogrammableControlsV4.getReportingRequest(
      featureIndex: featureIndex,
      controlID: controlID
    )
    let response = try transact(
      request,
      timeoutMilliseconds: timeoutMilliseconds
    )
    return try ReprogrammableControlsV4.parseReportingState(
      from: response,
      expectedControlID: controlID
    )
  }

  /// Discovers, validates, and snapshots the MX Master 4 Sense Panel without
  /// changing firmware state. Daemons should persist this snapshot before
  /// calling `applyTemporarySensePanelDiversion`, which closes the crash
  /// window between mutation and recovery-journal creation.
  public func prepareTemporarySensePanelDiversion(
    timeoutMilliseconds: Int32 = 1_000
  ) throws -> SensePanelDiversionSnapshot {
    let feature = try HIDPPDiscovery.requireFeature(
      .reprogrammableControlsV4,
      on: self,
      timeoutMilliseconds: timeoutMilliseconds
    )
    let count = try reprogrammableControlCount(
      featureIndex: feature.runtimeIndex,
      timeoutMilliseconds: timeoutMilliseconds
    )

    var sensePanel: ReprogrammableControlInfo?
    for index in 0..<count {
      let control = try reprogrammableControlInfo(
        featureIndex: feature.runtimeIndex,
        index: index,
        timeoutMilliseconds: timeoutMilliseconds
      )
      if control.controlID == ReprogrammableControlsV4.sensePanelControlID {
        sensePanel = control
        break
      }
    }
    guard let sensePanel else {
      throw ReprogrammableControlsError.sensePanelNotAdvertised
    }
    guard sensePanel.capabilities.contains(.divertable) else {
      throw ReprogrammableControlsError.sensePanelNotDivertable(
        sensePanel.capabilities
      )
    }
    guard sensePanel.capabilities.contains(.rawXY) else {
      throw ReprogrammableControlsError.sensePanelDoesNotSupportRawXY(
        sensePanel.capabilities
      )
    }
    let original = try controlReportingState(
      featureIndex: feature.runtimeIndex,
      controlID: sensePanel.controlID,
      timeoutMilliseconds: timeoutMilliseconds
    )

    return SensePanelDiversionSnapshot(
      deviceRegistryID: device.registryID,
      featureIndex: feature.runtimeIndex,
      control: sensePanel,
      originalReporting: original
    )
  }

  /// Enables only volatile diversion and raw-XY reporting, then verifies the
  /// readback. The caller must have durably journaled `snapshot` first.
  public func applyTemporarySensePanelDiversion(
    _ snapshot: SensePanelDiversionSnapshot,
    verify: Bool = true,
    timeoutMilliseconds: Int32 = 1_000
  ) throws {
    guard snapshot.deviceRegistryID == device.registryID else {
      throw ReprogrammableControlsError.snapshotBelongsToAnotherDevice
    }
    let request = try ReprogrammableControlsV4.setReportingRequest(
      featureIndex: snapshot.featureIndex,
      controlID: snapshot.control.controlID,
      change: .temporaryRawXY(preserving: snapshot.originalReporting)
    )
    let response = try transact(
      request,
      timeoutMilliseconds: timeoutMilliseconds
    )
    try response.requireSuccess()

    if verify {
      let actual = try controlReportingState(
        featureIndex: snapshot.featureIndex,
        controlID: snapshot.control.controlID,
        timeoutMilliseconds: timeoutMilliseconds
      )
      guard actual.diverted,
        actual.rawXY,
        actual.forceRawXY == snapshot.originalReporting.forceRawXY,
        actual.persistentlyDiverted == snapshot.originalReporting.persistentlyDiverted,
        actual.remappedTo == snapshot.originalReporting.remappedTo,
        actual.analyticsKeyEvents == snapshot.originalReporting.analyticsKeyEvents,
        actual.rawWheel == snapshot.originalReporting.rawWheel
      else {
        throw ReprogrammableControlsError.diversionVerificationFailed(actual)
      }
    }
  }

  /// Convenience for callers that do not need crash recovery. Long-running
  /// daemons should use the split prepare/journal/apply sequence instead.
  public func beginTemporarySensePanelDiversion(
    timeoutMilliseconds: Int32 = 1_000
  ) throws -> SensePanelDiversionSnapshot {
    let snapshot = try prepareTemporarySensePanelDiversion(
      timeoutMilliseconds: timeoutMilliseconds
    )
    try applyTemporarySensePanelDiversion(
      snapshot,
      timeoutMilliseconds: timeoutMilliseconds
    )
    return snapshot
  }

  /// Restores the complete state captured before diversion, including an
  /// existing remap or persistent flags, and verifies the readback by default.
  public func restoreSensePanelDiversion(
    _ snapshot: SensePanelDiversionSnapshot,
    verify: Bool = true,
    timeoutMilliseconds: Int32 = 1_000
  ) throws {
    guard snapshot.deviceRegistryID == device.registryID else {
      throw ReprogrammableControlsError.snapshotBelongsToAnotherDevice
    }
    let request = try ReprogrammableControlsV4.setReportingRequest(
      featureIndex: snapshot.featureIndex,
      controlID: snapshot.control.controlID,
      change: .restoring(snapshot.originalReporting)
    )
    let response = try transact(
      request,
      timeoutMilliseconds: timeoutMilliseconds
    )
    try response.requireSuccess()

    if verify {
      let actual = try controlReportingState(
        featureIndex: snapshot.featureIndex,
        controlID: snapshot.control.controlID,
        timeoutMilliseconds: timeoutMilliseconds
      )
      guard actual == snapshot.originalReporting else {
        throw ReprogrammableControlsError.restoreVerificationFailed(
          expected: snapshot.originalReporting,
          actual: actual
        )
      }
    }
  }
}

extension UInt16 {
  fileprivate var bigEndianBytes: (high: UInt8, low: UInt8) {
    (UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF))
  }

  fileprivate init(bigEndianHigh high: UInt8, low: UInt8) {
    self = (UInt16(high) << 8) | UInt16(low)
  }
}
