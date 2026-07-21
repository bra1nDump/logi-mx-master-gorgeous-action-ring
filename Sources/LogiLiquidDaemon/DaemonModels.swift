import Foundation
import LogiLiquidControl
import LogiLiquidCore
import LogiLiquidHID
import LogiLiquidService

public enum MouseDaemonJSON {
  public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  public static func decode<T: Decodable>(
    _ type: T.Type,
    from value: JSONValue
  ) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(type, from: data)
  }
}

public struct MouseDaemonDoctorCheck: Codable, Equatable, Sendable {
  public let name: String
  public let ok: Bool
  public let message: String

  public init(name: String, ok: Bool, message: String) {
    self.name = name
    self.ok = ok
    self.message = message
  }
}

public struct MouseDaemonDoctorReport: Codable, Equatable, Sendable {
  public let ok: Bool
  public let checks: [MouseDaemonDoctorCheck]

  public init(checks: [MouseDaemonDoctorCheck]) {
    self.ok = checks.allSatisfy(\.ok)
    self.checks = checks
  }
}

public struct MouseHIDFeatureInspection: Codable, Equatable, Sendable {
  public let id: UInt16
  public let runtimeIndex: UInt8
  public let version: UInt8

  public init(id: UInt16, runtimeIndex: UInt8, version: UInt8) {
    self.id = id
    self.runtimeIndex = runtimeIndex
    self.version = version
  }
}

/// Sanitized device metadata. It deliberately contains neither a Bluetooth
/// address nor a serial number.
public struct MouseDeviceInspection: Codable, Equatable, Sendable {
  public let registryID: UInt64
  public let vendorID: UInt16
  public let productID: UInt16
  public let product: String
  public let transport: String?
  public let isMXMaster4DirectBluetooth: Bool
  public let supportsHIDPPLongReports: Bool
  public let protocolMajor: UInt8
  public let protocolMinor: UInt8
  public let pingEchoMatched: Bool
  public let features: [MouseHIDFeatureInspection]
  public let sensePanelControl: ReprogrammableControlInfo?
  public let sensePanelReporting: ControlReportingState?
  public let diversionActive: Bool

  public init(
    registryID: UInt64,
    vendorID: UInt16,
    productID: UInt16,
    product: String,
    transport: String?,
    isMXMaster4DirectBluetooth: Bool,
    supportsHIDPPLongReports: Bool,
    protocolMajor: UInt8,
    protocolMinor: UInt8,
    pingEchoMatched: Bool,
    features: [MouseHIDFeatureInspection],
    sensePanelControl: ReprogrammableControlInfo?,
    sensePanelReporting: ControlReportingState?,
    diversionActive: Bool
  ) {
    self.registryID = registryID
    self.vendorID = vendorID
    self.productID = productID
    self.product = product
    self.transport = transport
    self.isMXMaster4DirectBluetooth = isMXMaster4DirectBluetooth
    self.supportsHIDPPLongReports = supportsHIDPPLongReports
    self.protocolMajor = protocolMajor
    self.protocolMinor = protocolMinor
    self.pingEchoMatched = pingEchoMatched
    self.features = features
    self.sensePanelControl = sensePanelControl
    self.sensePanelReporting = sensePanelReporting
    self.diversionActive = diversionActive
  }

  public func doctorChecks() -> [MouseDaemonDoctorCheck] {
    let featureIDs = Set(features.map(\.id))
    return [
      MouseDaemonDoctorCheck(
        name: "device.mx-master-4",
        ok: isMXMaster4DirectBluetooth,
        message: isMXMaster4DirectBluetooth
          ? "MX Master 4 is connected over Bluetooth Low Energy."
          : "The selected HID device is not an MX Master 4 Bluetooth interface."
      ),
      MouseDaemonDoctorCheck(
        name: "device.hidpp-long-report",
        ok: supportsHIDPPLongReports,
        message: supportsHIDPPLongReports
          ? "The FF43 HID++ 0x11 long-report interface is available."
          : "The selected interface cannot exchange HID++ 0x11 long reports."
      ),
      MouseDaemonDoctorCheck(
        name: "protocol.ping",
        ok: pingEchoMatched,
        message: pingEchoMatched
          ? "The HID++ protocol ping was echoed."
          : "The HID++ protocol ping did not match."
      ),
      MouseDaemonDoctorCheck(
        name: "feature.reprogrammable-controls",
        ok: featureIDs.contains(HIDPPFeatureID.reprogrammableControlsV4.rawValue),
        message: featureIDs.contains(HIDPPFeatureID.reprogrammableControlsV4.rawValue)
          ? "Reprogrammable Controls V4 is available."
          : "Reprogrammable Controls V4 (0x1B04) is unavailable."
      ),
      MouseDaemonDoctorCheck(
        name: "feature.haptic-feedback",
        ok: featureIDs.contains(HIDPPFeatureID.hapticFeedback.rawValue),
        message: featureIDs.contains(HIDPPFeatureID.hapticFeedback.rawValue)
          ? "Haptic Feedback is available."
          : "Haptic Feedback (0x19B0) is unavailable."
      ),
      MouseDaemonDoctorCheck(
        name: "control.sense-panel",
        ok: sensePanelControl?.controlID == ReprogrammableControlsV4.sensePanelControlID
          && sensePanelControl?.capabilities.contains(.divertable) == true
          && sensePanelControl?.capabilities.contains(.rawXY) == true,
        message: sensePanelControl?.controlID == ReprogrammableControlsV4.sensePanelControlID
          && sensePanelControl?.capabilities.contains(.divertable) == true
          && sensePanelControl?.capabilities.contains(.rawXY) == true
          ? "Sense Panel 0x01A0 supports temporary diversion and raw XY."
          : "Sense Panel 0x01A0 is unavailable or lacks required capabilities."
      ),
    ]
  }
}

public enum MouseDaemonHIDEvent: Sendable {
  case rawReport(HIDPPPacket)
  case sensePanelPressed
  case sensePanelReleased
  case pointerDelta(Vector2)
  case wakeHealthProbeSucceeded(generation: UInt64)
  case terminated(message: String)
}

public enum MouseDaemonPrimaryClickEvent: Sendable {
  case primaryClick
  case terminated(message: String)
}

public enum MouseDaemonPointerMotionEvent: Sendable {
  case pointerDelta(Vector2)
  case terminated(message: String)
}

/// Tracks primary-button down edges while a physical ring interaction is active.
/// Pointer movement has a separate source handoff, so this monitor never
/// observes or duplicates motion.
public protocol MouseDaemonPrimaryClickMonitoring: Sendable {
  func start(
    eventHandler: @escaping @Sendable (MouseDaemonPrimaryClickEvent) -> Void
  ) throws
  func setTracking(_ tracking: Bool)
  func stop()
}

/// Samples normal system-pointer movement only after the Sense Panel is
/// released. Raw HID++ XY owns movement while the panel remains pressed.
public protocol MouseDaemonPointerMotionMonitoring: Sendable {
  func start(
    eventHandler: @escaping @Sendable (MouseDaemonPointerMotionEvent) -> Void
  ) throws
  func setTracking(_ tracking: Bool)
  func stop()
}

public struct NoopPrimaryClickMonitor:
  MouseDaemonPrimaryClickMonitoring, Sendable
{
  public init() {}

  public func start(
    eventHandler _: @escaping @Sendable (MouseDaemonPrimaryClickEvent) -> Void
  ) throws {}

  public func setTracking(_: Bool) {}

  public func stop() {}
}

public struct NoopPointerMotionMonitor:
  MouseDaemonPointerMotionMonitoring, Sendable
{
  public init() {}

  public func start(
    eventHandler _: @escaping @Sendable (MouseDaemonPointerMotionEvent) -> Void
  ) throws {}

  public func setTracking(_: Bool) {}

  public func stop() {}
}

public protocol MouseDaemonLatchedCompletionScheduling: Sendable {
  func schedule(
    after delay: TimeInterval,
    operation: @escaping @Sendable () -> Void
  )
}

public struct DispatchLatchedCompletionScheduler:
  MouseDaemonLatchedCompletionScheduling, Sendable
{
  public init() {}

  public func schedule(
    after delay: TimeInterval,
    operation: @escaping @Sendable () -> Void
  ) {
    DispatchQueue.global(qos: .userInteractive).asyncAfter(
      deadline: .now() + delay,
      execute: operation
    )
  }
}

public protocol MouseDaemonHIDBackend: MouseHIDControlling {
  var isActive: Bool { get }
  var lastFailureDescription: String? { get }

  func start(
    eventHandler: @escaping @Sendable (MouseDaemonHIDEvent) -> Void
  ) throws
  func stop() throws
  func inspect() throws -> MouseDeviceInspection
  func suspendInputForSleep()
  func resumeInputAfterSleep()
  func requestHealthProbe(generation: UInt64)
}

public enum MouseDaemonError: Error, Equatable, Sendable {
  case alreadyRunning
  case notRunning
  case noMXMaster4
  case selectedDeviceUnavailable(UInt64)
  case unsafePath(String)
  case unsupportedJournalVersion(Int)
  case diversionRecoveryDeviceMismatch(expected: UInt64, actual: UInt64)
  case diversionRecoveryDeviceIdentityMismatch
  case diversionRecoveryDeviceIdentityUnavailable
  case restorationFailed(String)
  case invalidParameter(String)
}

extension MouseDaemonError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      "The mouse daemon is already running."
    case .notRunning:
      "The mouse daemon is not running."
    case .noMXMaster4:
      "No compatible MX Master 4 Bluetooth HID++ interface was found."
    case .selectedDeviceUnavailable(let registryID):
      "The selected MX Master 4 HID registry entry \(registryID) is unavailable."
    case .unsafePath(let path):
      "The daemon refused an unsafe private path: \(path)"
    case .unsupportedJournalVersion(let version):
      "Unsupported diversion recovery journal version \(version)."
    case .diversionRecoveryDeviceMismatch(let expected, let actual):
      "The recovery journal belongs to registry entry \(expected), not \(actual)."
    case .diversionRecoveryDeviceIdentityMismatch:
      "The recovery journal belongs to a different physical MX Master 4."
    case .diversionRecoveryDeviceIdentityUnavailable:
      "The physical MX Master 4 named by the recovery journal is not connected."
    case .restorationFailed(let message):
      "Sense Panel restoration failed: \(message)"
    case .invalidParameter(let message):
      message
    }
  }
}
