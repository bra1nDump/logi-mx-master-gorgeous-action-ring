import CLogiLiquidHID
import Foundation

public enum HIDPPTransportError: Error, Equatable, CustomStringConvertible, Sendable {
  case openFailed(String)
  case closed
  case transactionFailed(String)
  case eventReadFailed(String)
  case malformedResponse(String)

  public var description: String {
    switch self {
    case .openFailed(let message): "could not open HID++ device: \(message)"
    case .closed: "HID++ device session is closed"
    case .transactionFailed(let message): "HID++ transaction failed: \(message)"
    case .eventReadFailed(let message): "HID++ event read failed: \(message)"
    case .malformedResponse(let message): "malformed HID++ response: \(message)"
    }
  }
}

extension HIDPPTransportError: LocalizedError {
  public var errorDescription: String? { description }
}

/// A persistent, non-exclusive IOHID device connection. The C transport owns a
/// single serialized transaction lane and retains unmatched input reports for
/// the event consumer, so command responses cannot eat Sense Panel events.
public final class HIDPPDeviceSession: @unchecked Sendable {
  public let device: LogitechHIDDevice

  private let lifecycle = NSCondition()
  private var rawSession: OpaquePointer?
  private var activeOperations = 0
  private var isClosing = false

  public init(device: LogitechHIDDevice) throws {
    self.device = device
    var openedSession: OpaquePointer?
    var errorBuffer = Array(repeating: CChar(0), count: 512)
    let status = errorBuffer.withUnsafeMutableBufferPointer { errorPointer in
      llh_session_open(
        device.registryID,
        &openedSession,
        errorPointer.baseAddress,
        errorPointer.count
      )
    }
    guard status == 0, let openedSession else {
      throw HIDPPTransportError.openFailed(Self.message(from: errorBuffer))
    }
    rawSession = openedSession
  }

  deinit {
    close()
  }

  public var isConnected: Bool {
    lifecycle.lock()
    guard let rawSession, !isClosing else {
      lifecycle.unlock()
      return false
    }
    let result = llh_session_is_connected(rawSession)
    lifecycle.unlock()
    return result
  }

  public var droppedEventReportCount: UInt64 {
    lifecycle.lock()
    guard let rawSession, !isClosing else {
      lifecycle.unlock()
      return 0
    }
    let result = llh_session_dropped_report_count(rawSession)
    lifecycle.unlock()
    return result
  }

  public func close() {
    lifecycle.lock()
    guard rawSession != nil, !isClosing else {
      lifecycle.unlock()
      return
    }
    isClosing = true
    while activeOperations > 0 {
      lifecycle.wait()
    }
    let session = rawSession
    rawSession = nil
    lifecycle.unlock()
    if let session {
      llh_session_close(session)
    }
  }

  @discardableResult
  public func transact(
    _ request: HIDPPPacket,
    timeoutMilliseconds: Int32 = 1_000
  ) throws -> HIDPPPacket {
    let rawSession = try beginOperation()
    defer { endOperation() }

    var response = Array(
      repeating: UInt8(0),
      count: Int(LLH_MAX_REPORT_CAPACITY)
    )
    var responseLength = 0
    var errorBuffer = Array(repeating: CChar(0), count: 512)
    let requestBytes = request.bytes

    let status = requestBytes.withUnsafeBufferPointer { requestPointer in
      response.withUnsafeMutableBufferPointer { responsePointer in
        errorBuffer.withUnsafeMutableBufferPointer { errorPointer in
          llh_session_transact(
            rawSession,
            requestPointer.baseAddress,
            requestPointer.count,
            responsePointer.baseAddress,
            responsePointer.count,
            &responseLength,
            timeoutMilliseconds,
            errorPointer.baseAddress,
            errorPointer.count
          )
        }
      }
    }
    guard status == 0 else {
      throw HIDPPTransportError.transactionFailed(
        Self.message(from: errorBuffer)
      )
    }
    guard responseLength == HIDPPPacket.longReportLength else {
      throw HIDPPTransportError.malformedResponse(
        "expected 20 bytes, got \(responseLength)"
      )
    }
    return try HIDPPPacket(bytes: Array(response.prefix(responseLength)))
  }

  /// Returns nil on timeout. This only consumes reports that did not match an
  /// in-flight command response.
  public func nextEventReport(
    timeoutMilliseconds: Int32 = 1_000
  ) throws -> HIDPPPacket? {
    let rawSession = try beginOperation()
    defer { endOperation() }

    let deadline = Date(
      timeIntervalSinceNow: Double(max(timeoutMilliseconds, 0)) / 1_000
    )
    var remainingMilliseconds = max(timeoutMilliseconds, 0)
    while true {
      var report = Array(
        repeating: UInt8(0),
        count: Int(LLH_MAX_REPORT_CAPACITY)
      )
      var reportLength = 0
      var errorBuffer = Array(repeating: CChar(0), count: 512)
      let status = report.withUnsafeMutableBufferPointer { reportPointer in
        errorBuffer.withUnsafeMutableBufferPointer { errorPointer in
          llh_session_next_report(
            rawSession,
            reportPointer.baseAddress,
            reportPointer.count,
            &reportLength,
            remainingMilliseconds,
            errorPointer.baseAddress,
            errorPointer.count
          )
        }
      }
      if status == 1 {
        return nil
      }
      guard status == 0 else {
        throw HIDPPTransportError.eventReadFailed(
          Self.message(from: errorBuffer)
        )
      }
      if reportLength == HIDPPPacket.longReportLength {
        return try HIDPPPacket(bytes: Array(report.prefix(reportLength)))
      }

      // MX Master 4 also emits HID++ short reports on the same FF43
      // interface. They are unrelated to the 20-byte feature events this
      // session consumes and must not terminate the long-lived daemon.
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { return nil }
      remainingMilliseconds = Int32(
        min(ceil(remaining * 1_000), Double(Int32.max))
      )
    }
  }

  private func beginOperation() throws -> OpaquePointer {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    guard let rawSession, !isClosing else {
      throw HIDPPTransportError.closed
    }
    activeOperations += 1
    return rawSession
  }

  private func endOperation() {
    lifecycle.lock()
    activeOperations -= 1
    if activeOperations == 0 {
      lifecycle.broadcast()
    }
    lifecycle.unlock()
  }

  private static func message(from buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
    let message = String(decoding: bytes, as: UTF8.self)
    return message.isEmpty ? "unknown transport error" : message
  }
}
