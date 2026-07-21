import Foundation
import LogiLiquidControl
import LogiLiquidCore
import LogiLiquidService

public struct MouseDaemonStatus: Codable, Equatable, Sendable {
  public let running: Bool
  public let deviceActive: Bool
  public let phase: RingInteractionPhase
  public let configuredActionCount: Int
  public let configurationPath: String
  public let lastDeviceFailure: String?

  public init(
    running: Bool,
    deviceActive: Bool,
    phase: RingInteractionPhase,
    configuredActionCount: Int,
    configurationPath: String,
    lastDeviceFailure: String? = nil
  ) {
    self.running = running
    self.deviceActive = deviceActive
    self.phase = phase
    self.configuredActionCount = configuredActionCount
    self.configurationPath = configurationPath
    self.lastDeviceFailure = lastDeviceFailure
  }
}

public final class MouseDaemonCoordinator: @unchecked Sendable {
  private enum SleepDomain {
    case screens
    case system
  }

  public static let defaultLatchedDwell: TimeInterval =
    RingInteractionTiming.latchedSuctionDuration

  private struct PutActionParameters: Codable {
    let name: String
    let action: ConfiguredAction
    let zone: CardinalZone?
    let applicationBundleID: String?
  }

  private struct RemoveActionParameters: Codable {
    let name: String
    let zone: CardinalZone?
    let applicationBundleID: String?
  }

  private struct ClearActionsParameters: Codable {
    let zone: CardinalZone
    let applicationBundleID: String
  }

  private struct MoveActionParameters: Codable {
    let name: String
    let index: Int
    let zone: CardinalZone?
    let applicationBundleID: String?
  }

  private struct ResolveActionsParameters: Codable {
    let bundleID: String?
  }

  private struct HapticParameters: Codable {
    let waveformID: UInt8
  }

  private struct InvokeParameters: Codable {
    let origin: Vector2
    let bundleID: String?
  }

  private struct MoveParameters: Codable {
    let delta: Vector2
  }

  private struct PlayParameters: Codable {
    let inputs: [RingInput]
  }

  public let configurationRepository: any MouseDaemonConfigurationRepository
  public let runtime: MouseRuntime
  public let hidBackend: any MouseDaemonHIDBackend
  public let primaryClickMonitor: any MouseDaemonPrimaryClickMonitoring
  public let pointerMotionMonitor: any MouseDaemonPointerMotionMonitoring
  public let eventHub: MouseDaemonEventHub

  private let accessibilityTrusted: @Sendable () -> Bool
  private let frontmostApplicationProvider: any FrontmostApplicationProviding
  private let terminalDeviceFailureHandler: @Sendable (String) -> Void
  private let wakeHealthProbeSuccessHandler: @Sendable (UInt64) -> Void
  private let latchedCompletionScheduler: any MouseDaemonLatchedCompletionScheduling
  private let latchedDwell: TimeInterval
  private let sensePanelPressDebounceInterval: TimeInterval
  private let uptimeProvider: @Sendable () -> TimeInterval
  private let interactionLock = NSRecursiveLock()
  private let lifecycleLock = NSLock()
  private let configurationMutationLock = NSLock()
  private var running = false
  private var screenSleeping = false
  private var systemSleeping = false
  private var reportedTerminalDeviceFailure = false
  private var sensePanelPressed = false
  private var suppressNextSensePanelRelease = false
  private var lastAcceptedSensePanelPressUptime: TimeInterval?
  private var completionGeneration: UInt64 = 0
  private var scheduledCompletionGeneration: UInt64?

  public init(
    configurationRepository: any MouseDaemonConfigurationRepository,
    runtime: MouseRuntime,
    hidBackend: any MouseDaemonHIDBackend,
    primaryClickMonitor: any MouseDaemonPrimaryClickMonitoring =
      NoopPrimaryClickMonitor(),
    pointerMotionMonitor: any MouseDaemonPointerMotionMonitoring =
      NoopPointerMotionMonitor(),
    eventHub: MouseDaemonEventHub,
    frontmostApplicationProvider: any FrontmostApplicationProviding =
      UnknownFrontmostApplicationProvider(),
    accessibilityTrusted: @escaping @Sendable () -> Bool = { true },
    terminalDeviceFailureHandler: @escaping @Sendable (String) -> Void = { _ in },
    wakeHealthProbeSuccessHandler: @escaping @Sendable (UInt64) -> Void = { _ in },
    latchedCompletionScheduler: any MouseDaemonLatchedCompletionScheduling =
      DispatchLatchedCompletionScheduler(),
    latchedDwell: TimeInterval = MouseDaemonCoordinator.defaultLatchedDwell,
    sensePanelPressDebounceInterval: TimeInterval = 0.15,
    uptimeProvider: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.configurationRepository = configurationRepository
    self.runtime = runtime
    self.hidBackend = hidBackend
    self.primaryClickMonitor = primaryClickMonitor
    self.pointerMotionMonitor = pointerMotionMonitor
    self.eventHub = eventHub
    self.frontmostApplicationProvider = frontmostApplicationProvider
    self.accessibilityTrusted = accessibilityTrusted
    self.terminalDeviceFailureHandler = terminalDeviceFailureHandler
    self.wakeHealthProbeSuccessHandler = wakeHealthProbeSuccessHandler
    self.latchedCompletionScheduler = latchedCompletionScheduler
    self.latchedDwell = latchedDwell
    self.sensePanelPressDebounceInterval = sensePanelPressDebounceInterval
    self.uptimeProvider = uptimeProvider
  }

  public var isRunning: Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return running
  }

  public func start() throws {
    lifecycleLock.lock()
    guard !running else {
      lifecycleLock.unlock()
      throw MouseDaemonError.alreadyRunning
    }
    reportedTerminalDeviceFailure = false
    screenSleeping = false
    systemSleeping = false
    sensePanelPressed = false
    suppressNextSensePanelRelease = false
    lastAcceptedSensePanelPressUptime = nil
    completionGeneration &+= 1
    scheduledCompletionGeneration = nil
    lifecycleLock.unlock()

    try configurationRepository.ensureExists()
    try primaryClickMonitor.start { [weak self] event in
      self?.receivePrimaryClick(event)
    }
    do {
      try pointerMotionMonitor.start { [weak self] event in
        self?.receivePointerMotion(event)
      }
    } catch {
      primaryClickMonitor.stop()
      throw error
    }
    do {
      try hidBackend.start { [weak self] event in
        self?.receive(event)
      }
    } catch {
      pointerMotionMonitor.stop()
      primaryClickMonitor.stop()
      throw error
    }

    lifecycleLock.lock()
    if !reportedTerminalDeviceFailure {
      running = true
    }
    lifecycleLock.unlock()
  }

  public func stop() throws {
    var firstError: (any Error)?
    interactionLock.lock()
    lifecycleLock.lock()
    running = false
    screenSleeping = false
    systemSleeping = false
    sensePanelPressed = false
    suppressNextSensePanelRelease = false
    lastAcceptedSensePanelPressUptime = nil
    lifecycleLock.unlock()
    invalidateScheduledCompletion()
    primaryClickMonitor.setTracking(false)
    pointerMotionMonitor.setTracking(false)
    do {
      try cancelActiveInteraction()
    } catch {
      firstError = error
    }
    interactionLock.unlock()
    primaryClickMonitor.stop()
    pointerMotionMonitor.stop()
    do {
      try hidBackend.stop()
    } catch {
      if firstError == nil {
        firstError = error
      }
    }
    if let firstError {
      throw firstError
    }
  }

  /// Ends the current interaction before the display disappears. The daemon
  /// owns this transition so cursor restoration cannot arrive late over IPC
  /// and cancel an interaction created after wake.
  public func prepareForSleep() {
    prepareForSystemSleep()
  }

  public func prepareForScreenSleep() {
    prepareForSleep(domain: .screens)
  }

  public func prepareForSystemSleep() {
    prepareForSleep(domain: .system)
  }

  private func prepareForSleep(domain: SleepDomain) {
    lifecycleLock.lock()
    let wasSleeping = sleeping
    switch domain {
    case .screens: screenSleeping = true
    case .system: systemSleeping = true
    }
    guard !wasSleeping else {
      lifecycleLock.unlock()
      return
    }
    sensePanelPressed = false
    suppressNextSensePanelRelease = false
    lastAcceptedSensePanelPressUptime = nil
    lifecycleLock.unlock()
    hidBackend.suspendInputForSleep()

    interactionLock.lock()
    defer { interactionLock.unlock() }
    DaemonLog.log("sleep notification received; ending the active interaction")
    invalidateScheduledCompletion()
    primaryClickMonitor.setTracking(false)
    pointerMotionMonitor.setTracking(false)
    do {
      try cancelActiveInteraction()
    } catch {
      DaemonLog.log("failed to cancel the active interaction before sleep: \(error)")
    }
  }

  /// Re-enables physical input and asks the active HID session to verify its
  /// volatile diversion immediately. Reconnect retries are handled separately
  /// by the supervisor gate.
  public func resumeAfterWake(generation: UInt64) {
    interactionLock.lock()
    defer { interactionLock.unlock() }
    lifecycleLock.lock()
    systemSleeping = false
    // A full system wake supersedes display sleep bookkeeping from the prior
    // power cycle. Waiting for a second notification here can permanently
    // suppress input on clamshell, dark-wake, and changing-display paths.
    screenSleeping = false
    lastAcceptedSensePanelPressUptime = nil
    lifecycleLock.unlock()
    DaemonLog.log("wake notification received; accepting input immediately")
    hidBackend.requestHealthProbe(generation: generation)
  }

  /// Display-only wake re-enables the input edge state immediately without a
  /// Bluetooth/HID health probe. If the whole system is still asleep, its wake
  /// notification owns the eventual resumption instead.
  public func resumeAfterScreenWake() {
    interactionLock.lock()
    defer { interactionLock.unlock() }
    lifecycleLock.lock()
    let wasSleeping = sleeping
    screenSleeping = false
    let shouldResume = wasSleeping && !sleeping
    if shouldResume {
      lastAcceptedSensePanelPressUptime = nil
    }
    lifecycleLock.unlock()
    guard shouldResume else { return }
    DaemonLog.log("display wake notification received; accepting input immediately")
    hidBackend.resumeInputAfterSleep()
  }

  /// Synchronous by design so it plugs directly into `UnixControlServer`'s
  /// serialized handler. Actor work is bridged onto Swift concurrency without
  /// blocking the main thread or the HID transaction lane.
  public func handle(_ request: ControlRequest) throws -> JSONValue {
    do {
      switch request.method {
      case .status:
        return try status()
      case .doctor:
        return try doctor()
      case .deviceInspect:
        return try MouseDaemonJSON.encode(hidBackend.inspect())
      case .eventsFollow:
        return .object(["stream": .string(ControlStream.events.rawValue)])
      case .reportsFollow:
        return .object(["stream": .string(ControlStream.reports.rawValue)])
      case .actionsList:
        return try MouseDaemonJSON.encode(configurationRepository.load())
      case .actionsResolve:
        let parameters = try decode(ResolveActionsParameters.self, request.params)
        let context = try resolvedApplicationContext(
          explicitBundleID: parameters.bundleID
        )
        return try MouseDaemonJSON.encode(
          configurationRepository.load().resolved(for: context)
        )
      case .actionsPut:
        let parameters = try decode(PutActionParameters.self, request.params)
        return try mutateConfiguration { configuration in
          try configuration.putAction(
            named: parameters.name,
            action: parameters.action,
            zone: parameters.zone ?? .top,
            whenApplication: parameters.applicationBundleID
          )
        }
      case .actionsRemove:
        let parameters = try decode(RemoveActionParameters.self, request.params)
        return try mutateConfiguration { configuration in
          if parameters.zone != nil || parameters.applicationBundleID != nil {
            guard let zone = parameters.zone,
              let applicationBundleID = parameters.applicationBundleID
            else {
              throw MouseDaemonError.invalidParameter(
                "Scoped action removal requires both zone and applicationBundleID."
              )
            }
            try configuration.removeActionPlacement(
              named: parameters.name,
              from: zone,
              whenApplication: applicationBundleID
            )
          } else {
            configuration.removeAction(named: parameters.name)
          }
        }
      case .actionsClear:
        let parameters = try decode(ClearActionsParameters.self, request.params)
        return try mutateConfiguration { configuration in
          guard parameters.zone == .bottom else {
            throw
              ConfigurationMutationError
              .applicationSpecificActionsRequireBottomZone(parameters.zone)
          }
          try configuration.clearApplicationOverride(
            for: parameters.applicationBundleID
          )
        }
      case .actionsMove:
        let parameters = try decode(MoveActionParameters.self, request.params)
        return try mutateConfiguration { configuration in
          if parameters.zone != nil || parameters.applicationBundleID != nil {
            try configuration.moveAction(
              named: parameters.name,
              in: parameters.zone ?? .bottom,
              to: parameters.index,
              whenApplication: parameters.applicationBundleID
            )
          } else {
            try configuration.moveAction(
              named: parameters.name,
              to: parameters.index
            )
          }
        }
      case .hapticPlay:
        let parameters = try decode(HapticParameters.self, request.params)
        try hidBackend.playHaptic(waveformID: parameters.waveformID)
        return .object([
          "played": .bool(true),
          "waveformID": .integer(Int64(parameters.waveformID)),
        ])
      case .simulateInvoke:
        let parameters = try decode(InvokeParameters.self, request.params)
        let context = try resolvedApplicationContext(
          explicitBundleID: parameters.bundleID
        )
        return try MouseDaemonJSON.encode(
          simulationTransition { [runtime] in
            try await runtime.simulate(
              .panelTrigger(
                origin: parameters.origin,
                frontmostApplication: context
              )
            )
          }
        )
      case .simulateMove:
        let parameters = try decode(MoveParameters.self, request.params)
        return try MouseDaemonJSON.encode(
          simulationTransition { [runtime] in
            try await runtime.simulate(.pointerDelta(parameters.delta))
          }
        )
      case .simulateRelease:
        return try MouseDaemonJSON.encode(
          simulationTransition { [runtime] in
            try await runtime.simulate(.panelRelease)
          }
        )
      case .simulateClick:
        return try MouseDaemonJSON.encode(
          simulationTransition { [runtime] in
            try await runtime.simulate(.primaryClick)
          }
        )
      case .simulateComplete:
        return try MouseDaemonJSON.encode(
          simulationTransition { [runtime] in
            try await runtime.simulate(.completeCommit)
          }
        )
      case .simulateDismiss:
        return try MouseDaemonJSON.encode(
          simulationTransition { [runtime] in
            try await runtime.simulate(.dismiss)
          }
        )
      case .simulateCancel:
        return try MouseDaemonJSON.encode(
          simulationTransition { [runtime] in
            try await runtime.simulate(.cancel)
          }
        )
      case .simulatePlay:
        let parameters = try decode(PlayParameters.self, request.params)
        guard !parameters.inputs.isEmpty else {
          throw MouseDaemonError.invalidParameter(
            "simulate.play requires at least one input."
          )
        }
        var transitions: [RingTransition] = []
        transitions.reserveCapacity(parameters.inputs.count)
        for input in parameters.inputs {
          transitions.append(
            try simulationTransition { [runtime] in
              try await runtime.simulate(input)
            }
          )
        }
        return try MouseDaemonJSON.encode(transitions)
      }
    } catch let failure as ControlRequestFailure {
      throw failure
    } catch is DecodingError {
      throw ControlRequestFailure(
        code: "invalid_params",
        message: "Request parameters do not match \(request.method.rawValue)."
      )
    } catch let error as MouseDaemonError {
      let code: String
      switch error {
      case .invalidParameter:
        code = "invalid_params"
      default:
        code = "device_error"
      }
      throw ControlRequestFailure(
        code: code,
        message: error.localizedDescription
      )
    } catch let error as ConfigurationError {
      throw ControlRequestFailure(
        code: "config_error",
        message: error.localizedDescription
      )
    } catch let error as ConfigurationMutationError {
      throw ControlRequestFailure(
        code: "config_error",
        message: error.localizedDescription
      )
    } catch let error as MouseRuntimeError {
      throw ControlRequestFailure(
        code: "runtime_error",
        message: String(describing: error)
      )
    } catch {
      throw ControlRequestFailure(
        code: "daemon_error",
        message: error.localizedDescription
      )
    }
  }

  private func status() throws -> JSONValue {
    let configuration = try configurationRepository.load()
    let phase = try waitForActor { [runtime] in
      await runtime.currentPhase()
    }
    return try MouseDaemonJSON.encode(
      MouseDaemonStatus(
        running: isRunning,
        deviceActive: hidBackend.isActive,
        phase: phase,
        configuredActionCount: configuration.actions.count,
        configurationPath: configurationRepository.url.path,
        lastDeviceFailure: hidBackend.lastFailureDescription
      )
    )
  }

  private func resolvedApplicationContext(
    explicitBundleID: String?
  ) throws -> FrontmostApplicationContext {
    if let explicitBundleID {
      return FrontmostApplicationContext(bundleID: explicitBundleID)
    }
    return try frontmostApplicationProvider.currentApplication()
  }

  private func simulationTransition(
    _ operation: @escaping @Sendable () async throws -> RingTransition
  ) throws -> RingTransition {
    interactionLock.lock()
    defer { interactionLock.unlock() }
    guard isAcceptingInput else { throw MouseDaemonError.notRunning }
    let transition: RingTransition
    do {
      transition = try waitForActor(operation)
    } catch {
      try? cancelActiveInteraction()
      throw error
    }
    if transition.frame.phase != .invoked && transition.frame.phase != .tracking {
      primaryClickMonitor.setTracking(false)
      pointerMotionMonitor.setTracking(false)
    }
    if transition.frame.phase != .invoked && transition.frame.phase != .tracking
      && transition.frame.phase != .latched
    {
      invalidateScheduledCompletion()
    }
    if transition.frame.phase == .latched {
      scheduleLatchedCompletion()
    }
    return transition
  }

  private func doctor() throws -> JSONValue {
    var checks: [MouseDaemonDoctorCheck] = []
    do {
      let configuration = try configurationRepository.load()
      checks.append(
        MouseDaemonDoctorCheck(
          name: "configuration",
          ok: true,
          message: "Configuration is readable and valid."
        )
      )
      let needsAccessibility = configuration.actions.values.contains { action in
        if case .shortcut = action { return true }
        return false
      }
      let hasRequiredAccessibility = !needsAccessibility || accessibilityTrusted()
      checks.append(
        MouseDaemonDoctorCheck(
          name: "permission.accessibility",
          ok: hasRequiredAccessibility,
          message: hasRequiredAccessibility
            ? "Accessibility permission is sufficient for configured actions."
            : "Accessibility permission is required by configured shortcut actions."
        )
      )
    } catch {
      checks.append(
        MouseDaemonDoctorCheck(
          name: "configuration",
          ok: false,
          message: error.localizedDescription
        )
      )
    }

    do {
      checks.append(contentsOf: try hidBackend.inspect().doctorChecks())
    } catch {
      checks.append(
        MouseDaemonDoctorCheck(
          name: "device.connection",
          ok: false,
          message: error.localizedDescription
        )
      )
    }
    return try MouseDaemonJSON.encode(MouseDaemonDoctorReport(checks: checks))
  }

  private func mutateConfiguration(
    _ mutation: (inout MouseConfiguration) throws -> Void
  ) throws -> JSONValue {
    configurationMutationLock.lock()
    defer { configurationMutationLock.unlock() }

    var configuration = try configurationRepository.load()
    try mutation(&configuration)
    try configurationRepository.save(configuration)
    return try MouseDaemonJSON.encode(configuration)
  }

  private func decode<T: Decodable>(
    _ type: T.Type,
    _ params: JSONValue
  ) throws -> T {
    try MouseDaemonJSON.decode(type, from: params)
  }

  private func receive(_ event: MouseDaemonHIDEvent) {
    interactionLock.lock()
    defer { interactionLock.unlock() }
    do {
      switch event {
      case .rawReport(let packet):
        eventHub.publish(
          stream: .reports,
          event: "hid.report",
          payload: .object([
            "bytes": .array(packet.bytes.map { .integer(Int64($0)) }),
            "hex": .string(packet.hex),
          ])
        )

      case .sensePanelPressed:
        guard updateSensePanelState(pressed: true) else { return }
        pointerMotionMonitor.setTracking(false)
        eventHub.publish(
          stream: .events,
          event: "hid.sense-panel.pressed"
        )
        let transition = try waitForActor { [runtime] in
          try await runtime.invoke()
        }
        reconcilePhysicalTransition(
          transition,
          allowSystemPointerTracking: false
        )

      case .sensePanelReleased:
        guard updateSensePanelState(pressed: false) else { return }
        eventHub.publish(
          stream: .events,
          event: "hid.sense-panel.released"
        )
        let transition = try waitForActor { [runtime] in
          try await runtime.handlePanelRelease()
        }
        reconcilePhysicalTransition(
          transition,
          allowSystemPointerTracking: true
        )

      case .pointerDelta(let delta):
        guard isSensePanelCurrentlyPressed() else { return }
        let phase = try waitForActor { [runtime] in
          await runtime.currentPhase()
        }
        guard phase == .invoked || phase == .tracking else { return }
        let transition = try waitForActor { [runtime] in
          try await runtime.handlePointerDelta(delta)
        }
        reconcilePhysicalTransition(
          transition,
          allowSystemPointerTracking: false
        )

      case .wakeHealthProbeSucceeded(let generation):
        wakeHealthProbeSuccessHandler(generation)

      case .terminated(let message):
        receiveTerminalDeviceFailure(message)
        return
      }
    } catch {
      invalidateScheduledCompletion()
      primaryClickMonitor.setTracking(false)
      pointerMotionMonitor.setTracking(false)
      try? cancelActiveInteraction()
      eventHub.publish(
        stream: .events,
        event: "daemon.input-error",
        payload: .object(["message": .string(error.localizedDescription)])
      )
    }
  }

  private func receiveTerminalDeviceFailure(_ message: String) {
    lifecycleLock.lock()
    running = false
    sensePanelPressed = false
    suppressNextSensePanelRelease = false
    lastAcceptedSensePanelPressUptime = nil
    completionGeneration &+= 1
    scheduledCompletionGeneration = nil
    let shouldReport = !reportedTerminalDeviceFailure
    reportedTerminalDeviceFailure = true
    lifecycleLock.unlock()

    primaryClickMonitor.setTracking(false)
    pointerMotionMonitor.setTracking(false)
    do {
      try cancelActiveInteraction()
    } catch {
      try? waitForActor { [runtime] in
        try await runtime.restoreCursorIfNeeded()
      }
      eventHub.publish(
        stream: .events,
        event: "daemon.input-error",
        payload: .object(["message": .string(error.localizedDescription)])
      )
    }
    eventHub.publish(
      stream: .events,
      event: "daemon.device-error",
      payload: .object(["message": .string(message)])
    )
    if shouldReport {
      terminalDeviceFailureHandler(message)
    }
  }

  private func updateSensePanelState(pressed: Bool) -> Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard running else { return false }

    if pressed {
      guard !sleeping else { return false }
      guard !sensePanelPressed else { return false }
      let now = uptimeProvider()
      if let lastAcceptedSensePanelPressUptime,
        now - lastAcceptedSensePanelPressUptime < sensePanelPressDebounceInterval
      {
        suppressNextSensePanelRelease = true
        return false
      }
      sensePanelPressed = true
      suppressNextSensePanelRelease = false
      lastAcceptedSensePanelPressUptime = now
      return true
    }

    if suppressNextSensePanelRelease {
      suppressNextSensePanelRelease = false
      return false
    }
    guard sensePanelPressed else { return false }
    sensePanelPressed = false
    return true
  }

  private func receivePrimaryClick(_ event: MouseDaemonPrimaryClickEvent) {
    interactionLock.lock()
    defer { interactionLock.unlock() }
    guard isAcceptingInput else { return }
    do {
      switch event {
      case .primaryClick:
        let phase = try waitForActor { [runtime] in
          await runtime.currentPhase()
        }
        guard phase == .invoked || phase == .tracking else { return }
        let transition = try waitForActor { [runtime] in
          try await runtime.handlePrimaryClick()
        }
        reconcilePhysicalTransition(
          transition,
          allowSystemPointerTracking: !isSensePanelCurrentlyPressed()
        )

      case .terminated(let message):
        invalidateScheduledCompletion()
        primaryClickMonitor.setTracking(false)
        pointerMotionMonitor.setTracking(false)
        try cancelActiveInteraction()
        eventHub.publish(
          stream: .events,
          event: "daemon.primary-click-error",
          payload: .object(["message": .string(message)])
        )
      }
    } catch {
      invalidateScheduledCompletion()
      primaryClickMonitor.setTracking(false)
      pointerMotionMonitor.setTracking(false)
      try? cancelActiveInteraction()
      eventHub.publish(
        stream: .events,
        event: "daemon.input-error",
        payload: .object(["message": .string(error.localizedDescription)])
      )
    }
  }

  private func receivePointerMotion(_ event: MouseDaemonPointerMotionEvent) {
    interactionLock.lock()
    defer { interactionLock.unlock() }
    guard isAcceptingInput else { return }
    do {
      switch event {
      case .pointerDelta(let delta):
        guard !isSensePanelCurrentlyPressed() else { return }
        let phase = try waitForActor { [runtime] in
          await runtime.currentPhase()
        }
        guard phase == .invoked || phase == .tracking else { return }
        let transition = try waitForActor { [runtime] in
          try await runtime.handlePointerDelta(delta)
        }
        reconcilePhysicalTransition(
          transition,
          allowSystemPointerTracking: true
        )

      case .terminated(let message):
        invalidateScheduledCompletion()
        primaryClickMonitor.setTracking(false)
        pointerMotionMonitor.setTracking(false)
        try cancelActiveInteraction()
        eventHub.publish(
          stream: .events,
          event: "daemon.pointer-error",
          payload: .object(["message": .string(message)])
        )
      }
    } catch {
      invalidateScheduledCompletion()
      primaryClickMonitor.setTracking(false)
      pointerMotionMonitor.setTracking(false)
      try? cancelActiveInteraction()
      eventHub.publish(
        stream: .events,
        event: "daemon.input-error",
        payload: .object(["message": .string(error.localizedDescription)])
      )
    }
  }

  private func isSensePanelCurrentlyPressed() -> Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return sensePanelPressed
  }

  private var isAcceptingInput: Bool {
    lifecycleLock.withLock { running && !sleeping }
  }

  private var sleeping: Bool {
    screenSleeping || systemSleeping
  }

  private func reconcilePhysicalTransition(
    _ transition: RingTransition,
    allowSystemPointerTracking: Bool
  ) {
    let acceptsPointer =
      transition.frame.phase == .invoked || transition.frame.phase == .tracking
    primaryClickMonitor.setTracking(acceptsPointer)
    pointerMotionMonitor.setTracking(
      acceptsPointer && allowSystemPointerTracking
    )
    if transition.frame.phase == .latched {
      scheduleLatchedCompletion()
    }
  }

  private func scheduleLatchedCompletion() {
    lifecycleLock.lock()
    guard running, scheduledCompletionGeneration == nil else {
      lifecycleLock.unlock()
      return
    }
    let generation = completionGeneration
    scheduledCompletionGeneration = generation
    lifecycleLock.unlock()

    latchedCompletionScheduler.schedule(after: max(latchedDwell, 0)) { [weak self] in
      self?.completeLatchedInteraction(generation: generation)
    }
  }

  private func completeLatchedInteraction(generation: UInt64) {
    interactionLock.lock()
    defer { interactionLock.unlock() }
    lifecycleLock.lock()
    guard running, scheduledCompletionGeneration == generation,
      completionGeneration == generation
    else {
      lifecycleLock.unlock()
      return
    }
    scheduledCompletionGeneration = nil
    lifecycleLock.unlock()

    do {
      let _: RingTransition? = try waitForActor { [runtime] in
        guard await runtime.currentPhase() == .latched else { return nil }
        return try await runtime.completeCommit()
      }
    } catch {
      try? waitForActor { [runtime] in
        try await runtime.restoreCursorIfNeeded()
      }
      eventHub.publish(
        stream: .events,
        event: "daemon.input-error",
        payload: .object(["message": .string(error.localizedDescription)])
      )
    }
  }

  private func invalidateScheduledCompletion() {
    lifecycleLock.lock()
    completionGeneration &+= 1
    scheduledCompletionGeneration = nil
    lifecycleLock.unlock()
  }

  private func cancelActiveInteraction() throws {
    var firstError: (any Error)?
    let phase = try waitForActor { [runtime] in
      await runtime.currentPhase()
    }
    if phase == .invoked || phase == .tracking || phase == .latched {
      do {
        _ = try waitForActor { [runtime] in
          try await runtime.cancel()
        }
      } catch {
        firstError = error
      }
    }
    do {
      try waitForActor { [runtime] in
        try await runtime.restoreCursorIfNeeded()
      }
    } catch {
      if firstError == nil {
        firstError = error
      }
    }
    if let firstError {
      throw firstError
    }
  }
}

private final class BlockingActorResult<Value>: @unchecked Sendable {
  private let condition = NSCondition()
  private var result: Result<Value, any Error>?

  func resolve(_ result: Result<Value, any Error>) {
    condition.lock()
    self.result = result
    condition.broadcast()
    condition.unlock()
  }

  func wait() throws -> Value {
    condition.lock()
    while result == nil {
      condition.wait()
    }
    let resolved = result!
    condition.unlock()
    return try resolved.get()
  }
}

private func waitForActor<Value: Sendable>(
  _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
  let box = BlockingActorResult<Value>()
  Task.detached {
    do {
      box.resolve(.success(try await operation()))
    } catch {
      box.resolve(.failure(error))
    }
  }
  return try box.wait()
}
