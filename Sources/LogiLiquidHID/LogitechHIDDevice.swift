import CLogiLiquidHID
import CryptoKit
import Foundation

public struct LogitechHIDDevice: Codable, Equatable, Sendable {
  public static let logitechVendorID: UInt16 = 0x046D
  public static let mxMaster4ProductID: UInt16 = 0xB042

  public let registryID: UInt64
  public let vendorID: UInt16
  public let productID: UInt16
  public let versionNumber: Int32?
  public let locationID: UInt32?
  public let primaryUsagePage: UInt16?
  public let primaryUsage: UInt16?
  public let maxInputReportSize: Int32?
  public let maxOutputReportSize: Int32?
  public let product: String
  public let manufacturer: String?
  public let transport: String?
  public let serialNumberPresent: Bool
  /// A one-way, model-bound fingerprint used only to recognize the same
  /// physical device after macOS replaces its IORegistry entry. The underlying
  /// serial number is never exposed by the Swift API or written to disk.
  public let stableIdentity: String?
  public let hasVendorUsagePageFF43: Bool
  public let hasHIDPPLongReport11: Bool

  public var isMXMaster4DirectBluetooth: Bool {
    vendorID == Self.logitechVendorID && productID == Self.mxMaster4ProductID
      && transport == "Bluetooth Low Energy"
  }

  public var supportsHIDPPLongReports: Bool {
    hasVendorUsagePageFF43 && hasHIDPPLongReport11
      && (maxOutputReportSize ?? 0) >= HIDPPPacket.longReportLength
  }

  init(cValue: inout LLHDeviceInfo) {
    registryID = cValue.registry_id
    vendorID = UInt16(clamping: cValue.vendor_id)
    productID = UInt16(clamping: cValue.product_id)
    versionNumber = Self.optional(cValue.version_number)
    locationID = Self.optional(cValue.location_id).map(UInt32.init)
    primaryUsagePage = Self.optional(cValue.primary_usage_page).map(UInt16.init)
    primaryUsage = Self.optional(cValue.primary_usage).map(UInt16.init)
    maxInputReportSize = Self.optional(cValue.max_input_report_size)
    maxOutputReportSize = Self.optional(cValue.max_output_report_size)
    product = Self.cString(&cValue.product)
    manufacturer = Self.nonempty(Self.cString(&cValue.manufacturer))
    transport = Self.nonempty(Self.cString(&cValue.transport))
    let serialNumber = Self.nonempty(Self.cString(&cValue.serial_number))
    serialNumberPresent = serialNumber != nil
    stableIdentity = Self.stableIdentity(
      vendorID: vendorID,
      productID: productID,
      serialNumber: serialNumber,
      locationID: locationID
    )
    hasVendorUsagePageFF43 = cValue.has_vendor_usage_page_ff43
    hasHIDPPLongReport11 = cValue.has_hidpp_long_report_11
  }

  private static func optional(_ value: Int32) -> Int32? {
    value >= 0 ? value : nil
  }

  private static func nonempty(_ value: String) -> String? {
    value.isEmpty ? nil : value
  }

  private static func stableIdentity(
    vendorID: UInt16,
    productID: UInt16,
    serialNumber: String?,
    locationID: UInt32?
  ) -> String? {
    let material: String
    if let serialNumber {
      material = "serial\0\(vendorID)\0\(productID)\0\(serialNumber)"
    } else if let locationID {
      // BLE LocationID is derived from the paired physical endpoint on macOS.
      // It is a less portable fallback, but still distinguishes two same-model
      // mice and therefore fails closed if macOS cannot supply either value.
      material = "location\0\(vendorID)\0\(productID)\0\(locationID)"
    } else {
      return nil
    }

    let digest = SHA256.hash(data: Data(material.utf8))
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func cString<T>(_ value: inout T) -> String {
    withUnsafePointer(to: &value) { pointer in
      pointer.withMemoryRebound(
        to: CChar.self,
        capacity: MemoryLayout<T>.size
      ) { String(cString: $0) }
    }
  }
}

public enum LogitechHID {
  /// Enumerates already-paired Logitech IOHID interfaces. No output reports
  /// are sent, and no device is opened by this operation.
  public static func enumerateDevices() -> [LogitechHIDDevice] {
    let count = llh_copy_logitech_devices(nil, 0)
    guard count > 0 else { return [] }

    var rawDevices = Array(repeating: LLHDeviceInfo(), count: count)
    let copied = rawDevices.withUnsafeMutableBufferPointer { buffer in
      llh_copy_logitech_devices(buffer.baseAddress, buffer.count)
    }

    return rawDevices.prefix(min(copied, rawDevices.count)).map { raw in
      var mutableRaw = raw
      return LogitechHIDDevice(cValue: &mutableRaw)
    }.sorted { lhs, rhs in
      if lhs.product == rhs.product {
        return lhs.registryID < rhs.registryID
      }
      return lhs.product < rhs.product
    }
  }
}
