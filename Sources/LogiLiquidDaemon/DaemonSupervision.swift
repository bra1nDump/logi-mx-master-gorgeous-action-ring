import Foundation

/// Timestamped stderr logging for the daemon process. When the daemon runs as
/// the installed LaunchAgent, launchd redirects this stream to
/// `~/Library/Application Support/Logi Liquid Controls/logs/daemon.error.log`.
public enum DaemonLog {
  private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  public static func log(_ message: String) {
    let line = "\(Date().formatted(timestampStyle)) logi-liquid-daemon: \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}

/// The reason the supervisor loop woke up.
public enum DaemonSupervisorEvent: Equatable, Sendable {
  case signal
  case deviceFailure(String)
  case timeout
}

/// A resettable gate the supervisor blocks on between device sessions. A
/// process signal always wins over a device failure and is never cleared by
/// `reset`, so shutdown cannot be lost while a reconnect is in flight.
public final class DaemonSupervisorGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var signalled = false
  private var deviceFailure: String?

  public init() {}

  public func signalShutdown() {
    condition.lock()
    signalled = true
    condition.broadcast()
    condition.unlock()
  }

  public func signalDeviceFailure(_ message: String) {
    condition.lock()
    if deviceFailure == nil {
      deviceFailure = message
      condition.broadcast()
    }
    condition.unlock()
  }

  /// Clears a consumed device failure. A pending shutdown remains latched.
  public func reset() {
    condition.lock()
    deviceFailure = nil
    condition.unlock()
  }

  public func wait(timeout: TimeInterval? = nil) -> DaemonSupervisorEvent {
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    condition.lock()
    defer { condition.unlock() }
    while !signalled && deviceFailure == nil {
      if let deadline {
        guard condition.wait(until: deadline) else { return .timeout }
      } else {
        condition.wait()
      }
    }
    if signalled { return .signal }
    return .deviceFailure(deviceFailure!)
  }
}

extension MouseDaemonError {
  /// Failures that no amount of waiting for the device fixes: bad input, a
  /// different physical mouse than the recovery journal names, or unsafe
  /// filesystem state. Everything else — device absent, asleep, half-awake
  /// after a Bluetooth reconnect — is worth retrying in-process.
  public var preventsAutomaticDeviceRecovery: Bool {
    switch self {
    case .alreadyRunning,
      .invalidParameter,
      .unsafePath,
      .unsupportedJournalVersion,
      .selectedDeviceUnavailable,
      .diversionRecoveryDeviceMismatch,
      .diversionRecoveryDeviceIdentityMismatch:
      return true
    case .notRunning,
      .noMXMaster4,
      .diversionRecoveryDeviceIdentityUnavailable,
      .restorationFailed:
      return false
    }
  }
}

/// Retry pacing for device bring-up: quick first retries for the common
/// wake/reconnect case, capped so a persistent failure stays cheap.
public struct DaemonRetryBackoff: Equatable, Sendable {
  public private(set) var current: TimeInterval
  public let initial: TimeInterval
  public let maximum: TimeInterval

  public init(initial: TimeInterval = 1, maximum: TimeInterval = 10) {
    self.initial = initial
    self.maximum = maximum
    current = initial
  }

  public mutating func next() -> TimeInterval {
    let delay = current
    current = min(current * 2, maximum)
    return delay
  }

  public mutating func reset() {
    current = initial
  }
}
