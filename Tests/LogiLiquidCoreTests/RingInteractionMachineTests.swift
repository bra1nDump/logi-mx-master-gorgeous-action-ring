import XCTest

@testable import LogiLiquidCore

final class RingInteractionMachineTests: XCTestCase {
  private let profile = try! RingInteractionProfile(
    ringRadius: 100,
    targetingDeadZone: 5,
    mergeStartDistance: 50
  )

  func testPanelTriggerResolvesFrontmostApplicationAndEmitsZoneMetadata() throws {
    var machine = try makeMachine()
    let context = FrontmostApplicationContext(
      bundleID: "com.apple.finder",
      localizedName: "Finder"
    )
    let origin = Vector2(x: 1_280, y: 720)

    let invocation = machine.handle(
      .panelTrigger(origin: origin, frontmostApplication: context)
    )
    XCTAssertEqual(invocation.frame.phase, .invoked)
    XCTAssertEqual(invocation.frame.origin, origin)
    XCTAssertEqual(invocation.frame.frontmostApplication, context)
    XCTAssertEqual(
      invocation.frame.targetVectors.map(\.actionName),
      ["Spotify", "Telegram", "ChatGPT", "Finder Action", "Aqua"]
    )
    XCTAssertEqual(
      invocation.frame.targetVectors.map(\.zone),
      [.top, .right, .right, .bottom, .left]
    )
    XCTAssertEqual(invocation.frame.zoneLayouts.map(\.zone), CardinalZone.clockwiseOrder)
    XCTAssertEqual(
      invocation.frame.zoneLayouts.first(where: { $0.zone == .bottom })?.actionNames,
      ["Finder Action"]
    )
    XCTAssertEqual(invocation.cursorVisibilityIntent, .hide)
    XCTAssertEqual(invocation.hapticIntent, .none)
    XCTAssertNil(invocation.actionToPerform)
  }

  func testSecondPanelTriggerTogglesOpenMenuClosedAndNextTriggerReopens() throws {
    var machine = try makeMachine()
    _ = machine.handle(.panelTriggerAtOrigin())

    let toggledClosed = machine.handle(
      .panelTrigger(
        origin: Vector2(x: 900, y: 500),
        frontmostApplication: FrontmostApplicationContext(bundleID: "com.apple.finder")
      )
    )
    XCTAssertEqual(toggledClosed.frame.phase, .cancelled)
    XCTAssertEqual(toggledClosed.cursorVisibilityIntent, .restore)
    XCTAssertEqual(toggledClosed.hapticIntent, .none)
    XCTAssertNil(toggledClosed.actionToPerform)

    let reopened = machine.handle(
      .panelTrigger(
        origin: Vector2(x: 10, y: 20),
        frontmostApplication: FrontmostApplicationContext(bundleID: "com.apple.finder")
      )
    )
    XCTAssertEqual(reopened.frame.phase, .invoked)
    XCTAssertEqual(reopened.frame.origin, Vector2(x: 10, y: 20))
    XCTAssertEqual(reopened.cursorVisibilityIntent, .hide)
    XCTAssertEqual(reopened.hapticIntent, .none)
  }

  func testPanelReleaseDoesNotCancelAndMovementContinuesAfterRelease() throws {
    var machine = try makeMachine()
    _ = machine.handle(.panelTriggerAtOrigin())

    let released = machine.handle(.panelRelease)
    XCTAssertEqual(released.frame.phase, .invoked)
    XCTAssertEqual(released.cursorVisibilityIntent, .none)
    XCTAssertEqual(released.hapticIntent, .none)

    let beforeThreshold = machine.handle(.pointerDelta(Vector2(x: 0, y: -69.5)))
    XCTAssertEqual(beforeThreshold.frame.phase, .tracking)
    XCTAssertEqual(beforeThreshold.frame.currentTarget?.actionName, "Spotify")
    XCTAssertEqual(beforeThreshold.frame.mergeProgress, 0.39, accuracy: 0.000_001)
    // 69.5 of 100 points closed: the approach ramps gradually with proximity.
    XCTAssertEqual(beforeThreshold.frame.approachProgress, 1 - (30.5 / 100), accuracy: 0.000_001)
    XCTAssertNil(beforeThreshold.actionToPerform)

    let latched = machine.handle(.pointerDelta(Vector2(x: 0, y: -0.01)))
    XCTAssertEqual(latched.frame.phase, .latched)
    XCTAssertEqual(latched.actionToPerform?.name, "Spotify")
    XCTAssertEqual(latched.actionToPerform?.zone, .top)
    XCTAssertEqual(
      latched.frame.movingBubbleOffset,
      latched.frame.currentTarget?.vectorFromOrigin
    )
    XCTAssertEqual(latched.frame.mergeProgress, 1)
    XCTAssertEqual(latched.frame.approachProgress, 1)
    XCTAssertEqual(latched.cursorVisibilityIntent, .none)
    XCTAssertEqual(latched.hapticIntent, .play(waveformID: 0))

    let completed = machine.handle(.completeCommit)
    XCTAssertEqual(completed.frame.phase, .committed)
    XCTAssertNil(completed.actionToPerform)
    XCTAssertEqual(completed.hapticIntent, .none)
    XCTAssertEqual(completed.cursorVisibilityIntent, .restore)
  }

  func testPrimaryClickDismissesAndCannotBypassOverlapThreshold() throws {
    var machine = try makeMachine()
    let context = FrontmostApplicationContext(bundleID: "com.example.Editor")
    _ = machine.handle(
      .panelTrigger(origin: .zero, frontmostApplication: context)
    )
    let selected = machine.handle(.pointerDelta(Vector2(x: 0, y: -30)))
    XCTAssertEqual(selected.frame.currentTarget?.actionName, "Spotify")
    XCTAssertEqual(selected.frame.mergeProgress, 0)
    // The merge stays dormant outside the merge distance, but the approach
    // already ramps: 30 of 100 points closed.
    XCTAssertEqual(selected.frame.approachProgress, 1 - (70.0 / 100.0), accuracy: 0.000_001)

    let clicked = machine.handle(.primaryClick)
    XCTAssertEqual(clicked.frame.phase, .cancelled)
    XCTAssertNil(clicked.actionToPerform)
    XCTAssertEqual(clicked.hapticIntent, .none)
    XCTAssertEqual(clicked.cursorVisibilityIntent, .restore)

    let duplicateClick = machine.handle(.primaryClick)
    XCTAssertNil(duplicateClick.actionToPerform)
    XCTAssertEqual(duplicateClick.cursorVisibilityIntent, .none)
  }

  func testPrimaryClickWithoutSelectionDismisses() throws {
    var machine = try makeMachine()
    _ = machine.handle(.panelTriggerAtOrigin())

    let dismissed = machine.handle(.primaryClick)
    XCTAssertEqual(dismissed.frame.phase, .cancelled)
    XCTAssertEqual(dismissed.cursorVisibilityIntent, .restore)
    XCTAssertNil(dismissed.actionToPerform)
  }

  func testEscapeDismissAndLegacyCancelAllCloseWithoutAction() throws {
    for input in [RingInput.escape, .dismiss, .cancel] {
      var machine = try makeMachine()
      _ = machine.handle(.panelTriggerAtOrigin())
      _ = machine.handle(.pointerDelta(Vector2(x: 0, y: -20)))

      let cancelled = machine.handle(input)
      XCTAssertEqual(cancelled.frame.phase, .cancelled)
      XCTAssertEqual(cancelled.cursorVisibilityIntent, .restore)
      XCTAssertNil(cancelled.actionToPerform)
    }
  }

  func testOverlapThresholdLatchesActionAndHapticExactlyOnceThenCompletes() throws {
    var machine = try makeMachine()
    _ = machine.handle(.panelTriggerAtOrigin())
    let outside = machine.handle(
      .pointerDelta(Vector2(x: 0, y: -69.5075))
    )
    XCTAssertEqual(outside.frame.phase, .tracking)

    let latched = machine.handle(.pointerDelta(Vector2(x: 0, y: -0.001)))
    XCTAssertEqual(latched.frame.phase, .latched)
    XCTAssertEqual(latched.frame.mergeProgress, 1)
    XCTAssertEqual(latched.actionToPerform?.name, "Spotify")
    XCTAssertEqual(latched.hapticIntent, .play(waveformID: 0))
    XCTAssertEqual(latched.cursorVisibilityIntent, .none)

    let ignoredMovement = machine.handle(.pointerDelta(Vector2(x: 0, y: -20)))
    XCTAssertEqual(ignoredMovement.frame.phase, .latched)
    XCTAssertNil(ignoredMovement.actionToPerform)
    XCTAssertEqual(ignoredMovement.hapticIntent, .none)
    XCTAssertEqual(ignoredMovement.cursorVisibilityIntent, .none)

    let ignoredClick = machine.handle(.primaryClick)
    XCTAssertEqual(ignoredClick.frame.phase, .latched)
    XCTAssertNil(ignoredClick.actionToPerform)

    let committed = machine.handle(.completeCommit)
    XCTAssertEqual(committed.frame.phase, .committed)
    XCTAssertNil(committed.actionToPerform)
    XCTAssertEqual(committed.hapticIntent, .none)
    XCTAssertEqual(committed.cursorVisibilityIntent, .restore)

    let duplicateCompletion = machine.handle(.completeCommit)
    XCTAssertEqual(duplicateCompletion.frame.phase, .committed)
    XCTAssertNil(duplicateCompletion.actionToPerform)
    XCTAssertEqual(duplicateCompletion.cursorVisibilityIntent, .none)
  }

  func testUnknownApplicationKeepsEmptyBottomPlaceholderWithoutTarget() throws {
    var machine = try makeMachine()
    let invocation = machine.handle(
      .panelTrigger(
        origin: .zero,
        frontmostApplication: FrontmostApplicationContext(bundleID: "com.example.Other")
      )
    )
    XCTAssertFalse(invocation.frame.targetVectors.contains { $0.zone == .bottom })
    let bottom = try XCTUnwrap(
      invocation.frame.zoneLayouts.first { $0.zone == .bottom }
    )
    XCTAssertTrue(bottom.actionNames.isEmpty)
    XCTAssertTrue(bottom.isPlaceholder)
  }

  func testResetClearsTerminalStateAndTypedContext() throws {
    var machine = try makeMachine()
    _ = machine.handle(
      .panelTrigger(
        origin: Vector2(x: 10, y: 20),
        frontmostApplication: FrontmostApplicationContext(bundleID: "com.apple.finder")
      )
    )
    _ = machine.handle(.dismiss)

    let reset = machine.handle(.reset)
    XCTAssertEqual(reset.frame.phase, .idle)
    XCTAssertEqual(reset.frame.origin, .zero)
    XCTAssertEqual(reset.frame.frontmostApplication, .unknown)
    XCTAssertEqual(reset.frame.accumulatedPointerDelta, .zero)
    XCTAssertNil(reset.frame.currentTarget)
    XCTAssertEqual(reset.frame.mergeProgress, 0)
  }

  func testEmptyConfigurationNeverHidesCursorButRetainsBottomMetadata() throws {
    var machine = try RingInteractionMachine(
      configuration: MouseConfiguration(),
      profile: profile
    )
    let transition = machine.handle(.panelTriggerAtOrigin())
    XCTAssertEqual(transition.frame.phase, .idle)
    XCTAssertEqual(transition.frame.targetVectors, [])
    XCTAssertEqual(transition.cursorVisibilityIntent, .none)
    XCTAssertEqual(
      transition.frame.zoneLayouts.first(where: { $0.zone == .bottom })?.isPlaceholder,
      true
    )
  }

  func testLegacyInvokeIsUnknownContextPanelToggle() throws {
    var machine = try makeMachine()
    let opened = machine.handle(.invoke(origin: Vector2(x: 1, y: 2)))
    XCTAssertEqual(opened.frame.phase, .invoked)
    XCTAssertEqual(opened.frame.frontmostApplication, .unknown)

    let toggled = machine.handle(.invoke(origin: Vector2(x: 3, y: 4)))
    XCTAssertEqual(toggled.frame.phase, .cancelled)
    XCTAssertEqual(toggled.cursorVisibilityIntent, .restore)
  }

  func testSimulationIsDeterministicAcrossNewInputs() throws {
    let context = FrontmostApplicationContext(bundleID: "com.apple.finder")
    let inputs: [RingInput] = [
      .panelTrigger(origin: .zero, frontmostApplication: context),
      .panelRelease,
      .pointerDelta(Vector2(x: 0, y: 76)),
      .completeCommit,
      .reset,
    ]

    let first = try RingSimulation.run(
      configuration: configuration(),
      profile: profile,
      inputs: inputs
    )
    let second = try RingSimulation.run(
      configuration: configuration(),
      profile: profile,
      inputs: inputs
    )

    XCTAssertEqual(first, second)
    XCTAssertEqual(first[2].frame.phase, .latched)
    XCTAssertEqual(first[2].actionToPerform?.name, "Finder Action")
    XCTAssertEqual(first[2].actionToPerform?.zone, .bottom)
    XCTAssertEqual(first[3].frame.phase, .committed)
    XCTAssertNil(first[3].actionToPerform)
    XCTAssertEqual(first[4].frame.phase, .idle)
  }

  func testNonFiniteMovementIsIgnored() throws {
    var machine = try makeMachine()
    _ = machine.handle(.panelTriggerAtOrigin())
    let transition = machine.handle(.pointerDelta(Vector2(x: .infinity, y: 10)))
    XCTAssertEqual(transition.frame.phase, .invoked)
    XCTAssertEqual(transition.frame.accumulatedPointerDelta, .zero)
  }

  func testProfileRejectsInvalidThresholds() {
    XCTAssertThrowsError(
      try RingInteractionProfile(
        ringRadius: 0,
        targetingDeadZone: 5,
        mergeStartDistance: 50
      )
    )
    XCTAssertThrowsError(
      try RingInteractionProfile(
        ringRadius: 100,
        targetingDeadZone: -1,
        mergeStartDistance: 50
      )
    )
    XCTAssertThrowsError(
      try RingInteractionProfile(
        ringRadius: 100,
        targetingDeadZone: 5,
        mergeStartDistance: 0
      )
    )
    XCTAssertThrowsError(
      try RingInteractionProfile(
        ringRadius: 100,
        targetingDeadZone: 5,
        mergeStartDistance: 50,
        movingBubbleRadius: 0,
        targetBubbleRadius: 28
      )
    )
    XCTAssertThrowsError(
      try RingInteractionProfile(
        ringRadius: 100,
        targetingDeadZone: 5,
        mergeStartDistance: 50,
        movingBubbleRadius: 22.4,
        targetBubbleRadius: 0
      )
    )
    XCTAssertThrowsError(
      try RingInteractionProfile(
        ringRadius: 100,
        targetingDeadZone: 5,
        mergeStartDistance: 50,
        movingBubbleRadius: 29,
        targetBubbleRadius: 28
      )
    )
  }

  private func makeMachine() throws -> RingInteractionMachine {
    try RingInteractionMachine(configuration: configuration(), profile: profile)
  }

  private func configuration() -> MouseConfiguration {
    MouseConfiguration(
      actions: [
        "Spotify": .spotify(SpotifyAction()),
        "Telegram": .application(ApplicationAction(bundleID: "ru.keepcoder.Telegram")),
        "ChatGPT": .shortcut(ShortcutAction(key: "space", modifiers: [.option])),
        "Finder Action": .shortcut(ShortcutAction(key: "f", modifiers: [.command])),
        "Aqua": .shortcut(ShortcutAction(key: "fn", repeatCount: 2)),
      ],
      zones: RingZones(
        top: ["Spotify"],
        right: ["Telegram", "ChatGPT"],
        bottom: [],
        left: ["Aqua"]
      ),
      applicationSpecific: [
        "com.apple.finder": ApplicationSpecificActions(bottom: ["Finder Action"])
      ]
    )
  }
}
