import AppKit
import Dispatch
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
  case wake(UInt64)
  case timeout
}

/// A resettable gate the supervisor blocks on between device sessions. A
/// process signal always wins over a device failure and is never cleared by
/// `reset`, so shutdown cannot be lost while a reconnect is in flight.
public final class DaemonSupervisorGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var signalled = false
  private var deviceFailure: String?
  private var wakeGeneration: UInt64 = 0
  private var pendingWakeGeneration: UInt64?
  private var retryWakeGeneration: UInt64?

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

  @discardableResult
  public func signalWake() -> UInt64 {
    condition.lock()
    wakeGeneration &+= 1
    let generation = wakeGeneration
    pendingWakeGeneration = generation
    retryWakeGeneration = generation
    condition.broadcast()
    condition.unlock()
    return generation
  }

  public func consumeWakeRetry() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let pending = retryWakeGeneration != nil
    retryWakeGeneration = nil
    return pending
  }

  public func clearWakeRetry(generation: UInt64) {
    condition.lock()
    if retryWakeGeneration == generation {
      retryWakeGeneration = nil
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
    while !signalled && deviceFailure == nil && pendingWakeGeneration == nil {
      if let deadline {
        guard condition.wait(until: deadline) else { return .timeout }
      } else {
        condition.wait()
      }
    }
    if signalled { return .signal }
    if let deviceFailure { return .deviceFailure(deviceFailure) }
    let generation = pendingWakeGeneration!
    pendingWakeGeneration = nil
    return .wake(generation)
  }
}

/// Delivers documented macOS sleep/wake notifications to the daemon. The
/// production monitor must be started on the AppKit main thread while its
/// application event loop is running; `NSWorkspace` does not feed a private
/// worker run loop in a command-line LaunchAgent.
public final class SystemPowerMonitor: @unchecked Sendable {
  private enum PowerDomain {
    case screens
    case system
  }

  private enum PowerState {
    case unknown
    case awake
    case sleeping
  }

  public static let defaultLifecycleTimeout: TimeInterval = 2

  private let notificationCenter: NotificationCenter
  private let screenSleepNotifications: [Notification.Name]
  private let systemSleepNotifications: [Notification.Name]
  private let screenWakeNotifications: [Notification.Name]
  private let systemWakeNotifications: [Notification.Name]
  private let onScreenSleep: @Sendable () -> Void
  private let onSystemSleep: @Sendable () -> Void
  private let onScreenWake: @Sendable () -> Void
  private let onSystemWake: @Sendable () -> Void
  private let condition = NSCondition()
  private let deliveryQueue: OperationQueue
  private let requiresMainThread: Bool

  private var running = false
  private var observerTokens: [NSObjectProtocol] = []
  private var screenPowerState = PowerState.unknown
  private var systemPowerState = PowerState.unknown

  public convenience init(
    onScreenSleep: @escaping @Sendable () -> Void,
    onSystemSleep: @escaping @Sendable () -> Void,
    onScreenWake: @escaping @Sendable () -> Void,
    onSystemWake: @escaping @Sendable () -> Void
  ) {
    self.init(
      notificationCenter: NSWorkspace.shared.notificationCenter,
      screenSleepNotifications: [NSWorkspace.screensDidSleepNotification],
      systemSleepNotifications: [NSWorkspace.willSleepNotification],
      screenWakeNotifications: [NSWorkspace.screensDidWakeNotification],
      systemWakeNotifications: [NSWorkspace.didWakeNotification],
      requiresMainThread: true,
      onScreenSleep: onScreenSleep,
      onSystemSleep: onSystemSleep,
      onScreenWake: onScreenWake,
      onSystemWake: onSystemWake
    )
  }

  convenience init(
    notificationCenter: NotificationCenter,
    sleepNotifications: [Notification.Name],
    wakeNotifications: [Notification.Name],
    requiresMainThread: Bool = false,
    onSleep: @escaping @Sendable () -> Void,
    onWake: @escaping @Sendable () -> Void
  ) {
    self.init(
      notificationCenter: notificationCenter,
      screenSleepNotifications: [],
      systemSleepNotifications: sleepNotifications,
      screenWakeNotifications: [],
      systemWakeNotifications: wakeNotifications,
      requiresMainThread: requiresMainThread,
      onScreenSleep: {},
      onSystemSleep: onSleep,
      onScreenWake: {},
      onSystemWake: onWake
    )
  }

  init(
    notificationCenter: NotificationCenter,
    screenSleepNotifications: [Notification.Name],
    systemSleepNotifications: [Notification.Name],
    screenWakeNotifications: [Notification.Name],
    systemWakeNotifications: [Notification.Name],
    requiresMainThread: Bool = false,
    onScreenSleep: @escaping @Sendable () -> Void,
    onSystemSleep: @escaping @Sendable () -> Void,
    onScreenWake: @escaping @Sendable () -> Void,
    onSystemWake: @escaping @Sendable () -> Void
  ) {
    self.notificationCenter = notificationCenter
    self.screenSleepNotifications = screenSleepNotifications
    self.systemSleepNotifications = systemSleepNotifications
    self.screenWakeNotifications = screenWakeNotifications
    self.systemWakeNotifications = systemWakeNotifications
    self.requiresMainThread = requiresMainThread
    self.onScreenSleep = onScreenSleep
    self.onSystemSleep = onSystemSleep
    self.onScreenWake = onScreenWake
    self.onSystemWake = onSystemWake
    let deliveryQueue = OperationQueue()
    deliveryQueue.name = "com.logiliquid.controls.daemon.power-events"
    deliveryQueue.maxConcurrentOperationCount = 1
    deliveryQueue.qualityOfService = .userInteractive
    self.deliveryQueue = deliveryQueue
  }

  deinit {
    condition.lock()
    running = false
    let tokens = observerTokens
    observerTokens = []
    condition.unlock()
    for token in tokens {
      notificationCenter.removeObserver(token)
    }
  }

  @discardableResult
  public func start() -> Bool {
    precondition(
      !requiresMainThread || Thread.isMainThread,
      "The NSWorkspace power monitor must start on the AppKit main thread."
    )
    condition.lock()
    guard !running else {
      condition.unlock()
      return true
    }
    running = true
    screenPowerState = .unknown
    systemPowerState = .unknown
    observerTokens =
      screenSleepNotifications.map { notification in
        notificationCenter.addObserver(
          forName: notification,
          object: nil,
          queue: nil
        ) { [weak self] _ in
          self?.enqueueSleep(for: .screens)
        }
      }
      + systemSleepNotifications.map { notification in
        notificationCenter.addObserver(
          forName: notification,
          object: nil,
          queue: nil
        ) { [weak self] _ in
          self?.enqueueSleep(for: .system)
        }
      }
      + screenWakeNotifications.map { notification in
        notificationCenter.addObserver(
          forName: notification,
          object: nil,
          queue: nil
        ) { [weak self] _ in
          self?.enqueueWake(for: .screens)
        }
      }
      + systemWakeNotifications.map { notification in
        notificationCenter.addObserver(
          forName: notification,
          object: nil,
          queue: nil
        ) { [weak self] _ in
          self?.enqueueWake(for: .system)
        }
      }
    condition.unlock()
    return true
  }

  /// Stops accepting notifications and waits only long enough for callbacks
  /// already owned by the serial delivery queue. A sleep callback may itself be
  /// suspended by macOS; that must not turn SIGTERM into an unbounded wait.
  @discardableResult
  public func stop(
    timeout: TimeInterval = SystemPowerMonitor.defaultLifecycleTimeout
  ) -> Bool {
    precondition(
      !requiresMainThread || Thread.isMainThread,
      "The NSWorkspace power monitor must stop on the AppKit main thread."
    )
    condition.lock()
    guard running || !observerTokens.isEmpty else {
      condition.unlock()
      return true
    }
    running = false
    let tokens = observerTokens
    observerTokens = []
    condition.unlock()

    for token in tokens {
      notificationCenter.removeObserver(token)
    }

    let drained = DispatchSemaphore(value: 0)
    deliveryQueue.addOperation {
      drained.signal()
    }
    return drained.wait(timeout: .now() + max(timeout, 0)) == .success
  }

  private func enqueueSleep(for domain: PowerDomain) {
    deliveryQueue.addOperation { [weak self] in
      self?.deliverSleep(for: domain)
    }
  }

  private func enqueueWake(for domain: PowerDomain) {
    deliveryQueue.addOperation { [weak self] in
      self?.deliverWake(for: domain)
    }
  }

  private func deliverSleep(for domain: PowerDomain) {
    condition.lock()
    guard running, powerState(for: domain) != .sleeping else {
      condition.unlock()
      return
    }
    setPowerState(.sleeping, for: domain)
    condition.unlock()
    switch domain {
    case .screens: onScreenSleep()
    case .system: onSystemSleep()
    }
  }

  private func deliverWake(for domain: PowerDomain) {
    condition.lock()
    guard running, powerState(for: domain) != .awake else {
      condition.unlock()
      return
    }
    setPowerState(.awake, for: domain)
    condition.unlock()
    switch domain {
    case .screens: onScreenWake()
    case .system: onSystemWake()
    }
  }

  private func setPowerState(_ state: PowerState, for domain: PowerDomain) {
    switch domain {
    case .screens: screenPowerState = state
    case .system: systemPowerState = state
    }
  }

  private func powerState(for domain: PowerDomain) -> PowerState {
    switch domain {
    case .screens: screenPowerState
    case .system: systemPowerState
    }
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

  public mutating func next(afterWake: Bool) -> TimeInterval {
    afterWake ? 0 : next()
  }

  public mutating func reset() {
    current = initial
  }
}
