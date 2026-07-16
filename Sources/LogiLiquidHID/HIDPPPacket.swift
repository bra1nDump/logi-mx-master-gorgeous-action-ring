import Foundation

public enum HIDPPPacketError: Error, Equatable, CustomStringConvertible, Sendable {
  case invalidLength(Int)
  case invalidReportID(UInt8)
  case parametersTooLong(Int)
  case nibbleOutOfRange(name: String, value: UInt8)
  case deviceError(code: UInt8, featureIndex: UInt8, functionSoftwareByte: UInt8)

  public var description: String {
    switch self {
    case .invalidLength(let length):
      "HID++ long reports must be 20 bytes, got \(length)"
    case .invalidReportID(let reportID):
      String(format: "expected HID++ long report ID 0x11, got 0x%02X", reportID)
    case .parametersTooLong(let count):
      "HID++ long reports hold at most 16 parameter bytes, got \(count)"
    case .nibbleOutOfRange(let name, let value):
      String(format: "%@ must fit in four bits, got 0x%02X", name, value)
    case .deviceError(let code, let featureIndex, let functionSoftwareByte):
      String(
        format: "HID++ error 0x%02X for feature 0x%02X, function/software 0x%02X",
        code,
        featureIndex,
        functionSoftwareByte
      )
    }
  }
}

/// One HID++ 2.0 long report. Direct-Bluetooth Logitech devices use report ID
/// `0x11`, device index `0xFF`, and 16 parameter bytes.
public struct HIDPPPacket: Equatable, Sendable, Codable {
  public static let longReportID: UInt8 = 0x11
  public static let longReportLength = 20
  public static let parameterCapacity = 16
  public static let directBluetoothDeviceIndex: UInt8 = 0xFF
  public static let defaultSoftwareID: UInt8 = 0x0A

  public let reportID: UInt8
  public let deviceIndex: UInt8
  public let featureIndex: UInt8
  public let functionID: UInt8
  public let softwareID: UInt8
  public let parameters: [UInt8]

  public init(
    deviceIndex: UInt8 = Self.directBluetoothDeviceIndex,
    featureIndex: UInt8,
    functionID: UInt8,
    softwareID: UInt8 = Self.defaultSoftwareID,
    parameters: [UInt8] = []
  ) throws {
    guard functionID <= 0x0F else {
      throw HIDPPPacketError.nibbleOutOfRange(
        name: "functionID",
        value: functionID
      )
    }
    guard softwareID <= 0x0F else {
      throw HIDPPPacketError.nibbleOutOfRange(
        name: "softwareID",
        value: softwareID
      )
    }
    guard parameters.count <= Self.parameterCapacity else {
      throw HIDPPPacketError.parametersTooLong(parameters.count)
    }

    reportID = Self.longReportID
    self.deviceIndex = deviceIndex
    self.featureIndex = featureIndex
    self.functionID = functionID
    self.softwareID = softwareID
    self.parameters =
      parameters
      + Array(
        repeating: 0,
        count: Self.parameterCapacity - parameters.count
      )
  }

  public init(bytes: [UInt8]) throws {
    guard bytes.count == Self.longReportLength else {
      throw HIDPPPacketError.invalidLength(bytes.count)
    }
    guard bytes[0] == Self.longReportID else {
      throw HIDPPPacketError.invalidReportID(bytes[0])
    }

    reportID = bytes[0]
    deviceIndex = bytes[1]
    featureIndex = bytes[2]
    functionID = bytes[3] >> 4
    softwareID = bytes[3] & 0x0F
    parameters = Array(bytes[4...19])
  }

  public var bytes: [UInt8] {
    [
      reportID,
      deviceIndex,
      featureIndex,
      (functionID << 4) | softwareID,
    ] + parameters
  }

  public var hex: String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
  }

  public var isErrorResponse: Bool {
    featureIndex == 0xFF
  }

  /// In a HID++ error report, parameter byte zero echoes the original
  /// function/software byte and parameter byte one contains the error code.
  public var deviceError: HIDPPPacketError? {
    guard isErrorResponse else { return nil }
    return .deviceError(
      code: parameters[1],
      featureIndex: (functionID << 4) | softwareID,
      functionSoftwareByte: parameters[0]
    )
  }

  public func requireSuccess() throws {
    if let deviceError {
      throw deviceError
    }
  }

  public static func rootProtocolVersion(
    deviceIndex: UInt8 = directBluetoothDeviceIndex,
    softwareID: UInt8 = defaultSoftwareID,
    ping: (UInt8, UInt8, UInt8) = (0x52, 0x4D, 0x50)
  ) throws -> HIDPPPacket {
    try HIDPPPacket(
      deviceIndex: deviceIndex,
      featureIndex: 0x00,
      functionID: 0x01,
      softwareID: softwareID,
      parameters: [ping.0, ping.1, ping.2]
    )
  }

  public static func rootFeature(
    _ featureID: UInt16,
    deviceIndex: UInt8 = directBluetoothDeviceIndex,
    softwareID: UInt8 = defaultSoftwareID
  ) throws -> HIDPPPacket {
    try HIDPPPacket(
      deviceIndex: deviceIndex,
      featureIndex: 0x00,
      functionID: 0x00,
      softwareID: softwareID,
      parameters: [
        UInt8((featureID >> 8) & 0xFF),
        UInt8(featureID & 0xFF),
        0x00,
      ]
    )
  }
}
