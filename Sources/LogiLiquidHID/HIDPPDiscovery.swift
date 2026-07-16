import Foundation

public struct HIDPPFeatureID: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: UInt16

  public init(rawValue: UInt16) {
    self.rawValue = rawValue
  }

  public static let featureSet = Self(rawValue: 0x0001)
  public static let deviceInformation = Self(rawValue: 0x0003)
  public static let deviceNameAndType = Self(rawValue: 0x0005)
  public static let unifiedBattery = Self(rawValue: 0x1004)
  public static let changeHost = Self(rawValue: 0x1814)
  public static let hostsInformation = Self(rawValue: 0x1815)
  public static let hapticFeedback = Self(rawValue: 0x19B0)
  public static let forceSensingButton = Self(rawValue: 0x19C0)
  public static let reprogrammableControlsV4 = Self(rawValue: 0x1B04)
  public static let smartShiftEnhanced = Self(rawValue: 0x2111)
  public static let highResolutionWheelEnhanced = Self(rawValue: 0x2121)
  public static let thumbWheel = Self(rawValue: 0x2150)
  public static let adjustableDPI = Self(rawValue: 0x2201)
}

public struct HIDPPFeatureDescriptor: Codable, Equatable, Sendable {
  public let id: HIDPPFeatureID
  public let runtimeIndex: UInt8
  public let featureType: UInt8
  public let version: UInt8

  public init(
    id: HIDPPFeatureID,
    runtimeIndex: UInt8,
    featureType: UInt8,
    version: UInt8
  ) {
    self.id = id
    self.runtimeIndex = runtimeIndex
    self.featureType = featureType
    self.version = version
  }
}

public struct HIDPPProtocolVersion: Codable, Equatable, Sendable {
  public let major: UInt8
  public let minor: UInt8
  public let pingEcho: UInt8
  public let pingEchoMatched: Bool
}

public struct HIDPPDiscoveryResult: Codable, Equatable, Sendable {
  public let protocolVersion: HIDPPProtocolVersion
  public let features: [HIDPPFeatureDescriptor]

  public var featuresByID: [HIDPPFeatureID: HIDPPFeatureDescriptor] {
    Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
  }
}

public enum HIDPPDiscoveryError: Error, Equatable, CustomStringConvertible, Sendable {
  case malformedProtocolVersion
  case protocolPingMismatch(expected: UInt8, actual: UInt8)
  case unavailableFeature(HIDPPFeatureID)

  public var description: String {
    switch self {
    case .malformedProtocolVersion:
      "device returned a malformed HID++ protocol version"
    case .protocolPingMismatch(let expected, let actual):
      String(
        format: "HID++ protocol ping mismatch: expected 0x%02X, got 0x%02X",
        expected,
        actual
      )
    case .unavailableFeature(let featureID):
      String(format: "HID++ feature 0x%04X is unavailable", featureID.rawValue)
    }
  }
}

public enum HIDPPDiscovery {
  public static let defaultFeatureCatalog: [HIDPPFeatureID] = [
    .featureSet,
    .deviceInformation,
    .deviceNameAndType,
    .unifiedBattery,
    .changeHost,
    .hostsInformation,
    .hapticFeedback,
    .forceSensingButton,
    .reprogrammableControlsV4,
    .smartShiftEnhanced,
    .highResolutionWheelEnhanced,
    .thumbWheel,
    .adjustableDPI,
  ]

  /// Performs only IRoot reads: protocol ping and getFeature lookups.
  public static func readOnlyDiscover(
    on session: HIDPPDeviceSession,
    featureCatalog: [HIDPPFeatureID] = defaultFeatureCatalog,
    timeoutMilliseconds: Int32 = 1_000
  ) throws -> HIDPPDiscoveryResult {
    let ping = (UInt8(0x52), UInt8(0x4D), UInt8(0x50))
    let protocolRequest = try HIDPPPacket.rootProtocolVersion(ping: ping)
    let protocolResponse = try session.transact(
      protocolRequest,
      timeoutMilliseconds: timeoutMilliseconds
    )
    try protocolResponse.requireSuccess()
    let version = HIDPPProtocolVersion(
      major: protocolResponse.parameters[0],
      minor: protocolResponse.parameters[1],
      pingEcho: protocolResponse.parameters[2],
      pingEchoMatched: protocolResponse.parameters[2] == ping.2
    )
    guard version.pingEchoMatched else {
      throw HIDPPDiscoveryError.protocolPingMismatch(
        expected: ping.2,
        actual: version.pingEcho
      )
    }

    var features: [HIDPPFeatureDescriptor] = []
    for featureID in featureCatalog {
      if let feature = try feature(
        featureID,
        on: session,
        timeoutMilliseconds: timeoutMilliseconds
      ) {
        features.append(feature)
      }
    }
    return HIDPPDiscoveryResult(
      protocolVersion: version,
      features: features
    )
  }

  /// Looks up one feature through IRoot/getFeature. This is read-only.
  public static func feature(
    _ featureID: HIDPPFeatureID,
    on session: HIDPPDeviceSession,
    timeoutMilliseconds: Int32 = 1_000
  ) throws -> HIDPPFeatureDescriptor? {
    let request = try HIDPPPacket.rootFeature(featureID.rawValue)
    let response = try session.transact(
      request,
      timeoutMilliseconds: timeoutMilliseconds
    )
    try response.requireSuccess()
    guard response.parameters[0] != 0 else {
      return nil
    }
    return HIDPPFeatureDescriptor(
      id: featureID,
      runtimeIndex: response.parameters[0],
      featureType: response.parameters[1],
      version: response.parameters[2]
    )
  }

  public static func requireFeature(
    _ featureID: HIDPPFeatureID,
    on session: HIDPPDeviceSession,
    timeoutMilliseconds: Int32 = 1_000
  ) throws -> HIDPPFeatureDescriptor {
    guard
      let descriptor = try feature(
        featureID,
        on: session,
        timeoutMilliseconds: timeoutMilliseconds
      )
    else {
      throw HIDPPDiscoveryError.unavailableFeature(featureID)
    }
    return descriptor
  }
}
