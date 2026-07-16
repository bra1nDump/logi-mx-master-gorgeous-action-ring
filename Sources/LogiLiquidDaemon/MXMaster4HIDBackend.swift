import Foundation
import LogiLiquidCore
import LogiLiquidHID

/// Narrow driver boundary used to prove lifecycle safety without a physical
/// device. The production implementation below delegates to one persistent
/// `HIDPPDeviceSession`.
public protocol MXMaster4HIDDriving: AnyObject, Sendable {
  var stableDeviceIdentity: String? { get }

  func inspect(diversionActive: Bool) throws -> MouseDeviceInspection
  func prepareDiversion() throws -> SensePanelDiversionSnapshot
  func applyDiversion(_ snapshot: SensePanelDiversionSnapshot) throws
  func restoreDiversion(_ snapshot: SensePanelDiversionSnapshot) throws
  func sensePanelReportingState(
    featureIndex: UInt8,
    controlID: UInt16
  ) throws -> ControlReportingState
  func nextReport(timeoutMilliseconds: Int32) throws -> HIDPPPacket?
  func playHaptic(waveformID: UInt8) throws
  func close()
}

public protocol MXMaster4HIDDriverFactory: Sendable {
  func makeDriver(
    matchingStableIdentity stableDeviceIdentity: String?
  ) throws -> any MXMaster4HIDDriving
}

public struct IOKitMXMaster4HIDDriverFactory: MXMaster4HIDDriverFactory, Sendable {
  public let selectedRegistryID: UInt64?

  public init(selectedRegistryID: UInt64? = nil) {
    self.selectedRegistryID = selectedRegistryID
  }

  public func makeDriver(
    matchingStableIdentity stableDeviceIdentity: String?
  ) throws -> any MXMaster4HIDDriving {
    let devices = LogitechHID.enumerateDevices().filter {
      $0.isMXMaster4DirectBluetooth && $0.supportsHIDPPLongReports
    }
    let device: LogitechHIDDevice
    if let selectedRegistryID {
      guard let selected = devices.first(where: { $0.registryID == selectedRegistryID }) else {
        throw MouseDaemonError.selectedDeviceUnavailable(selectedRegistryID)
      }
      if let stableDeviceIdentity,
        selected.stableIdentity != stableDeviceIdentity
      {
        throw MouseDaemonError.diversionRecoveryDeviceIdentityMismatch
      }
      device = selected
    } else if let stableDeviceIdentity {
      guard
        let matching = devices.first(where: {
          $0.stableIdentity == stableDeviceIdentity
        })
      else {
        throw MouseDaemonError.diversionRecoveryDeviceIdentityUnavailable
      }
      device = matching
    } else {
      guard let first = devices.first else {
        throw MouseDaemonError.noMXMaster4
      }
      device = first
    }
    return try IOKitMXMaster4HIDDriver(device: device)
  }
}

public final class IOKitMXMaster4HIDDriver: MXMaster4HIDDriving, @unchecked Sendable {
  private let session: HIDPPDeviceSession
  private let closeLock = NSLock()
  private var closed = false
  private var cachedHapticFeatureIndex: UInt8?

  public init(device: LogitechHIDDevice) throws {
    session = try HIDPPDeviceSession(device: device)
  }

  deinit {
    close()
  }

  public var stableDeviceIdentity: String? {
    session.device.stableIdentity
  }

  public func inspect(diversionActive: Bool) throws -> MouseDeviceInspection {
    let discovery = try HIDPPDiscovery.readOnlyDiscover(on: session)
    let reprogrammableFeature = discovery.featuresByID[.reprogrammableControlsV4]

    var sensePanel: ReprogrammableControlInfo?
    var reporting: ControlReportingState?
    if let feature = reprogrammableFeature {
      let count = try session.reprogrammableControlCount(
        featureIndex: feature.runtimeIndex
      )
      for index in 0..<count {
        let control = try session.reprogrammableControlInfo(
          featureIndex: feature.runtimeIndex,
          index: index
        )
        if control.controlID == ReprogrammableControlsV4.sensePanelControlID {
          sensePanel = control
          reporting = try session.controlReportingState(
            featureIndex: feature.runtimeIndex,
            controlID: control.controlID
          )
          break
        }
      }
    }

    if let haptic = discovery.featuresByID[.hapticFeedback] {
      closeLock.lock()
      cachedHapticFeatureIndex = haptic.runtimeIndex
      closeLock.unlock()
    }

    let device = session.device
    return MouseDeviceInspection(
      registryID: device.registryID,
      vendorID: device.vendorID,
      productID: device.productID,
      product: device.product,
      transport: device.transport,
      isMXMaster4DirectBluetooth: device.isMXMaster4DirectBluetooth,
      supportsHIDPPLongReports: device.supportsHIDPPLongReports,
      protocolMajor: discovery.protocolVersion.major,
      protocolMinor: discovery.protocolVersion.minor,
      pingEchoMatched: discovery.protocolVersion.pingEchoMatched,
      features: discovery.features.map {
        MouseHIDFeatureInspection(
          id: $0.id.rawValue,
          runtimeIndex: $0.runtimeIndex,
          version: $0.version
        )
      },
      sensePanelControl: sensePanel,
      sensePanelReporting: reporting,
      diversionActive: diversionActive
    )
  }

  public func prepareDiversion() throws -> SensePanelDiversionSnapshot {
    try session.prepareTemporarySensePanelDiversion()
  }

  public func applyDiversion(_ snapshot: SensePanelDiversionSnapshot) throws {
    try session.applyTemporarySensePanelDiversion(snapshot)
  }

  public func restoreDiversion(_ snapshot: SensePanelDiversionSnapshot) throws {
    try session.restoreSensePanelDiversion(snapshot)
  }

  public func sensePanelReportingState(
    featureIndex: UInt8,
    controlID: UInt16
  ) throws -> ControlReportingState {
    try session.controlReportingState(
      featureIndex: featureIndex,
      controlID: controlID
    )
  }

  public func nextReport(timeoutMilliseconds: Int32) throws -> HIDPPPacket? {
    try session.nextEventReport(timeoutMilliseconds: timeoutMilliseconds)
  }

  public func playHaptic(waveformID: UInt8) throws {
    let featureIndex: UInt8
    closeLock.lock()
    if let cachedHapticFeatureIndex {
      featureIndex = cachedHapticFeatureIndex
      closeLock.unlock()
    } else {
      closeLock.unlock()
      featureIndex = try HIDPPDiscovery.requireFeature(
        .hapticFeedback,
        on: session
      ).runtimeIndex
      closeLock.lock()
      cachedHapticFeatureIndex = featureIndex
      closeLock.unlock()
    }
    try session.playHapticWaveform(waveformID, featureIndex: featureIndex)
  }

  public func close() {
    closeLock.lock()
    guard !closed else {
      closeLock.unlock()
      return
    }
    closed = true
    closeLock.unlock()
    session.close()
  }
}

public final class MXMaster4HIDBackend: MouseDaemonHIDBackend, @unchecked Sendable {
  private final class ActiveContext: @unchecked Sendable {
    let driver: any MXMaster4HIDDriving
    let snapshot: SensePanelDiversionSnapshot
    let handler: @Sendable (MouseDaemonHIDEvent) -> Void
    var stopRequested = false
    var cleanupError: (any Error)?

    init(
      driver: any MXMaster4HIDDriving,
      snapshot: SensePanelDiversionSnapshot,
      handler: @escaping @Sendable (MouseDaemonHIDEvent) -> Void
    ) {
      self.driver = driver
      self.snapshot = snapshot
      self.handler = handler
    }
  }

  private let driverFactory: any MXMaster4HIDDriverFactory
  private let journal: SensePanelDiversionJournalStore
  private let eventPollMilliseconds: Int32
  private let healthProbeInterval: TimeInterval
  private let uptimeProvider: @Sendable () -> TimeInterval
  private let wallClockProvider: @Sendable () -> Date
  private let lifecycle = NSCondition()

  /// A wall-clock jump this much larger than the uptime delta means the
  /// machine slept; the device may have silently lost its diversion.
  private static let sleepJumpThreshold: TimeInterval = 5

  private var context: ActiveContext?
  private var starting = false
  public private(set) var lastFailureDescription: String?

  public convenience init(
    selectedRegistryID: UInt64? = nil,
    journalURL: URL,
    eventPollMilliseconds: Int32 = 100
  ) throws {
    try self.init(
      driverFactory: IOKitMXMaster4HIDDriverFactory(
        selectedRegistryID: selectedRegistryID
      ),
      journal: SensePanelDiversionJournalStore(url: journalURL),
      eventPollMilliseconds: eventPollMilliseconds
    )
  }

  public init(
    driverFactory: any MXMaster4HIDDriverFactory,
    journal: SensePanelDiversionJournalStore,
    eventPollMilliseconds: Int32 = 100,
    healthProbeInterval: TimeInterval = 30,
    uptimeProvider: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    },
    wallClockProvider: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    guard eventPollMilliseconds > 0 else {
      throw MouseDaemonError.invalidParameter(
        "The HID event poll interval must be positive."
      )
    }
    guard healthProbeInterval > 0 else {
      throw MouseDaemonError.invalidParameter(
        "The health probe interval must be positive."
      )
    }
    self.driverFactory = driverFactory
    self.journal = journal
    self.eventPollMilliseconds = eventPollMilliseconds
    self.healthProbeInterval = healthProbeInterval
    self.uptimeProvider = uptimeProvider
    self.wallClockProvider = wallClockProvider
  }

  public var isActive: Bool {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    return context != nil
  }

  public func start(
    eventHandler: @escaping @Sendable (MouseDaemonHIDEvent) -> Void
  ) throws {
    lifecycle.lock()
    guard context == nil, !starting else {
      lifecycle.unlock()
      throw MouseDaemonError.alreadyRunning
    }
    starting = true
    lastFailureDescription = nil
    lifecycle.unlock()

    let recoveryEntry: SensePanelDiversionJournalEntry?
    let driver: any MXMaster4HIDDriving
    do {
      recoveryEntry = try journal.loadEntry()
      driver = try driverFactory.makeDriver(
        matchingStableIdentity: recoveryEntry?.stableDeviceIdentity
      )
    } catch {
      finishStarting(with: error)
      throw error
    }

    do {
      let inspection = try driver.inspect(diversionActive: false)
      if let recoveryEntry {
        let recoverySnapshot: SensePanelDiversionSnapshot
        if let stableDeviceIdentity = recoveryEntry.stableDeviceIdentity {
          guard driver.stableDeviceIdentity == stableDeviceIdentity else {
            throw MouseDaemonError.diversionRecoveryDeviceIdentityMismatch
          }
          guard
            let reprogrammableFeature = inspection.features.first(where: {
              $0.id == HIDPPFeatureID.reprogrammableControlsV4.rawValue
            }),
            let sensePanelControl = inspection.sensePanelControl
          else {
            throw MouseDaemonError.restorationFailed(
              "The reconnected mouse no longer advertises its Sense Panel controls."
            )
          }
          recoverySnapshot = recoveryEntry.snapshot.rebinding(
            toDeviceRegistryID: inspection.registryID,
            featureIndex: reprogrammableFeature.runtimeIndex,
            control: sensePanelControl
          )
        } else {
          guard recoveryEntry.snapshot.deviceRegistryID == inspection.registryID else {
            throw MouseDaemonError.diversionRecoveryDeviceMismatch(
              expected: recoveryEntry.snapshot.deviceRegistryID,
              actual: inspection.registryID
            )
          }
          recoverySnapshot = recoveryEntry.snapshot
        }
        try driver.restoreDiversion(recoverySnapshot)
        try journal.remove()
      }

      let snapshot = try driver.prepareDiversion()
      try journal.save(
        snapshot,
        stableDeviceIdentity: driver.stableDeviceIdentity
      )
      do {
        try driver.applyDiversion(snapshot)
      } catch {
        try restoreAfterFailedApply(
          driver: driver,
          snapshot: snapshot,
          originalError: error
        )
      }

      let activeContext = ActiveContext(
        driver: driver,
        snapshot: snapshot,
        handler: eventHandler
      )
      lifecycle.lock()
      context = activeContext
      starting = false
      lifecycle.broadcast()
      lifecycle.unlock()

      Thread.detachNewThread { [self, activeContext] in
        runEventLoop(activeContext)
      }
    } catch {
      driver.close()
      finishStarting(with: error)
      throw error
    }
  }

  public func stop() throws {
    lifecycle.lock()
    while starting {
      lifecycle.wait()
    }
    guard let activeContext = context else {
      lifecycle.unlock()
      return
    }
    activeContext.stopRequested = true
    while context === activeContext {
      lifecycle.wait()
    }
    let cleanupError = activeContext.cleanupError
    lifecycle.unlock()

    if let cleanupError {
      throw MouseDaemonError.restorationFailed(cleanupError.localizedDescription)
    }
  }

  public func inspect() throws -> MouseDeviceInspection {
    lifecycle.lock()
    let activeContext = context
    lifecycle.unlock()
    if let activeContext {
      return try activeContext.driver.inspect(diversionActive: true)
    }

    let driver = try driverFactory.makeDriver(matchingStableIdentity: nil)
    defer { driver.close() }
    return try driver.inspect(diversionActive: false)
  }

  public func playHaptic(waveformID: UInt8) throws {
    lifecycle.lock()
    guard let activeContext = context, !activeContext.stopRequested else {
      lifecycle.unlock()
      throw MouseDaemonError.notRunning
    }
    let driver = activeContext.driver
    lifecycle.unlock()
    try driver.playHaptic(waveformID: waveformID)
  }

  private func runEventLoop(_ activeContext: ActiveContext) {
    var sensePanelPressed = false
    var discardNextSensePanelRawXY = false
    var terminalError: (any Error)?
    var lastUptime = uptimeProvider()
    var lastWallClock = wallClockProvider()
    var lastProbeUptime = lastUptime

    while shouldContinue(activeContext) {
      do {
        // The MX Master 4 can silently drop its volatile diversion — most
        // visibly across system sleep, when the ring stops appearing even
        // though the session still reads cleanly. Probe the reporting state
        // periodically, and immediately after a detected sleep, and re-apply
        // the diversion if the device lost it. A probe failure is a terminal
        // session error, which hands recovery to the supervisor.
        let uptime = uptimeProvider()
        let wallClock = wallClockProvider()
        let wallDelta = wallClock.timeIntervalSince(lastWallClock)
        let sleptSinceLastPoll =
          wallDelta - (uptime - lastUptime) > Self.sleepJumpThreshold
        lastUptime = uptime
        lastWallClock = wallClock
        if sleptSinceLastPoll || uptime - lastProbeUptime >= healthProbeInterval {
          lastProbeUptime = uptime
          if sleptSinceLastPoll {
            DaemonLog.log("system wake detected; verifying the Sense Panel diversion")
          }
          let reporting = try activeContext.driver.sensePanelReportingState(
            featureIndex: activeContext.snapshot.featureIndex,
            controlID: activeContext.snapshot.control.controlID
          )
          if !reporting.diverted || !reporting.rawXY {
            DaemonLog.log(
              "the device dropped its Sense Panel diversion; re-applying"
            )
            try activeContext.driver.applyDiversion(activeContext.snapshot)
            sensePanelPressed = false
            discardNextSensePanelRawXY = false
          }
        }

        guard
          let packet = try activeContext.driver.nextReport(
            timeoutMilliseconds: eventPollMilliseconds
          )
        else {
          continue
        }
        activeContext.handler(.rawReport(packet))

        guard
          let event = ReprogrammableControlsV4.parseEvent(
            from: packet,
            featureIndex: activeContext.snapshot.featureIndex
          )
        else {
          continue
        }
        switch event {
        case .pressedControlIDs(let controlIDs):
          let isPressed = controlIDs.contains(
            ReprogrammableControlsV4.sensePanelControlID
          )
          if isPressed != sensePanelPressed {
            sensePanelPressed = isPressed
            discardNextSensePanelRawXY = isPressed
            activeContext.handler(
              isPressed ? .sensePanelPressed : .sensePanelReleased
            )
          }
        case .rawXY(let dx, let dy):
          guard sensePanelPressed else { continue }
          // The device emits one stale, absolute-looking sample on each down
          // edge (observed as -3091, -7254). Arm on the edge and discard only
          // that first sample; duplicate pressed reports do not re-arm it.
          if discardNextSensePanelRawXY {
            discardNextSensePanelRawXY = false
            continue
          }
          activeContext.handler(
            .pointerDelta(Vector2(x: Double(dx), y: Double(dy)))
          )
        }
      } catch {
        terminalError = error
        activeContext.handler(.terminated(message: error.localizedDescription))
        break
      }
    }

    cleanup(activeContext, terminalError: terminalError)
  }

  private func cleanup(
    _ activeContext: ActiveContext,
    terminalError: (any Error)?
  ) {
    var cleanupError: (any Error)?
    do {
      try activeContext.driver.restoreDiversion(activeContext.snapshot)
      try journal.remove()
    } catch {
      cleanupError = error
    }
    activeContext.driver.close()

    lifecycle.lock()
    activeContext.cleanupError = cleanupError
    if context === activeContext {
      context = nil
    }
    if let cleanupError {
      lastFailureDescription = cleanupError.localizedDescription
    } else if let terminalError {
      lastFailureDescription = terminalError.localizedDescription
    }
    lifecycle.broadcast()
    lifecycle.unlock()
  }

  private func shouldContinue(_ activeContext: ActiveContext) -> Bool {
    lifecycle.lock()
    defer { lifecycle.unlock() }
    return context === activeContext && !activeContext.stopRequested
  }

  private func restoreAfterFailedApply(
    driver: any MXMaster4HIDDriving,
    snapshot: SensePanelDiversionSnapshot,
    originalError: any Error
  ) throws -> Never {
    do {
      try driver.restoreDiversion(snapshot)
      try journal.remove()
    } catch {
      throw MouseDaemonError.restorationFailed(
        "\(originalError.localizedDescription); recovery also failed: \(error.localizedDescription)"
      )
    }
    throw originalError
  }

  private func finishStarting(with error: any Error) {
    lifecycle.lock()
    starting = false
    lastFailureDescription = error.localizedDescription
    lifecycle.broadcast()
    lifecycle.unlock()
  }
}
