import Foundation
import LogiLiquidCore
import XCTest

@testable import LogiLiquidService

@MainActor
final class MouseRuntimeTests: XCTestCase {
  private let profile = try! RingInteractionProfile(
    ringRadius: 100,
    targetingDeadZone: 5,
    mergeStartDistance: 50
  )

  func testPhysicalInvocationUsesCursorPublishesAndDoesNotPlayAutomaticHaptic() async throws {
    let dependencies = makeDependencies(configuration: configuration(named: "Search"))
    dependencies.cursor.position = Vector2(x: 800, y: 450)
    dependencies.frontmost.context = FrontmostApplicationContext(
      bundleID: "com.apple.Terminal",
      localizedName: "Terminal"
    )
    let runtime = makeRuntime(dependencies)

    let invocation = try await runtime.invoke()
    XCTAssertEqual(invocation.frame.origin, Vector2(x: 800, y: 450))
    XCTAssertEqual(invocation.frame.phase, .invoked)
    XCTAssertEqual(
      invocation.frame.frontmostApplication.bundleID,
      "com.apple.Terminal"
    )
    XCTAssertEqual(dependencies.cursor.readCount, 1)
    XCTAssertEqual(dependencies.frontmost.readCount, 1)
    XCTAssertEqual(dependencies.hid.waveformIDs, [])
    XCTAssertEqual(dependencies.visibility.intents, [.hide])
    XCTAssertEqual(dependencies.publisher.transitions, [invocation])

    let duplicate = try await runtime.invoke()
    XCTAssertEqual(duplicate.frame.origin, Vector2(x: 800, y: 450))
    XCTAssertEqual(duplicate.frame.phase, .cancelled)
    XCTAssertEqual(duplicate.hapticIntent, .none)
    XCTAssertEqual(dependencies.hid.waveformIDs, [])
    XCTAssertEqual(dependencies.loader.loadCount, 1)
    XCTAssertEqual(dependencies.publisher.transitions.count, 2)
    XCTAssertEqual(dependencies.visibility.intents, [.hide, .restore])
  }

  func testSimulationInvocationDoesNotReadPhysicalCursor() async throws {
    let dependencies = makeDependencies(configuration: configuration(named: "Search"))
    let runtime = makeRuntime(dependencies)

    let transition = try await runtime.simulate(
      .invoke(origin: Vector2(x: 123, y: 456))
    )

    XCTAssertEqual(transition.frame.origin, Vector2(x: 123, y: 456))
    XCTAssertEqual(dependencies.cursor.readCount, 0)
  }

  func testConfiguredHapticFailureCannotBreakInvocationBecauseItIsNotPlayed() async throws {
    let dependencies = makeDependencies(configuration: configuration(named: "Search"))
    dependencies.hid.error = FakeError.expected
    let runtime = makeRuntime(dependencies)

    let invocation = try await runtime.invoke()

    let phase = await runtime.currentPhase()
    XCTAssertEqual(invocation.frame.phase, .invoked)
    XCTAssertEqual(phase, .invoked)
    XCTAssertEqual(dependencies.hid.waveformIDs, [])
    XCTAssertEqual(dependencies.visibility.intents, [.hide])
    XCTAssertEqual(dependencies.publisher.transitions, [invocation])
    XCTAssertEqual(dependencies.executor.invocations, [])
  }

  func testCursorHideFailureDoesNotPublishAVisibleInvocation() async throws {
    let dependencies = makeDependencies(configuration: configuration(named: "Search"))
    dependencies.visibility.hideError = FakeError.expected
    let runtime = makeRuntime(dependencies)

    do {
      _ = try await runtime.invoke()
      XCTFail("Expected cursor hide to fail")
    } catch {
      XCTAssertEqual(error as? FakeError, .expected)
    }

    XCTAssertEqual(dependencies.publisher.transitions, [])
    XCTAssertEqual(dependencies.visibility.intents, [.hide])

    dependencies.visibility.hideError = nil
    let cancelled = try await runtime.cancel()
    XCTAssertEqual(cancelled.frame.phase, .cancelled)
    XCTAssertEqual(dependencies.publisher.transitions, [cancelled])
  }

  func testConfigurationIsSnapshottedUntilNextInvocationThenReloaded() async throws {
    let dependencies = makeDependencies(configuration: configuration(named: "First"))
    let runtime = makeRuntime(dependencies)

    _ = try await runtime.simulate(.invokeAtOrigin)
    dependencies.loader.configuration = configuration(named: "Second")

    let firstLatch = try await runtime.handlePointerDelta(Vector2(x: 0, y: -76))
    XCTAssertEqual(firstLatch.frame.phase, .latched)
    XCTAssertEqual(firstLatch.actionToPerform?.name, "First")
    XCTAssertEqual(dependencies.executor.invocations.map(\.name), ["First"])
    XCTAssertEqual(dependencies.loader.loadCount, 1)
    _ = try await runtime.completeCommit()

    let secondInvocation = try await runtime.simulate(
      .invoke(origin: Vector2(x: 50, y: 60))
    )
    XCTAssertEqual(secondInvocation.frame.targetVectors.map(\.actionName), ["Second"])
    let secondLatch = try await runtime.handlePointerDelta(Vector2(x: 0, y: -76))
    XCTAssertEqual(secondLatch.frame.phase, .latched)
    XCTAssertEqual(secondLatch.actionToPerform?.name, "Second")
    XCTAssertEqual(dependencies.executor.invocations.map(\.name), ["First", "Second"])
    XCTAssertEqual(dependencies.loader.loadCount, 2)
    XCTAssertEqual(dependencies.hid.waveformIDs, [0, 0])
  }

  func testEveryTransitionIsPublishedInOrderThroughCancel() async throws {
    let dependencies = makeDependencies(configuration: configuration(named: "Search"))
    let runtime = makeRuntime(dependencies)

    let invoked = try await runtime.simulate(.invokeAtOrigin)
    let tracking = try await runtime.handlePointerDelta(Vector2(x: 0, y: -30))
    let cancelled = try await runtime.cancel()
    let ignoredMovement = try await runtime.handlePointerDelta(Vector2(x: 0, y: -80))

    XCTAssertEqual(
      dependencies.publisher.transitions,
      [invoked, tracking, cancelled, ignoredMovement]
    )
    XCTAssertEqual(
      dependencies.publisher.transitions.map(\.frame.phase),
      [.invoked, .tracking, .cancelled, .cancelled]
    )
    XCTAssertEqual(
      dependencies.publisher.transitions.map(\.cursorVisibilityIntent),
      [.hide, .none, .restore, .none]
    )
    XCTAssertEqual(dependencies.executor.invocations, [])
    XCTAssertEqual(dependencies.visibility.intents, [.hide, .restore])
  }

  func testLatchedActionAndHapticExecuteOnceBeforeDeterministicCompletion() async throws {
    let dependencies = makeDependencies(configuration: configuration(named: "Search"))
    let runtime = makeRuntime(dependencies)

    _ = try await runtime.simulate(.invokeAtOrigin)
    let latched = try await runtime.handlePointerDelta(Vector2(x: 0, y: -76))
    let ignoredMove = try await runtime.handlePointerDelta(Vector2(x: 0, y: -20))
    let ignoredClick = try await runtime.handlePrimaryClick()
    let committed = try await runtime.completeCommit()
    let ignoredCompletion = try await runtime.completeCommit()

    XCTAssertEqual(latched.frame.phase, .latched)
    XCTAssertEqual(latched.actionToPerform?.name, "Search")
    XCTAssertEqual(latched.hapticIntent, .play(waveformID: 0))
    XCTAssertNil(ignoredMove.actionToPerform)
    XCTAssertNil(ignoredClick.actionToPerform)
    XCTAssertEqual(committed.frame.phase, .committed)
    XCTAssertNil(committed.actionToPerform)
    XCTAssertEqual(committed.cursorVisibilityIntent, .restore)
    XCTAssertNil(ignoredCompletion.actionToPerform)
    XCTAssertEqual(dependencies.executor.invocations.map(\.name), ["Search"])
    XCTAssertEqual(dependencies.hid.waveformIDs, [0])
    XCTAssertEqual(dependencies.publisher.transitions.count, 6)
  }

  func testFailedActionIsAttemptedOnceAndNotRetriedByLaterInput() async throws {
    let dependencies = makeDependencies(configuration: configuration(named: "Search"))
    dependencies.executor.error = FakeError.expected
    let runtime = makeRuntime(dependencies)

    _ = try await runtime.simulate(.invokeAtOrigin)
    do {
      _ = try await runtime.handlePointerDelta(Vector2(x: 0, y: -76))
      XCTFail("Expected action execution to fail")
    } catch {
      XCTAssertEqual(error as? FakeError, .expected)
    }

    let completed = try await runtime.completeCommit()
    XCTAssertEqual(completed.frame.phase, .committed)
    XCTAssertNil(completed.actionToPerform)
    XCTAssertEqual(dependencies.executor.invocations.count, 1)
  }

  func testLatchHapticFailureDoesNotSuppressActionOrCompletion() async throws {
    let dependencies = makeDependencies(configuration: configuration(named: "Search"))
    dependencies.hid.error = FakeError.expected
    let runtime = makeRuntime(dependencies)

    _ = try await runtime.simulate(.invokeAtOrigin)
    let latched = try await runtime.handlePointerDelta(Vector2(x: 0, y: -76))

    XCTAssertEqual(latched.frame.phase, .latched)
    XCTAssertEqual(dependencies.executor.invocations.map(\.name), ["Search"])
    XCTAssertEqual(dependencies.hid.waveformIDs, [0])
    XCTAssertEqual(dependencies.visibility.intents, [.hide])

    let committed = try await runtime.completeCommit()
    XCTAssertEqual(committed.frame.phase, .committed)
    XCTAssertEqual(dependencies.visibility.intents, [.hide, .restore])
  }

  func testInputsBeforeInvocationAreRejectedWithoutPublishing() async {
    let dependencies = makeDependencies(configuration: configuration(named: "Search"))
    let runtime = makeRuntime(dependencies)

    do {
      _ = try await runtime.handlePointerDelta(Vector2(x: 1, y: 1))
      XCTFail("Expected no-active-interaction error")
    } catch {
      XCTAssertEqual(error as? MouseRuntimeError, .noActiveInteraction)
    }

    XCTAssertEqual(dependencies.publisher.transitions, [])
    XCTAssertEqual(dependencies.loader.loadCount, 0)
  }

  func testEmptyConfigurationPublishesIdleWithoutExternalEffects() async throws {
    let dependencies = makeDependencies(configuration: MouseConfiguration())
    let runtime = makeRuntime(dependencies)

    let transition = try await runtime.simulate(.invokeAtOrigin)

    XCTAssertEqual(transition.frame.phase, .idle)
    XCTAssertEqual(transition.frame.targetVectors, [])
    XCTAssertEqual(dependencies.publisher.transitions, [transition])
    XCTAssertEqual(dependencies.hid.waveformIDs, [])
    XCTAssertEqual(dependencies.executor.invocations, [])
  }

  private func configuration(named name: String) -> MouseConfiguration {
    MouseConfiguration(
      actions: [
        name: .shortcut(ShortcutAction(key: "space", modifiers: [.command]))
      ],
      ring: [name]
    )
  }

  private func makeRuntime(_ dependencies: Dependencies) -> MouseRuntime {
    MouseRuntime(
      configurationLoader: dependencies.loader,
      hidController: dependencies.hid,
      eventPublisher: dependencies.publisher,
      cursorPositionProvider: dependencies.cursor,
      actionExecutor: dependencies.executor,
      frontmostApplicationProvider: dependencies.frontmost,
      cursorVisibilityController: dependencies.visibility,
      profile: profile,
      cursorRestorationDelay: 0
    )
  }

  private func makeDependencies(configuration: MouseConfiguration) -> Dependencies {
    Dependencies(
      loader: FakeConfigurationLoader(configuration: configuration),
      hid: FakeHIDController(),
      publisher: FakeEventPublisher(),
      cursor: FakeCursorPositionProvider(),
      frontmost: FakeFrontmostApplicationProvider(),
      visibility: FakeCursorVisibilityController(),
      executor: FakeActionExecutor()
    )
  }
}

private struct Dependencies {
  let loader: FakeConfigurationLoader
  let hid: FakeHIDController
  let publisher: FakeEventPublisher
  let cursor: FakeCursorPositionProvider
  let frontmost: FakeFrontmostApplicationProvider
  let visibility: FakeCursorVisibilityController
  let executor: FakeActionExecutor
}

private enum FakeError: Error, Equatable {
  case expected
}

private final class FakeConfigurationLoader: MouseConfigurationLoading, @unchecked Sendable {
  private let lock = NSLock()
  private var storedConfiguration: MouseConfiguration
  private var storedLoadCount = 0

  init(configuration: MouseConfiguration) {
    storedConfiguration = configuration
  }

  var configuration: MouseConfiguration {
    get { lock.withLock { storedConfiguration } }
    set { lock.withLock { storedConfiguration = newValue } }
  }

  var loadCount: Int {
    lock.withLock { storedLoadCount }
  }

  func load() throws -> MouseConfiguration {
    lock.withLock {
      storedLoadCount += 1
      return storedConfiguration
    }
  }
}

private final class FakeHIDController: MouseHIDControlling, @unchecked Sendable {
  private let lock = NSLock()
  private var storedWaveformIDs: [UInt8] = []
  private var storedError: (any Error)?

  var waveformIDs: [UInt8] {
    lock.withLock { storedWaveformIDs }
  }

  var error: (any Error)? {
    get { lock.withLock { storedError } }
    set { lock.withLock { storedError = newValue } }
  }

  func playHaptic(waveformID: UInt8) throws {
    try lock.withLock {
      storedWaveformIDs.append(waveformID)
      if let storedError {
        throw storedError
      }
    }
  }
}

private final class FakeEventPublisher: RingEventPublishing, @unchecked Sendable {
  private let lock = NSLock()
  private var storedTransitions: [RingTransition] = []

  var transitions: [RingTransition] {
    lock.withLock { storedTransitions }
  }

  func publish(_ transition: RingTransition) {
    lock.withLock { storedTransitions.append(transition) }
  }
}

private final class FakeCursorPositionProvider: CursorPositionProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var storedPosition = Vector2.zero
  private var storedReadCount = 0

  var position: Vector2 {
    get { lock.withLock { storedPosition } }
    set { lock.withLock { storedPosition = newValue } }
  }

  var readCount: Int {
    lock.withLock { storedReadCount }
  }

  func currentPosition() throws -> Vector2 {
    lock.withLock {
      storedReadCount += 1
      return storedPosition
    }
  }
}

private final class FakeFrontmostApplicationProvider:
  FrontmostApplicationProviding, @unchecked Sendable
{
  private let lock = NSLock()
  private var storedContext = FrontmostApplicationContext.unknown
  private var storedReadCount = 0

  var context: FrontmostApplicationContext {
    get { lock.withLock { storedContext } }
    set { lock.withLock { storedContext = newValue } }
  }

  var readCount: Int {
    lock.withLock { storedReadCount }
  }

  func currentApplication() throws -> FrontmostApplicationContext {
    lock.withLock {
      storedReadCount += 1
      return storedContext
    }
  }
}

private final class FakeCursorVisibilityController:
  CursorVisibilityControlling, @unchecked Sendable
{
  private let lock = NSLock()
  private var storedIntents: [CursorVisibilityIntent] = []
  private var storedHideError: (any Error)?

  var intents: [CursorVisibilityIntent] {
    lock.withLock { storedIntents }
  }

  var hideError: (any Error)? {
    get { lock.withLock { storedHideError } }
    set { lock.withLock { storedHideError = newValue } }
  }

  func hideCursor() throws {
    try lock.withLock {
      storedIntents.append(.hide)
      if let storedHideError {
        throw storedHideError
      }
    }
  }

  func restoreCursor() throws {
    lock.withLock { storedIntents.append(.restore) }
  }
}

private final class FakeActionExecutor: ActionExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var storedInvocations: [ActionInvocation] = []
  private var storedError: (any Error)?

  var invocations: [ActionInvocation] {
    lock.withLock { storedInvocations }
  }

  var error: (any Error)? {
    get { lock.withLock { storedError } }
    set { lock.withLock { storedError = newValue } }
  }

  func execute(_ invocation: ActionInvocation) throws {
    try lock.withLock {
      storedInvocations.append(invocation)
      if let storedError {
        throw storedError
      }
    }
  }
}
