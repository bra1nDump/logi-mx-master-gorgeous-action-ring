import ApplicationServices
import Foundation
import LogiLiquidCore
import XCTest

@testable import LogiLiquidService

final class SystemActionExecutorTests: XCTestCase {
  private let executor = SystemActionExecutor()

  func testValidatesSupportedShortcutNamesWithoutPromptingOrPosting() {
    for key in ["space", "A", "f12", "left", "/"] {
      XCTAssertNoThrow(
        try executor.validate(
          ActionInvocation(
            name: key,
            action: .shortcut(
              ShortcutAction(key: key, modifiers: [.command, .shift])
            )
          )
        )
      )
    }
  }

  func testRejectsUnsupportedShortcutBeforeAccessibilityCheck() {
    XCTAssertThrowsError(
      try executor.execute(
        ActionInvocation(
          name: "Bad shortcut",
          action: .shortcut(ShortcutAction(key: "not-a-real-key"))
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? SystemActionExecutorError,
        .unsupportedShortcutKey("not-a-real-key")
      )
    }
  }

  func testValidatesInstalledApplicationByBundleID() {
    XCTAssertNoThrow(
      try executor.validate(
        ActionInvocation(
          name: "Finder",
          action: .application(ApplicationAction(bundleID: "com.apple.finder"))
        )
      )
    )
  }

  func testRejectsInvalidOrMissingApplicationBundleID() {
    XCTAssertThrowsError(
      try executor.validate(
        ActionInvocation(
          name: "Empty",
          action: .application(ApplicationAction(bundleID: ""))
        )
      )
    ) { error in
      XCTAssertEqual(error as? SystemActionExecutorError, .invalidApplicationBundleID)
    }

    let missing = "dev.logiliquid.test.missing-\(UUID().uuidString)"
    XCTAssertThrowsError(
      try executor.validate(
        ActionInvocation(
          name: "Missing",
          action: .application(ApplicationAction(bundleID: missing))
        )
      )
    ) { error in
      XCTAssertEqual(error as? SystemActionExecutorError, .applicationNotFound(missing))
    }
  }

  func testValidatesDirectExecutableAndArgv() {
    XCTAssertNoThrow(
      try executor.validate(
        ActionInvocation(
          name: "True",
          action: .executable(
            ExecutableAction(executable: "/usr/bin/true", argv: ["one", "two words"])
          )
        )
      )
    )
  }

  func testRejectsRelativeMissingNonExecutableAndInvalidArgv() throws {
    assertExecutableError(
      ExecutableAction(executable: "usr/bin/true"),
      equals: .executablePathMustBeAbsolute("usr/bin/true")
    )
    assertExecutableError(
      ExecutableAction(executable: "/definitely/missing/logi-liquid"),
      equals: .executableNotFound("/definitely/missing/logi-liquid")
    )
    assertExecutableError(
      ExecutableAction(executable: "/usr/bin/true", argv: ["bad\0argument"]),
      equals: .invalidExecutableArgument
    )

    let file = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("not executable".utf8).write(to: file)
    assertExecutableError(
      ExecutableAction(executable: file.path),
      equals: .executableNotRunnable(file.path)
    )
  }

  func testAccessibilityStatusCheckIsNonprompting() {
    _ = executor.isAccessibilityTrusted
  }

  func testAquaVoiceDoubleRightOptionUsesKeyCode61AndConfiguredDelay() throws {
    let system = RecordingActionSystem()
    let executor = SystemActionExecutor(system: system)

    try executor.execute(
      ActionInvocation(
        name: "Aqua Voice",
        action: .shortcut(
          ShortcutAction(
            key: "rightoption",
            repeatCount: 2,
            interTapDelayMilliseconds: 75
          )
        )
      )
    )

    XCTAssertEqual(system.keyStrokes.map(\.keyCode), [61, 61])
    XCTAssertEqual(system.keyStrokes.map(\.flags), [0, 0])
    XCTAssertEqual(system.waits, [75])
  }

  func testControlUpShortcutUsesExpectedKeyCodeAndFlags() throws {
    let system = RecordingActionSystem()
    let executor = SystemActionExecutor(system: system)

    try executor.execute(
      ActionInvocation(
        name: "Control Up",
        action: .shortcut(ShortcutAction(key: "up", modifiers: [.control]))
      )
    )

    XCTAssertEqual(system.keyStrokes.map(\.keyCode), [126])
    XCTAssertEqual(system.keyStrokes.map(\.flags), [CGEventFlags.maskControl.rawValue])
  }

  func testModifierKeyTapSetsThenClearsItsOwnFlag() {
    XCTAssertEqual(
      MacOSActionExecutorSystem.flagsByApplying(keyCode: 58, pressed: true, to: []),
      .maskAlternate
    )
    XCTAssertEqual(
      MacOSActionExecutorSystem.flagsByApplying(keyCode: 58, pressed: false, to: .maskAlternate),
      []
    )
    // An explicit modifier in the shortcut stays held across the tap.
    XCTAssertEqual(
      MacOSActionExecutorSystem.flagsByApplying(
        keyCode: 61,
        pressed: false,
        to: [.maskAlternate, .maskShift]
      ),
      .maskShift
    )
    // Non-modifier keys pass flags through untouched.
    XCTAssertEqual(
      MacOSActionExecutorSystem.flagsByApplying(keyCode: 49, pressed: true, to: .maskAlternate),
      .maskAlternate
    )
  }

  func testRepeatedShortcutUsesShortDefaultDelay() throws {
    let system = RecordingActionSystem()
    let executor = SystemActionExecutor(system: system)

    try executor.execute(
      ActionInvocation(
        name: "Double tap",
        action: .shortcut(ShortcutAction(key: "fn", repeatCount: 2))
      )
    )

    XCTAssertEqual(system.waits, [80])
  }

  func testCleanShotCaptureAndRecordingURLsValidateWithoutOpeningThenExecute() throws {
    let system = RecordingActionSystem()
    system.handledURLSchemes = ["cleanshot"]
    let executor = SystemActionExecutor(system: system)
    let capture = ActionInvocation(
      name: "Take screenshot",
      action: .url(URLAction(url: URL(string: "cleanshot://capture-area")!))
    )
    let record = ActionInvocation(
      name: "Record demo video",
      action: .url(URLAction(url: URL(string: "cleanshot://record-screen")!))
    )

    try executor.validate(capture)
    try executor.validate(record)
    XCTAssertTrue(system.openedURLs.isEmpty)

    try executor.execute(capture)
    try executor.execute(record)
    XCTAssertEqual(
      system.openedURLs.map(\.absoluteString),
      ["cleanshot://capture-area", "cleanshot://record-screen"]
    )
  }

  func testURLActionRejectsSchemeWithoutInstalledHandler() {
    let system = RecordingActionSystem()
    let executor = SystemActionExecutor(system: system)

    XCTAssertThrowsError(
      try executor.validate(
        ActionInvocation(
          name: "Missing handler",
          action: .url(URLAction(url: URL(string: "not-installed://action")!))
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? SystemActionExecutorError,
        .urlHandlerNotFound("not-installed")
      )
    }
  }

  func testSpotifyPlayLaunchesSpotifyIfNeededThenSendsDocumentedAppleEvent() throws {
    let system = RecordingActionSystem()
    system.applicationURLs["com.spotify.client"] = URL(
      fileURLWithPath: "/Applications/Spotify.app"
    )
    let executor = SystemActionExecutor(system: system)
    let play = ActionInvocation(
      name: "Play Spotify",
      action: .spotify(SpotifyAction(playback: .play))
    )

    try executor.validate(play)
    XCTAssertTrue(system.openedApplications.isEmpty)
    XCTAssertTrue(system.appleEvents.isEmpty)

    try executor.execute(play)
    XCTAssertEqual(
      system.openedApplications,
      [URL(fileURLWithPath: "/Applications/Spotify.app")]
    )
    XCTAssertEqual(system.appleEvents.count, 1)
    XCTAssertEqual(system.appleEvents[0].bundleIdentifier, "com.spotify.client")
    XCTAssertEqual(system.appleEvents[0].eventClass, 0x7370_6679)
    XCTAssertEqual(system.appleEvents[0].eventID, 0x506C_6179)
  }

  func testSpotifyPlayDoesNotRelaunchRunningSpotify() throws {
    let system = RecordingActionSystem()
    system.applicationURLs["com.spotify.client"] = URL(
      fileURLWithPath: "/Applications/Spotify.app"
    )
    system.runningBundleIdentifiers = ["com.spotify.client"]
    let executor = SystemActionExecutor(system: system)

    try executor.execute(
      ActionInvocation(
        name: "Play Spotify",
        action: .spotify(SpotifyAction())
      )
    )

    XCTAssertTrue(system.openedApplications.isEmpty)
    XCTAssertEqual(system.appleEvents.count, 1)
  }

  func testSpotifyPlayWaitsForLaunchAndFailsWithoutSendingWhenItNeverRuns() {
    let system = RecordingActionSystem()
    system.applicationURLs["com.spotify.client"] = URL(
      fileURLWithPath: "/Applications/Spotify.app"
    )
    system.automaticallyStartsApplications = false
    let executor = SystemActionExecutor(system: system)

    XCTAssertThrowsError(
      try executor.execute(
        ActionInvocation(
          name: "Play Spotify",
          action: .spotify(SpotifyAction())
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? SystemActionExecutorError,
        .applicationLaunchTimedOut("com.spotify.client")
      )
    }
    XCTAssertEqual(system.waits, Array(repeating: 100, count: 50))
    XCTAssertTrue(system.appleEvents.isEmpty)
  }

  func testChatGPTQuickBarAndTelegramUseShortcutAndApplicationBoundaries() throws {
    let system = RecordingActionSystem()
    system.applicationURLs["ru.keepcoder.Telegram"] = URL(
      fileURLWithPath: "/Applications/Telegram.app"
    )
    let executor = SystemActionExecutor(system: system)

    try executor.execute(
      ActionInvocation(
        name: "ChatGPT Quick Chat",
        action: .shortcut(
          ShortcutAction(key: "space", modifiers: [.option])
        )
      )
    )
    try executor.execute(
      ActionInvocation(
        name: "Telegram",
        action: .application(
          ApplicationAction(bundleID: "ru.keepcoder.Telegram")
        )
      )
    )

    XCTAssertEqual(system.keyStrokes.map(\.keyCode), [49])
    XCTAssertEqual(
      system.keyStrokes.map(\.flags),
      [CGEventFlags.maskAlternate.rawValue]
    )
    XCTAssertEqual(
      system.openedApplications,
      [URL(fileURLWithPath: "/Applications/Telegram.app")]
    )
  }

  private func assertExecutableError(
    _ executable: ExecutableAction,
    equals expected: SystemActionExecutorError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try executor.validate(
        ActionInvocation(name: "Process", action: .executable(executable))
      ),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? SystemActionExecutorError,
        expected,
        file: file,
        line: line
      )
    }
  }
}

private final class RecordingActionSystem: SystemActionExecutorSystem, @unchecked Sendable {
  struct KeyStroke {
    let keyCode: CGKeyCode
    let flags: UInt64
  }

  struct AppleEvent {
    let bundleIdentifier: String
    let eventClass: AEEventClass
    let eventID: AEEventID
  }

  var isAccessibilityTrusted = true
  var applicationURLs: [String: URL] = [:]
  var handledURLSchemes: Set<String> = []
  var runningBundleIdentifiers: Set<String> = []
  var openedApplications: [URL] = []
  var openedURLs: [URL] = []
  var keyStrokes: [KeyStroke] = []
  var waits: [Int] = []
  var launchedExecutables: [ExecutableAction] = []
  var appleEvents: [AppleEvent] = []
  var automaticallyStartsApplications = true

  func applicationURL(bundleIdentifier: String) -> URL? {
    applicationURLs[bundleIdentifier]
  }

  func applicationURL(toOpen url: URL) -> URL? {
    guard let scheme = url.scheme, handledURLSchemes.contains(scheme) else {
      return nil
    }
    return URL(fileURLWithPath: "/Applications/URL Handler.app")
  }

  func isApplicationRunning(bundleIdentifier: String) -> Bool {
    runningBundleIdentifiers.contains(bundleIdentifier)
  }

  func openApplication(at url: URL) {
    openedApplications.append(url)
    if automaticallyStartsApplications,
      let bundleIdentifier = applicationURLs.first(where: { $0.value == url })?.key
    {
      runningBundleIdentifiers.insert(bundleIdentifier)
    }
  }

  func open(_ url: URL) -> Bool {
    openedURLs.append(url)
    return true
  }

  func postKeyStroke(keyCode: CGKeyCode, flags: CGEventFlags) throws {
    keyStrokes.append(KeyStroke(keyCode: keyCode, flags: flags.rawValue))
  }

  func wait(milliseconds: Int) {
    waits.append(milliseconds)
  }

  func fileExists(atPath path: String) -> Bool {
    true
  }

  func isExecutableFile(atPath path: String) -> Bool {
    true
  }

  func launch(executable: ExecutableAction) throws {
    launchedExecutables.append(executable)
  }

  func sendAppleEvent(
    bundleIdentifier: String,
    eventClass: AEEventClass,
    eventID: AEEventID
  ) throws {
    appleEvents.append(
      AppleEvent(
        bundleIdentifier: bundleIdentifier,
        eventClass: eventClass,
        eventID: eventID
      )
    )
  }
}
