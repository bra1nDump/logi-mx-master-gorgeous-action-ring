import Foundation
import LogiLiquidCore
import LogiLiquidDaemon
import LogiLiquidHID
import LogiLiquidService

final class TestConfigurationRepository:
  MouseDaemonConfigurationRepository, @unchecked Sendable
{
  let url = URL(fileURLWithPath: "/tmp/logi-liquid-in-memory-config.json")

  private let lock = NSLock()
  private var configuration: MouseConfiguration
  private(set) var ensureCallCount = 0

  init(configuration: MouseConfiguration = MouseConfiguration()) {
    self.configuration = configuration
  }

  func ensureExists() {
    lock.lock()
    ensureCallCount += 1
    lock.unlock()
  }

  func load() throws -> MouseConfiguration {
    lock.lock()
    defer { lock.unlock() }
    try configuration.validate()
    return configuration
  }

  func save(_ configuration: MouseConfiguration) throws {
    try configuration.validate()
    lock.lock()
    self.configuration = configuration
    lock.unlock()
  }
}

final class TestHIDBackend: MouseDaemonHIDBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (MouseDaemonHIDEvent) -> Void)?
  private var active = false
  private var storedHapticError: (any Error)?
  private(set) var hapticWaveforms: [UInt8] = []

  var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return active
  }

  var lastFailureDescription: String? { nil }

  var hapticError: (any Error)? {
    get { lock.withLock { storedHapticError } }
    set { lock.withLock { storedHapticError = newValue } }
  }

  func start(
    eventHandler: @escaping @Sendable (MouseDaemonHIDEvent) -> Void
  ) throws {
    lock.lock()
    active = true
    handler = eventHandler
    lock.unlock()
  }

  func stop() throws {
    lock.lock()
    active = false
    lock.unlock()
  }

  func inspect() throws -> MouseDeviceInspection {
    MouseDeviceInspection(
      registryID: 42,
      vendorID: LogitechHIDDevice.logitechVendorID,
      productID: LogitechHIDDevice.mxMaster4ProductID,
      product: "MX Master 4",
      transport: "Bluetooth Low Energy",
      isMXMaster4DirectBluetooth: true,
      supportsHIDPPLongReports: true,
      protocolMajor: 4,
      protocolMinor: 5,
      pingEchoMatched: true,
      features: [
        MouseHIDFeatureInspection(
          id: HIDPPFeatureID.reprogrammableControlsV4.rawValue,
          runtimeIndex: 0x0D,
          version: 4
        ),
        MouseHIDFeatureInspection(
          id: HIDPPFeatureID.hapticFeedback.rawValue,
          runtimeIndex: 0x0B,
          version: 1
        ),
      ],
      sensePanelControl: nil,
      sensePanelReporting: nil,
      diversionActive: isActive
    )
  }

  func playHaptic(waveformID: UInt8) throws {
    try lock.withLock {
      hapticWaveforms.append(waveformID)
      if let storedHapticError {
        throw storedHapticError
      }
    }
  }

  func emit(_ event: MouseDaemonHIDEvent) {
    lock.lock()
    let handler = handler
    lock.unlock()
    handler?(event)
  }
}

final class TestPrimaryClickMonitor:
  MouseDaemonPrimaryClickMonitoring, @unchecked Sendable
{
  private let lock = NSLock()
  private var handler: (@Sendable (MouseDaemonPrimaryClickEvent) -> Void)?
  private var storedTracking = false
  private(set) var startCallCount = 0
  private(set) var stopCallCount = 0

  var tracking: Bool {
    lock.withLock { storedTracking }
  }

  func start(
    eventHandler: @escaping @Sendable (MouseDaemonPrimaryClickEvent) -> Void
  ) throws {
    lock.withLock {
      startCallCount += 1
      handler = eventHandler
    }
  }

  func setTracking(_ tracking: Bool) {
    lock.withLock { storedTracking = tracking }
  }

  func stop() {
    lock.withLock {
      stopCallCount += 1
      storedTracking = false
    }
  }

  func emit(_ event: MouseDaemonPrimaryClickEvent) {
    let handler = lock.withLock { self.handler }
    handler?(event)
  }
}

final class TestPointerMotionMonitor:
  MouseDaemonPointerMotionMonitoring, @unchecked Sendable
{
  private let lock = NSLock()
  private var handler: (@Sendable (MouseDaemonPointerMotionEvent) -> Void)?
  private var storedTracking = false
  private(set) var startCallCount = 0
  private(set) var stopCallCount = 0

  var tracking: Bool {
    lock.withLock { storedTracking }
  }

  func start(
    eventHandler: @escaping @Sendable (MouseDaemonPointerMotionEvent) -> Void
  ) throws {
    lock.withLock {
      startCallCount += 1
      handler = eventHandler
    }
  }

  func setTracking(_ tracking: Bool) {
    lock.withLock { storedTracking = tracking }
  }

  func stop() {
    lock.withLock {
      stopCallCount += 1
      storedTracking = false
    }
  }

  func emit(_ event: MouseDaemonPointerMotionEvent) {
    let handler = lock.withLock { self.handler }
    handler?(event)
  }
}

final class TestLatchedCompletionScheduler:
  MouseDaemonLatchedCompletionScheduling, @unchecked Sendable
{
  private let lock = NSLock()
  private var operations: [@Sendable () -> Void] = []
  private var storedDelays: [TimeInterval] = []

  var delays: [TimeInterval] {
    lock.withLock { storedDelays }
  }

  var scheduledCount: Int {
    lock.withLock { operations.count }
  }

  func schedule(
    after delay: TimeInterval,
    operation: @escaping @Sendable () -> Void
  ) {
    lock.withLock {
      storedDelays.append(delay)
      operations.append(operation)
    }
  }

  func runNext() {
    let operation = lock.withLock {
      operations.isEmpty ? nil : operations.removeFirst()
    }
    operation?()
  }
}

struct FixedCursorProvider: CursorPositionProviding, Sendable {
  let position: Vector2

  func currentPosition() throws -> Vector2 {
    position
  }
}

final class RecordingActionExecutor: ActionExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ActionInvocation] = []

  var invocations: [ActionInvocation] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func execute(_ invocation: ActionInvocation) throws {
    lock.lock()
    storage.append(invocation)
    lock.unlock()
  }
}

final class RecordingCursorVisibilityController:
  CursorVisibilityControlling, @unchecked Sendable
{
  private let lock = NSLock()
  private var storage: [CursorVisibilityIntent] = []
  private var hidden = false

  var intents: [CursorVisibilityIntent] {
    lock.withLock { storage }
  }

  func hideCursor() throws {
    lock.withLock {
      guard !hidden else { return }
      hidden = true
      storage.append(.hide)
    }
  }

  func restoreCursor() throws {
    lock.withLock {
      guard hidden else { return }
      hidden = false
      storage.append(.restore)
    }
  }
}

final class PublishedEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [MouseDaemonPublishedEvent] = []

  var events: [MouseDaemonPublishedEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ event: MouseDaemonPublishedEvent) {
    lock.lock()
    storage.append(event)
    lock.unlock()
  }
}

func makeTestCoordinator(
  configuration: MouseConfiguration = MouseConfiguration(),
  cursorPosition: Vector2 = Vector2(x: 50, y: 60),
  terminalDeviceFailureHandler: @escaping @Sendable (String) -> Void = { _ in },
  latchedDwell: TimeInterval = MouseDaemonCoordinator.defaultLatchedDwell,
  sensePanelPressDebounceInterval: TimeInterval = 0,
  uptimeProvider: @escaping @Sendable () -> TimeInterval = {
    ProcessInfo.processInfo.systemUptime
  }
) -> (
  coordinator: MouseDaemonCoordinator,
  repository: TestConfigurationRepository,
  backend: TestHIDBackend,
  primaryClickMonitor: TestPrimaryClickMonitor,
  pointerMotionMonitor: TestPointerMotionMonitor,
  completionScheduler: TestLatchedCompletionScheduler,
  events: MouseDaemonEventHub,
  executor: RecordingActionExecutor,
  visibility: RecordingCursorVisibilityController
) {
  let repository = TestConfigurationRepository(configuration: configuration)
  let backend = TestHIDBackend()
  let primaryClickMonitor = TestPrimaryClickMonitor()
  let pointerMotionMonitor = TestPointerMotionMonitor()
  let completionScheduler = TestLatchedCompletionScheduler()
  let events = MouseDaemonEventHub()
  let executor = RecordingActionExecutor()
  let visibility = RecordingCursorVisibilityController()
  let runtime = MouseRuntime(
    configurationLoader: repository,
    hidController: backend,
    eventPublisher: events,
    cursorPositionProvider: FixedCursorProvider(position: cursorPosition),
    actionExecutor: executor,
    cursorVisibilityController: visibility,
    cursorRestorationDelay: 0
  )
  let coordinator = MouseDaemonCoordinator(
    configurationRepository: repository,
    runtime: runtime,
    hidBackend: backend,
    primaryClickMonitor: primaryClickMonitor,
    pointerMotionMonitor: pointerMotionMonitor,
    eventHub: events,
    terminalDeviceFailureHandler: terminalDeviceFailureHandler,
    latchedCompletionScheduler: completionScheduler,
    latchedDwell: latchedDwell,
    sensePanelPressDebounceInterval: sensePanelPressDebounceInterval,
    uptimeProvider: uptimeProvider
  )
  return (
    coordinator,
    repository,
    backend,
    primaryClickMonitor,
    pointerMotionMonitor,
    completionScheduler,
    events,
    executor,
    visibility
  )
}

func makeDiversionSnapshot(
  registryID: UInt64 = 42,
  featureIndex: UInt8 = 0x0D
) throws -> SensePanelDiversionSnapshot {
  let infoResponse = try HIDPPPacket(
    featureIndex: featureIndex,
    functionID: 0x01,
    parameters: [
      0x01, 0xA0,
      0x00, 0x00,
      0x31,
      0x00, 0x00, 0x00,
      0x05,
    ]
  )
  let control = try ReprogrammableControlsV4.parseControlInfo(
    from: infoResponse,
    index: 0
  )
  let reporting = ControlReportingState(
    controlID: ReprogrammableControlsV4.sensePanelControlID,
    diverted: false,
    persistentlyDiverted: false,
    rawXY: false,
    forceRawXY: false,
    remappedTo: 0x00C4,
    analyticsKeyEvents: false,
    rawWheel: false
  )
  struct SnapshotProxy: Codable {
    let deviceRegistryID: UInt64
    let featureIndex: UInt8
    let control: ReprogrammableControlInfo
    let originalReporting: ControlReportingState
  }
  let data = try JSONEncoder().encode(
    SnapshotProxy(
      deviceRegistryID: registryID,
      featureIndex: featureIndex,
      control: control,
      originalReporting: reporting
    )
  )
  return try JSONDecoder().decode(SensePanelDiversionSnapshot.self, from: data)
}
