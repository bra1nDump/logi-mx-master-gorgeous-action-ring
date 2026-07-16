import Foundation
import LogiLiquidControl
import LogiLiquidCore
import LogiLiquidDaemon
import XCTest

private enum CoordinatorTestError: Error {
  case hapticFailure
}

final class MouseDaemonCoordinatorTests: XCTestCase {
  func testActionCRUDUsesStableNamesAndPreservesExplicitOrder() throws {
    let fixture = makeTestCoordinator()
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    let first = ConfiguredAction.application(
      ApplicationAction(bundleID: "com.apple.Terminal")
    )
    let second = ConfiguredAction.executable(
      ExecutableAction(executable: "/usr/bin/open", argv: ["-a", "Finder"])
    )
    _ = try fixture.coordinator.handle(
      ControlRequest(
        method: .actionsPut,
        params: .object([
          "name": .string("terminal"),
          "action": try MouseDaemonJSON.encode(first),
        ])
      )
    )
    _ = try fixture.coordinator.handle(
      ControlRequest(
        method: .actionsPut,
        params: .object([
          "name": .string("finder"),
          "action": try MouseDaemonJSON.encode(second),
        ])
      )
    )

    let moved = try fixture.coordinator.handle(
      ControlRequest(
        method: .actionsMove,
        params: .object([
          "name": .string("finder"),
          "index": .integer(0),
        ])
      )
    )
    let movedConfiguration = try MouseDaemonJSON.decode(
      MouseConfiguration.self,
      from: moved
    )
    XCTAssertEqual(movedConfiguration.ring, ["finder", "terminal"])

    let removed = try fixture.coordinator.handle(
      ControlRequest(
        method: .actionsRemove,
        params: .object(["name": .string("terminal")])
      )
    )
    let removedConfiguration = try MouseDaemonJSON.decode(
      MouseConfiguration.self,
      from: removed
    )
    XCTAssertEqual(removedConfiguration.ring, ["finder"])
    XCTAssertNil(removedConfiguration.actions["terminal"])

    let listed = try fixture.coordinator.handle(
      ControlRequest(method: .actionsList)
    )
    XCTAssertEqual(
      try MouseDaemonJSON.decode(MouseConfiguration.self, from: listed),
      removedConfiguration
    )
  }

  func testScopedApplicationRemovalAndClearPreservePayloadsAndGlobalReferences() throws {
    let shared = ConfiguredAction.shortcut(ShortcutAction(key: "s"))
    let contextOnly = ConfiguredAction.shortcut(ShortcutAction(key: "c"))
    let configuration = MouseConfiguration(
      actions: [
        "Shared": shared,
        "Context Only": contextOnly,
      ],
      zones: RingZones(top: ["Shared"]),
      applicationSpecific: [
        "com.example.editor": ApplicationSpecificActions(
          bottom: ["Shared", "Context Only"]
        )
      ]
    )
    let fixture = makeTestCoordinator(configuration: configuration)
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    let removed = try fixture.coordinator.handle(
      ControlRequest(
        method: .actionsRemove,
        params: [
          "name": "Shared",
          "zone": "bottom",
          "applicationBundleID": "com.example.editor",
        ]
      )
    )
    let afterRemove = try MouseDaemonJSON.decode(
      MouseConfiguration.self,
      from: removed
    )
    XCTAssertEqual(
      afterRemove.applicationSpecific["com.example.editor"]?.bottom,
      ["Context Only"]
    )
    XCTAssertNotNil(afterRemove.actions["Shared"])
    XCTAssertEqual(afterRemove.zones.top, ["Shared"])

    let cleared = try fixture.coordinator.handle(
      ControlRequest(
        method: .actionsClear,
        params: [
          "zone": "bottom",
          "applicationBundleID": "com.example.editor",
        ]
      )
    )
    let afterClear = try MouseDaemonJSON.decode(
      MouseConfiguration.self,
      from: cleared
    )
    XCTAssertEqual(afterClear.applicationSpecific["com.example.editor"]?.bottom, [])
    XCTAssertEqual(
      Set(afterClear.actions.keys),
      ["Shared", "Context Only"]
    )
    XCTAssertEqual(afterClear.zones.top, ["Shared"])
  }

  func testSimulationLatchesThenAutoCompletesThroughProductionScheduler() throws {
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let fixture = makeTestCoordinator(configuration: configuration)
    let published = PublishedEventRecorder()
    let token = fixture.events.subscribe { event in
      published.append(event)
    }
    defer { fixture.events.unsubscribe(token) }
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    _ = try fixture.coordinator.handle(
      ControlRequest(
        method: .simulateInvoke,
        params: .object([
          "origin": .object(["x": .number(10), "y": .number(20)])
        ])
      )
    )
    let latchedValue = try fixture.coordinator.handle(
      ControlRequest(
        method: .simulateMove,
        params: .object([
          "delta": .object(["x": .number(0), "y": .number(-115)])
        ])
      )
    )
    let latched = try MouseDaemonJSON.decode(
      RingTransition.self,
      from: latchedValue
    )
    XCTAssertEqual(latched.frame.phase, .latched)
    XCTAssertEqual(latched.actionToPerform?.name, "terminal")
    XCTAssertEqual(latched.hapticIntent, .play(waveformID: 0))
    XCTAssertEqual(latched.cursorVisibilityIntent, .none)
    XCTAssertEqual(fixture.completionScheduler.scheduledCount, 1)

    _ = try fixture.coordinator.handle(
      ControlRequest(
        method: .simulateMove,
        params: .object([
          "delta": .object(["x": .number(0), "y": .number(-20)])
        ])
      )
    )

    fixture.completionScheduler.runNext()
    let committedStatus = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(committedStatus.phase, .committed)

    // Explicit completion stays idempotent for deterministic agent scripts.
    let duplicateCompletionValue = try fixture.coordinator.handle(
      ControlRequest(method: .simulateComplete)
    )
    let duplicateCompletion = try MouseDaemonJSON.decode(
      RingTransition.self,
      from: duplicateCompletionValue
    )
    XCTAssertEqual(duplicateCompletion.frame.phase, .committed)
    XCTAssertNil(duplicateCompletion.actionToPerform)
    XCTAssertEqual(duplicateCompletion.hapticIntent, .none)
    XCTAssertEqual(duplicateCompletion.cursorVisibilityIntent, .none)

    XCTAssertEqual(fixture.backend.hapticWaveforms, [0])
    XCTAssertEqual(fixture.executor.invocations.map(\.name), ["terminal"])
    let transitions = published.events.filter { $0.event == "ring.transition" }
    XCTAssertEqual(transitions.count, 5)
  }

  func testPointerSourceHandsOffFromRawWhilePressedToSystemAfterRelease() throws {
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let fixture = makeTestCoordinator(
      configuration: configuration,
      cursorPosition: Vector2(x: 50, y: 60)
    )
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    fixture.backend.emit(.sensePanelPressed)
    XCTAssertTrue(fixture.primaryClickMonitor.tracking)
    XCTAssertFalse(fixture.pointerMotionMonitor.tracking)
    fixture.backend.emit(.pointerDelta(Vector2(x: 0, y: -30)))

    var status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .tracking)
    XCTAssertTrue(fixture.primaryClickMonitor.tracking)
    XCTAssertFalse(fixture.pointerMotionMonitor.tracking)

    fixture.backend.emit(.sensePanelReleased)
    XCTAssertTrue(fixture.primaryClickMonitor.tracking)
    XCTAssertTrue(fixture.pointerMotionMonitor.tracking)

    // Raw HID++ is no longer authoritative after release and must not overlap
    // the system-pointer source.
    fixture.backend.emit(.pointerDelta(Vector2(x: 0, y: -100)))
    status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .tracking)

    fixture.pointerMotionMonitor.emit(
      .pointerDelta(Vector2(x: 0, y: -85))
    )

    status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .latched)
    XCTAssertFalse(fixture.primaryClickMonitor.tracking)
    XCTAssertFalse(fixture.pointerMotionMonitor.tracking)
    XCTAssertEqual(fixture.executor.invocations.map(\.name), ["terminal"])
    XCTAssertEqual(fixture.backend.hapticWaveforms, [0])
    XCTAssertEqual(fixture.completionScheduler.scheduledCount, 1)
    XCTAssertEqual(
      fixture.completionScheduler.delays,
      [MouseDaemonCoordinator.defaultLatchedDwell]
    )

    fixture.completionScheduler.runNext()
    status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .committed)
    XCTAssertEqual(fixture.executor.invocations.map(\.name), ["terminal"])
    XCTAssertEqual(fixture.backend.hapticWaveforms, [0])
    XCTAssertEqual(fixture.visibility.intents, [.hide, .restore])
  }

  func testPhysicalPrimaryClickDismissesAndCannotBypassOverlapThreshold() throws {
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let fixture = makeTestCoordinator(configuration: configuration)
    let published = PublishedEventRecorder()
    let token = fixture.events.subscribe { event in
      published.append(event)
    }
    defer { fixture.events.unsubscribe(token) }
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    fixture.backend.emit(.sensePanelPressed)
    fixture.backend.emit(.sensePanelReleased)
    fixture.pointerMotionMonitor.emit(.pointerDelta(Vector2(x: 0, y: -45)))
    fixture.primaryClickMonitor.emit(.primaryClick)

    let status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .cancelled)
    XCTAssertFalse(fixture.primaryClickMonitor.tracking)
    XCTAssertFalse(fixture.pointerMotionMonitor.tracking)
    XCTAssertEqual(fixture.executor.invocations, [])
    XCTAssertEqual(fixture.backend.hapticWaveforms, [])
    XCTAssertEqual(fixture.completionScheduler.scheduledCount, 0)
    XCTAssertEqual(
      published.events.filter { $0.event == "ring.transition" }.count,
      4
    )

    fixture.primaryClickMonitor.emit(.primaryClick)
    XCTAssertEqual(fixture.executor.invocations, [])
    XCTAssertEqual(
      published.events.filter { $0.event == "ring.transition" }.count,
      4
    )
  }

  func testPhysicalPrimaryClickWithoutTargetDismisses() throws {
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let fixture = makeTestCoordinator(configuration: configuration)
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    fixture.backend.emit(.sensePanelPressed)
    fixture.backend.emit(.sensePanelReleased)
    fixture.primaryClickMonitor.emit(.primaryClick)

    let status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .cancelled)
    XCTAssertFalse(fixture.primaryClickMonitor.tracking)
    XCTAssertFalse(fixture.pointerMotionMonitor.tracking)
    XCTAssertEqual(fixture.executor.invocations, [])
  }

  func testSecondSensePanelClickDismissesWithoutExecuting() throws {
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let fixture = makeTestCoordinator(configuration: configuration)
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    fixture.backend.emit(.sensePanelPressed)
    fixture.backend.emit(.sensePanelReleased)
    fixture.backend.emit(.sensePanelPressed)
    fixture.backend.emit(.sensePanelReleased)

    let status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .cancelled)
    XCTAssertFalse(fixture.primaryClickMonitor.tracking)
    XCTAssertFalse(fixture.pointerMotionMonitor.tracking)
    XCTAssertEqual(fixture.executor.invocations, [])
    XCTAssertEqual(fixture.backend.hapticWaveforms, [])
  }

  func testDuplicateSenseEdgesInvokeOnceAndCleanNextPressIsAccepted() throws {
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let fixture = makeTestCoordinator(configuration: configuration)
    let published = PublishedEventRecorder()
    let token = fixture.events.subscribe { published.append($0) }
    defer { fixture.events.unsubscribe(token) }
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    fixture.backend.emit(.sensePanelPressed)
    fixture.backend.emit(.sensePanelPressed)
    fixture.backend.emit(.sensePanelPressed)
    fixture.backend.emit(.sensePanelReleased)
    fixture.backend.emit(.sensePanelReleased)

    var status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .invoked)
    XCTAssertEqual(fixture.backend.hapticWaveforms, [])
    XCTAssertTrue(fixture.primaryClickMonitor.tracking)
    XCTAssertEqual(
      published.events.filter { $0.event == "hid.sense-panel.pressed" }.count,
      1
    )
    XCTAssertEqual(
      published.events.filter { $0.event == "hid.sense-panel.released" }.count,
      1
    )

    fixture.backend.emit(.sensePanelPressed)
    status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .cancelled)
    XCTAssertEqual(fixture.backend.hapticWaveforms, [])

    fixture.backend.emit(.sensePanelReleased)
    fixture.backend.emit(.sensePanelPressed)
    status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .invoked)
    XCTAssertEqual(fixture.backend.hapticWaveforms, [])
  }

  func testSensePressReleaseBounceIsDebouncedWithoutBlockingLaterIntentionalPress() throws {
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let clock = TestUptimeClock(uptime: 100)
    let fixture = makeTestCoordinator(
      configuration: configuration,
      sensePanelPressDebounceInterval: 0.15,
      uptimeProvider: { clock.uptime }
    )
    let published = PublishedEventRecorder()
    let token = fixture.events.subscribe { published.append($0) }
    defer { fixture.events.unsubscribe(token) }
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    fixture.backend.emit(.sensePanelPressed)
    fixture.backend.emit(.sensePanelReleased)
    clock.advance(by: 0.05)
    fixture.backend.emit(.sensePanelPressed)
    fixture.backend.emit(.sensePanelReleased)

    var status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .invoked)
    XCTAssertEqual(fixture.backend.hapticWaveforms, [])
    XCTAssertEqual(
      published.events.filter { $0.event == "hid.sense-panel.pressed" }.count,
      1
    )
    XCTAssertEqual(
      published.events.filter { $0.event == "hid.sense-panel.released" }.count,
      1
    )

    clock.advance(by: 0.2)
    fixture.backend.emit(.sensePanelPressed)
    status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .cancelled)
    XCTAssertEqual(fixture.backend.hapticWaveforms, [])
    XCTAssertEqual(
      published.events.filter { $0.event == "hid.sense-panel.pressed" }.count,
      2
    )

    fixture.backend.emit(.sensePanelReleased)
    clock.advance(by: 0.2)
    fixture.backend.emit(.sensePanelPressed)
    status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .invoked)
    XCTAssertEqual(fixture.backend.hapticWaveforms, [])
  }

  func testInvocationSkipsAutomaticHapticAndExplicitCLIStillPlaysIt() throws {
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let fixture = makeTestCoordinator(configuration: configuration)
    fixture.backend.hapticError = CoordinatorTestError.hapticFailure
    let published = PublishedEventRecorder()
    let token = fixture.events.subscribe { event in
      published.append(event)
    }
    defer { fixture.events.unsubscribe(token) }
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    fixture.backend.emit(.sensePanelPressed)

    var status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .invoked)
    XCTAssertTrue(fixture.primaryClickMonitor.tracking)
    XCTAssertFalse(fixture.pointerMotionMonitor.tracking)
    XCTAssertEqual(fixture.backend.hapticWaveforms, [])
    XCTAssertEqual(fixture.visibility.intents, [.hide])
    XCTAssertEqual(fixture.executor.invocations, [])
    XCTAssertEqual(
      published.events.filter { $0.event == "ring.transition" }.count,
      1
    )
    XCTAssertEqual(
      published.events.filter { $0.event == "daemon.input-error" }.count,
      0
    )

    fixture.backend.hapticError = nil
    let played = try fixture.coordinator.handle(
      ControlRequest(
        method: .hapticPlay,
        params: .object(["waveformID": .integer(7)])
      )
    )
    XCTAssertEqual(
      played,
      .object(["played": .bool(true), "waveformID": .integer(7)])
    )
    XCTAssertEqual(fixture.backend.hapticWaveforms, [7])
    status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .invoked)
  }

  func testLatchHapticFailureStillRunsActionAndScheduledCompletion() throws {
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let fixture = makeTestCoordinator(configuration: configuration)
    fixture.backend.hapticError = CoordinatorTestError.hapticFailure
    let published = PublishedEventRecorder()
    let token = fixture.events.subscribe { published.append($0) }
    defer { fixture.events.unsubscribe(token) }
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    fixture.backend.emit(.sensePanelPressed)
    fixture.backend.emit(.sensePanelReleased)
    fixture.pointerMotionMonitor.emit(
      .pointerDelta(Vector2(x: 0, y: -115))
    )

    var status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .latched)
    XCTAssertEqual(fixture.executor.invocations.map(\.name), ["terminal"])
    XCTAssertEqual(fixture.backend.hapticWaveforms, [0])
    XCTAssertEqual(fixture.completionScheduler.scheduledCount, 1)
    XCTAssertFalse(fixture.primaryClickMonitor.tracking)
    XCTAssertFalse(fixture.pointerMotionMonitor.tracking)
    XCTAssertTrue(
      published.events.filter { $0.event == "daemon.input-error" }.isEmpty
    )

    fixture.completionScheduler.runNext()
    status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .committed)
    XCTAssertEqual(fixture.visibility.intents, [.hide, .restore])
    XCTAssertEqual(fixture.executor.invocations.map(\.name), ["terminal"])
    XCTAssertEqual(fixture.backend.hapticWaveforms, [0])
  }

  func testTerminalDeviceFailureCancelsInteractionAndRequestsProcessTerminationOnce() throws {
    let failures = TerminalDeviceFailureRecorder()
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let fixture = makeTestCoordinator(
      configuration: configuration,
      terminalDeviceFailureHandler: { message in failures.append(message) }
    )
    let published = PublishedEventRecorder()
    let token = fixture.events.subscribe { published.append($0) }
    defer { fixture.events.unsubscribe(token) }
    try fixture.coordinator.start()

    fixture.backend.emit(.sensePanelPressed)
    XCTAssertTrue(fixture.primaryClickMonitor.tracking)
    fixture.backend.emit(.pointerDelta(Vector2(x: 0, y: -115)))
    XCTAssertEqual(fixture.completionScheduler.scheduledCount, 1)
    XCTAssertFalse(fixture.primaryClickMonitor.tracking)
    XCTAssertFalse(fixture.pointerMotionMonitor.tracking)

    fixture.backend.emit(.terminated(message: "device disconnected"))
    fixture.backend.emit(.terminated(message: "duplicate disconnect"))
    fixture.completionScheduler.runNext()

    XCTAssertFalse(fixture.coordinator.isRunning)
    XCTAssertFalse(fixture.primaryClickMonitor.tracking)
    XCTAssertFalse(fixture.pointerMotionMonitor.tracking)
    XCTAssertEqual(failures.messages, ["device disconnected"])
    let status = try MouseDaemonJSON.decode(
      MouseDaemonStatus.self,
      from: fixture.coordinator.handle(ControlRequest(method: .status))
    )
    XCTAssertEqual(status.phase, .cancelled)
    XCTAssertEqual(fixture.executor.invocations.map(\.name), ["terminal"])
    XCTAssertEqual(fixture.backend.hapticWaveforms, [0])
    XCTAssertEqual(fixture.visibility.intents, [.hide, .restore])
    let terminalEvents = published.events.filter { $0.event == "daemon.device-error" }
    XCTAssertEqual(terminalEvents.count, 2)

    // This is the production executable's shutdown path. Backend stop waits
    // for its event loop to restore diversion before the process exits.
    try fixture.coordinator.stop()
    XCTAssertFalse(fixture.backend.isActive)
  }

  func testInvalidParametersAndInvalidMoveHaveStableErrors() throws {
    let fixture = makeTestCoordinator()
    try fixture.coordinator.start()
    defer { try? fixture.coordinator.stop() }

    XCTAssertThrowsError(
      try fixture.coordinator.handle(
        ControlRequest(
          method: .simulateMove,
          params: .object(["delta": .string("wrong")])
        )
      )
    ) { error in
      XCTAssertEqual(
        (error as? ControlRequestFailure)?.wireError.code,
        "invalid_params"
      )
    }

    XCTAssertThrowsError(
      try fixture.coordinator.handle(
        ControlRequest(
          method: .actionsMove,
          params: .object([
            "name": .string("missing"),
            "index": .integer(0),
          ])
        )
      )
    ) { error in
      XCTAssertEqual(
        (error as? ControlRequestFailure)?.wireError.code,
        "config_error"
      )
    }
  }
}

private final class TestUptimeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedUptime: TimeInterval

  init(uptime: TimeInterval) {
    storedUptime = uptime
  }

  var uptime: TimeInterval {
    lock.withLock { storedUptime }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock { storedUptime += interval }
  }
}

private final class TerminalDeviceFailureRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var messages: [String] {
    lock.withLock { storage }
  }

  func append(_ message: String) {
    lock.withLock { storage.append(message) }
  }
}
