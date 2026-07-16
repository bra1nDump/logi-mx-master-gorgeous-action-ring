import Foundation
import LogiLiquidCore

/// Loads the latest durable configuration. `MouseRuntime` calls this only when
/// beginning a new interaction, then lets the core machine retain that snapshot.
public protocol MouseConfigurationLoading: Sendable {
  func load() throws -> MouseConfiguration
}

public protocol MouseHIDControlling: Sendable {
  func playHaptic(waveformID: UInt8) throws
}

/// Receives every transition produced by the state machine, including ignored
/// inputs whose frame does not change. Publishers should enqueue synchronously.
public protocol RingEventPublishing: Sendable {
  func publish(_ transition: RingTransition)
}

public protocol CursorPositionProviding: Sendable {
  func currentPosition() throws -> Vector2
}

public protocol FrontmostApplicationProviding: Sendable {
  func currentApplication() throws -> FrontmostApplicationContext
}

public protocol CursorVisibilityControlling: Sendable {
  func hideCursor() throws
  func restoreCursor() throws
}

public protocol ActionExecuting: Sendable {
  func execute(_ invocation: ActionInvocation) throws
}

public struct FileMouseConfigurationLoader: MouseConfigurationLoading, Sendable {
  public let store: ConfigurationStore

  public init(url: URL) throws {
    store = try ConfigurationStore(url: url)
  }

  public func load() throws -> MouseConfiguration {
    try store.load()
  }
}

public enum MouseRuntimeError: Error, Equatable, Sendable {
  case noActiveInteraction
}

public struct UnknownFrontmostApplicationProvider:
  FrontmostApplicationProviding, Sendable
{
  public init() {}

  public func currentApplication() throws -> FrontmostApplicationContext {
    .unknown
  }
}

public struct NoopCursorVisibilityController:
  CursorVisibilityControlling, Sendable
{
  public init() {}

  public func hideCursor() throws {}

  public func restoreCursor() throws {}
}

/// Serial orchestration boundary between physical/simulated input, the pure ring
/// machine, and one-shot external effects. It owns no HID session or UI.
public actor MouseRuntime {
  private let configurationLoader: any MouseConfigurationLoading
  private let hidController: any MouseHIDControlling
  private let eventPublisher: any RingEventPublishing
  private let cursorPositionProvider: any CursorPositionProviding
  private let frontmostApplicationProvider: any FrontmostApplicationProviding
  private let cursorVisibilityController: any CursorVisibilityControlling
  private let actionExecutor: any ActionExecuting
  private let profile: RingInteractionProfile
  private let cursorRestorationDelay: TimeInterval

  private var machine: RingInteractionMachine?

  public init(
    configurationLoader: any MouseConfigurationLoading,
    hidController: any MouseHIDControlling,
    eventPublisher: any RingEventPublishing,
    cursorPositionProvider: any CursorPositionProviding,
    actionExecutor: any ActionExecuting,
    frontmostApplicationProvider: any FrontmostApplicationProviding =
      UnknownFrontmostApplicationProvider(),
    cursorVisibilityController: any CursorVisibilityControlling =
      NoopCursorVisibilityController(),
    profile: RingInteractionProfile = .default,
    cursorRestorationDelay: TimeInterval = RingInteractionTiming.cursorRestorationDelay
  ) {
    self.configurationLoader = configurationLoader
    self.hidController = hidController
    self.eventPublisher = eventPublisher
    self.cursorPositionProvider = cursorPositionProvider
    self.frontmostApplicationProvider = frontmostApplicationProvider
    self.cursorVisibilityController = cursorVisibilityController
    self.actionExecutor = actionExecutor
    self.profile = profile
    self.cursorRestorationDelay = max(cursorRestorationDelay, 0)
  }

  /// Starts a physical interaction at the current system cursor position.
  @discardableResult
  public func invoke() throws -> RingTransition {
    try beginPanelTrigger(
      at: cursorPositionProvider.currentPosition(),
      frontmostApplication: frontmostApplicationProvider.currentApplication()
    )
  }

  /// Feeds one physical relative-pointer report into the current interaction.
  @discardableResult
  public func handlePointerDelta(_ delta: Vector2) throws -> RingTransition {
    try feed(.pointerDelta(delta))
  }

  @discardableResult
  public func handlePanelRelease() throws -> RingTransition {
    try feed(.panelRelease)
  }

  @discardableResult
  public func handlePrimaryClick() throws -> RingTransition {
    try feed(.primaryClick)
  }

  @discardableResult
  public func completeCommit() throws -> RingTransition {
    try feed(.completeCommit)
  }

  @discardableResult
  public func dismiss() throws -> RingTransition {
    try feed(.dismiss)
  }

  @discardableResult
  public func cancel() throws -> RingTransition {
    try feed(.cancel)
  }

  @discardableResult
  public func reset() throws -> RingTransition {
    try feed(.reset)
  }

  /// Drives the exact same runtime path without reading physical cursor or HID input.
  @discardableResult
  public func simulate(_ input: RingInput) throws -> RingTransition {
    switch input {
    case .invoke(let origin):
      try beginInvocation(at: origin)
    case .panelTrigger(let origin, let frontmostApplication):
      try beginPanelTrigger(
        at: origin,
        frontmostApplication: frontmostApplication
      )
    case .panelRelease, .pointerDelta, .primaryClick, .completeCommit, .escape,
      .dismiss, .cancel, .reset:
      try feed(input)
    }
  }

  public func currentPhase() -> RingInteractionPhase {
    machine?.phase ?? .idle
  }

  /// Restores only a cursor hide owned by this runtime's visibility controller.
  /// The production controller is idempotent and never decrements the global
  /// hide count unless its own prior hide succeeded.
  public func restoreCursorIfNeeded() throws {
    try cursorVisibilityController.restoreCursor()
  }

  private func beginInvocation(at origin: Vector2) throws -> RingTransition {
    try beginPanelTrigger(at: origin, frontmostApplication: .unknown)
  }

  private func beginPanelTrigger(
    at origin: Vector2,
    frontmostApplication: FrontmostApplicationContext
  ) throws -> RingTransition {
    if var activeMachine = machine,
      activeMachine.phase == .invoked || activeMachine.phase == .tracking
        || activeMachine.phase == .latched
    {
      let transition = activeMachine.handle(
        .panelTrigger(
          origin: origin,
          frontmostApplication: frontmostApplication
        )
      )
      machine = activeMachine
      return try publishAndPerformEffects(transition)
    }

    let configuration = try configurationLoader.load()
    var newMachine = try RingInteractionMachine(
      configuration: configuration,
      profile: profile
    )
    let transition = newMachine.handle(
      .panelTrigger(
        origin: origin,
        frontmostApplication: frontmostApplication
      )
    )
    machine = newMachine
    return try publishAndPerformEffects(transition)
  }

  private func feed(_ input: RingInput) throws -> RingTransition {
    guard var activeMachine = machine else {
      throw MouseRuntimeError.noActiveInteraction
    }

    let transition = activeMachine.handle(input)
    machine = activeMachine
    return try publishAndPerformEffects(transition)
  }

  private func publishAndPerformEffects(_ transition: RingTransition) throws -> RingTransition {
    // On invocation, remove the real pointer before the overlay becomes
    // visible. Terminal frames still publish first so the overlay disappears
    // before the real pointer is restored.
    if transition.cursorVisibilityIntent == .hide {
      try cursorVisibilityController.hideCursor()
    }

    eventPublisher.publish(transition)

    if transition.cursorVisibilityIntent == .restore {
      if cursorRestorationDelay > 0 {
        Thread.sleep(forTimeInterval: cursorRestorationDelay)
      }
      try cursorVisibilityController.restoreCursor()
    }

    var actionFailure: (any Error)?
    if let invocation = transition.actionToPerform {
      do {
        try actionExecutor.execute(invocation)
      } catch {
        actionFailure = error
      }
    }

    if case .play(let waveformID) = transition.hapticIntent {
      do {
        try hidController.playHaptic(waveformID: waveformID)
      } catch {
        // Latch haptics are tactile confirmation, never authority. The action
        // has already been attempted and suction completion must continue.
        if transition.actionToPerform == nil {
          throw error
        }
      }
    }

    if let actionFailure {
      throw actionFailure
    }

    return transition
  }
}
