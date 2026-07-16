import Foundation
import LogiLiquidControl
import LogiLiquidService

/// Owns the Unix control endpoint around an injected coordinator. The same
/// host is used by production and the black-box fake daemon fixture.
public final class MouseDaemonControlHost: @unchecked Sendable {
  public let coordinator: MouseDaemonCoordinator
  public let server: UnixControlServer

  private let eventHub: MouseDaemonEventHub
  private let eventSubscription: UUID
  private let lifecycleLock = NSLock()
  private var started = false

  public init(
    coordinator: MouseDaemonCoordinator,
    eventHub: MouseDaemonEventHub,
    socketURL: URL = LogiLiquidControlProtocol.defaultSocketURL
  ) {
    self.coordinator = coordinator
    self.eventHub = eventHub
    let server = UnixControlServer(socketURL: socketURL) { [weak coordinator] request in
      guard let coordinator else {
        throw ControlRequestFailure(
          code: "daemon_stopped",
          message: "The mouse daemon is stopping."
        )
      }
      return try coordinator.handle(request)
    }
    self.server = server
    self.eventSubscription = eventHub.subscribe { [weak server] event in
      server?.publish(
        stream: event.stream,
        event: event.event,
        payload: event.payload
      )
    }
  }

  deinit {
    try? stop()
    eventHub.unsubscribe(eventSubscription)
  }

  public func start() throws {
    lifecycleLock.lock()
    guard !started else {
      lifecycleLock.unlock()
      return
    }
    lifecycleLock.unlock()

    try server.start()
    do {
      try coordinator.start()
    } catch {
      server.stop()
      throw error
    }

    lifecycleLock.lock()
    started = true
    lifecycleLock.unlock()
  }

  public func stop() throws {
    lifecycleLock.lock()
    let wasStarted = started
    started = false
    lifecycleLock.unlock()
    guard wasStarted else {
      server.stop()
      return
    }

    var stopError: (any Error)?
    do {
      try coordinator.stop()
    } catch {
      stopError = error
    }
    server.stop()
    if let stopError {
      throw stopError
    }
  }
}

public enum ProductionMouseDaemonFactory {
  public static var defaultConfigurationURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(
        path: "Library/Application Support/Logi Liquid Controls", directoryHint: .isDirectory
      )
      .appending(path: "config.json", directoryHint: .notDirectory)
  }

  public static func make(
    configurationURL: URL = defaultConfigurationURL,
    journalURL: URL? = nil,
    socketURL: URL = LogiLiquidControlProtocol.defaultSocketURL,
    selectedRegistryID: UInt64? = nil,
    terminalDeviceFailureHandler: @escaping @Sendable (String) -> Void = { _ in }
  ) throws -> MouseDaemonControlHost {
    let repository = try PrivateMouseConfigurationRepository(
      url: configurationURL,
      initialConfiguration: .logiLiquidDefault
    )
    let resolvedJournalURL =
      journalURL
      ?? configurationURL.deletingLastPathComponent()
      .appending(path: "sense-panel-diversion.json", directoryHint: .notDirectory)
    let backend = try MXMaster4HIDBackend(
      selectedRegistryID: selectedRegistryID,
      journalURL: resolvedJournalURL
    )
    let events = MouseDaemonEventHub()
    let cursor = SystemCursorPositionProvider()
    let primaryClickMonitor = try SystemPrimaryClickMonitor()
    let pointerMotionMonitor = try SystemPointerMotionMonitor(
      positionProvider: cursor
    )
    let frontmostApplication = SystemFrontmostApplicationProvider()
    let cursorVisibility = SystemCursorVisibilityController()
    let actionExecutor = SystemActionExecutor()
    let runtime = MouseRuntime(
      configurationLoader: repository,
      hidController: backend,
      eventPublisher: events,
      cursorPositionProvider: cursor,
      actionExecutor: actionExecutor,
      frontmostApplicationProvider: frontmostApplication,
      cursorVisibilityController: cursorVisibility
    )
    let coordinator = MouseDaemonCoordinator(
      configurationRepository: repository,
      runtime: runtime,
      hidBackend: backend,
      primaryClickMonitor: primaryClickMonitor,
      pointerMotionMonitor: pointerMotionMonitor,
      eventHub: events,
      frontmostApplicationProvider: frontmostApplication,
      accessibilityTrusted: { actionExecutor.isAccessibilityTrusted },
      terminalDeviceFailureHandler: terminalDeviceFailureHandler
    )
    return MouseDaemonControlHost(
      coordinator: coordinator,
      eventHub: events,
      socketURL: socketURL
    )
  }
}
