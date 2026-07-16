import Foundation
import XCTest

@testable import LogiLiquidCore

final class ConfigurationTests: XCTestCase {
  func testV2ConfigurationRoundTripsEveryActionTypeAndAllZones() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appending(path: "nested/mouse.json")
    let store = try ConfigurationStore(url: url)
    let configuration = sampleConfiguration()
    try store.save(configuration)

    XCTAssertEqual(try store.load(), configuration)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    XCTAssertEqual(object["version"] as? Int, 2)
    XCTAssertNil(object["ring"])

    let zones = try XCTUnwrap(object["zones"] as? [String: [String]])
    XCTAssertEqual(zones["top"], ["Search"])
    XCTAssertEqual(zones["right"], ["Terminal", "Website"])
    XCTAssertEqual(zones["bottom"], [])
    XCTAssertEqual(zones["left"], ["Notes", "Music"])

    let applications = try XCTUnwrap(
      object["applicationSpecific"] as? [String: [String: [String]]]
    )
    XCTAssertEqual(applications["com.apple.finder"]?["bottom"], ["Finder Action"])

    let actions = try XCTUnwrap(object["actions"] as? [String: [String: Any]])
    XCTAssertEqual(actions["Search"]?["type"] as? String, "shortcut")
    XCTAssertEqual(actions["Search"]?["repeatCount"] as? Int, 2)
    XCTAssertEqual(actions["Terminal"]?["type"] as? String, "application")
    XCTAssertEqual(actions["Notes"]?["type"] as? String, "executable")
    XCTAssertEqual(actions["Website"]?["type"] as? String, "url")
    XCTAssertEqual(actions["Website"]?["url"] as? String, "https://example.com/path")
    XCTAssertEqual(actions["Music"]?["type"] as? String, "spotify")
    XCTAssertEqual(actions["Music"]?["playback"] as? String, "play")
  }

  func testV1RingDecodesAndMigratesToNearestCardinalZones() throws {
    let legacyJSON = """
      {
        "version": 1,
        "actions": {
          "A": {"type":"application","bundleID":"com.example.A"},
          "B": {"type":"application","bundleID":"com.example.B"},
          "C": {"type":"application","bundleID":"com.example.C"},
          "D": {"type":"application","bundleID":"com.example.D"},
          "E": {"type":"application","bundleID":"com.example.E"},
          "F": {"type":"application","bundleID":"com.example.F"}
        },
        "ring": ["A","B","C","D","E","F"]
      }
      """

    let migrated = try JSONDecoder().decode(
      MouseConfiguration.self,
      from: Data(legacyJSON.utf8)
    )
    XCTAssertEqual(migrated.version, MouseConfiguration.currentVersion)
    XCTAssertEqual(migrated.zones.top, ["A"])
    XCTAssertEqual(migrated.zones.right, ["B", "C"])
    XCTAssertEqual(migrated.zones.bottom, ["D"])
    XCTAssertEqual(migrated.zones.left, ["E", "F"])
    XCTAssertEqual(migrated.ring, ["A", "B", "C", "D", "E", "F"])
    XCTAssertNoThrow(try migrated.validate())

    let reencoded =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(migrated)
      ) as? [String: Any]
    XCTAssertEqual(reencoded?["version"] as? Int, 2)
    XCTAssertNotNil(reencoded?["zones"])
    XCTAssertNil(reencoded?["ring"])
  }

  func testApplicationResolutionOverridesOnlyBottomAtInvocation() throws {
    let configuration = sampleConfiguration()
    let finder = FrontmostApplicationContext(
      bundleID: "com.apple.finder",
      localizedName: "Finder"
    )
    let finderResolved = try configuration.resolved(for: finder)
    XCTAssertEqual(finderResolved.context, finder)
    XCTAssertEqual(finderResolved.zones.top, ["Search"])
    XCTAssertEqual(finderResolved.zones.right, ["Terminal", "Website"])
    XCTAssertEqual(finderResolved.zones.bottom, ["Finder Action"])
    XCTAssertEqual(finderResolved.zones.left, ["Notes", "Music"])

    let safariResolved = try configuration.resolved(
      for: FrontmostApplicationContext(bundleID: "com.apple.Safari")
    )
    XCTAssertEqual(safariResolved.zones.bottom, [])

    let unknownResolved = try configuration.resolved(for: .unknown)
    XCTAssertEqual(unknownResolved.zones, configuration.zones)
  }

  func testLogiLiquidDefaultHasRequestedCardinalCountsAndExecutableActionsOnly() throws {
    let configuration = MouseConfiguration.logiLiquidDefault
    XCTAssertNoThrow(try configuration.validate())
    XCTAssertEqual(configuration.zones.top, ["Play Spotify"])
    XCTAssertEqual(
      configuration.zones.right,
      ["Telegram", "ChatGPT Quick Chat"]
    )
    XCTAssertEqual(configuration.zones.bottom, [])
    XCTAssertEqual(
      configuration.zones.left,
      ["Aqua Voice", "CleanShot Capture", "CleanShot Record"]
    )
    XCTAssertTrue(configuration.applicationSpecific.isEmpty)
    XCTAssertEqual(
      configuration.actions["Aqua Voice"],
      .shortcut(ShortcutAction(key: "fn", repeatCount: 2))
    )
    XCTAssertEqual(
      configuration.actions["CleanShot Record"],
      .url(URLAction(url: URL(string: "cleanshot://record-screen")!))
    )
  }

  func testSaveAtomicallyReplacesCompletePreviousConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try ConfigurationStore(url: directory.appending(path: "mouse.json"))
    try store.save(sampleConfiguration())

    let replacement = MouseConfiguration(
      actions: [
        "Browser": .application(ApplicationAction(bundleID: "com.apple.Safari"))
      ],
      zones: RingZones(right: ["Browser"])
    )
    try store.save(replacement)

    XCTAssertEqual(try store.load(), replacement)
    let text = try String(contentsOf: store.url, encoding: .utf8)
    XCTAssertFalse(text.contains("Terminal"))
    XCTAssertTrue(text.hasSuffix("\n"))
  }

  func testStoreRejectsNonFileURL() {
    let url = URL(string: "https://example.com/mouse.json")!
    XCTAssertThrowsError(try ConfigurationStore(url: url)) { error in
      XCTAssertEqual(error as? ConfigurationError, .nonFileURL(url))
    }
  }

  func testUnsupportedVersionIsRejectedOnValidationAndLoad() throws {
    var configuration = sampleConfiguration()
    configuration.version = 99
    assertValidationError(
      configuration,
      equals: .unsupportedVersion(found: 99, supported: 2)
    )

    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "mouse.json")
    try Data(#"{"version":99,"actions":{},"zones":{}}"#.utf8).write(to: url)

    XCTAssertThrowsError(try ConfigurationStore(url: url).load()) { error in
      XCTAssertEqual(
        error as? ConfigurationError,
        .unsupportedVersion(found: 99, supported: 2)
      )
    }
  }

  func testZoneReferencesMustBeUniqueKnownAndFilled() {
    let actions: [String: ConfiguredAction] = [
      "One": .application(ApplicationAction(bundleID: "com.example.One"))
    ]
    assertValidationError(
      MouseConfiguration(actions: actions, zones: RingZones(top: [""])),
      equals: .emptyZoneEntry
    )
    assertValidationError(
      MouseConfiguration(actions: actions, zones: RingZones(top: ["Missing"])),
      equals: .unknownZoneAction("Missing")
    )
    assertValidationError(
      MouseConfiguration(
        actions: actions,
        zones: RingZones(top: ["One"], right: ["One"])
      ),
      equals: .duplicateZoneAction("One")
    )
    assertValidationError(
      MouseConfiguration(
        actions: actions,
        applicationSpecific: [" ": ApplicationSpecificActions(bottom: ["One"])]
      ),
      equals: .invalidApplicationSpecificBundleID(" ")
    )
    assertValidationError(
      MouseConfiguration(
        actions: actions,
        applicationSpecific: [
          "com.example.App": ApplicationSpecificActions(bottom: ["One", "One"])
        ]
      ),
      equals: .duplicateApplicationAction(name: "One", bundleID: "com.example.App")
    )
  }

  func testActionPayloadValidationIncludesNewActionTypes() {
    assertActionError(
      name: "Bad Shortcut",
      action: .shortcut(ShortcutAction(key: " ")),
      equals: .invalidShortcutKey(action: "Bad Shortcut")
    )
    assertActionError(
      name: "Bad Repeat",
      action: .shortcut(ShortcutAction(key: "k", repeatCount: 0)),
      equals: .invalidShortcutRepeatCount(action: "Bad Repeat")
    )
    assertActionError(
      name: "Repeated Modifier",
      action: .shortcut(ShortcutAction(key: "k", modifiers: [.command, .command])),
      equals: .duplicateShortcutModifier(action: "Repeated Modifier", modifier: .command)
    )
    assertActionError(
      name: "Relative Process",
      action: .executable(ExecutableAction(executable: "open")),
      equals: .executablePathMustBeAbsolute(action: "Relative Process")
    )
    assertActionError(
      name: "Relative URL",
      action: .url(URLAction(url: URL(string: "relative/path")!)),
      equals: .urlMustBeAbsolute(action: "Relative URL")
    )
  }

  func testMutationHelpersPlaceMoveAndRemoveGlobalAndApplicationActions() throws {
    var configuration = MouseConfiguration()
    let browser = ConfiguredAction.application(
      ApplicationAction(bundleID: "com.apple.Safari")
    )
    let notes = ConfiguredAction.application(
      ApplicationAction(bundleID: "com.apple.Notes")
    )

    try configuration.putAction(named: "Browser", action: browser, zone: .right)
    try configuration.putAction(named: "Notes", action: notes, zone: .right)
    try configuration.putAction(named: "Browser", action: browser, zone: .right)
    XCTAssertEqual(configuration.zones.right, ["Browser", "Notes"])

    try configuration.moveAction(named: "Notes", in: .right, to: 0)
    XCTAssertEqual(configuration.zones.right, ["Notes", "Browser"])

    try configuration.putAction(named: "Browser", action: browser, zone: .left)
    XCTAssertEqual(configuration.zones.right, ["Notes"])
    XCTAssertEqual(configuration.zones.left, ["Browser"])

    try configuration.putAction(
      named: "Browser",
      action: browser,
      zone: .bottom,
      whenApplication: "com.apple.finder"
    )
    XCTAssertEqual(
      configuration.applicationSpecific["com.apple.finder"]?.bottom,
      ["Browser"]
    )
    XCTAssertThrowsError(
      try configuration.putAction(
        named: "Notes",
        action: notes,
        zone: .top,
        whenApplication: "com.apple.finder"
      )
    ) { error in
      XCTAssertEqual(
        error as? ConfigurationMutationError,
        .applicationSpecificActionsRequireBottomZone(.top)
      )
    }

    XCTAssertTrue(configuration.removeAction(named: "Browser"))
    XCTAssertFalse(configuration.removeAction(named: "Browser"))
    XCTAssertEqual(configuration.zones.left, [])
    XCTAssertEqual(configuration.applicationSpecific["com.apple.finder"]?.bottom, [])
    XCTAssertNoThrow(try configuration.validate())
  }

  func testScopedApplicationRemovalKeepsPayloadAndExplicitEmptyOverride() throws {
    var configuration = MouseConfiguration(
      actions: [
        "Global Bottom": .shortcut(ShortcutAction(key: "g")),
        "Shared": .shortcut(ShortcutAction(key: "s")),
      ],
      zones: RingZones(
        top: ["Shared"],
        bottom: ["Global Bottom"]
      ),
      applicationSpecific: [
        "com.example.editor": ApplicationSpecificActions(bottom: ["Shared"])
      ]
    )

    XCTAssertTrue(
      try configuration.removeActionPlacement(
        named: "Shared",
        from: .bottom,
        whenApplication: "com.example.editor"
      )
    )
    XCTAssertFalse(
      try configuration.removeActionPlacement(
        named: "Shared",
        from: .bottom,
        whenApplication: "com.example.editor"
      )
    )
    XCTAssertNotNil(configuration.actions["Shared"])
    XCTAssertEqual(configuration.zones.top, ["Shared"])
    XCTAssertEqual(configuration.applicationSpecific["com.example.editor"]?.bottom, [])
    XCTAssertEqual(
      try configuration.resolved(
        for: FrontmostApplicationContext(bundleID: "com.example.editor")
      ).zones.bottom,
      []
    )
  }

  func testClearApplicationOverridePreservesSharedActionsAndGlobalPlacements() throws {
    var configuration = MouseConfiguration(
      actions: [
        "Global Bottom": .shortcut(ShortcutAction(key: "g")),
        "Context One": .shortcut(ShortcutAction(key: "1")),
        "Context Two": .shortcut(ShortcutAction(key: "2")),
      ],
      zones: RingZones(bottom: ["Global Bottom"]),
      applicationSpecific: [
        "com.example.editor": ApplicationSpecificActions(
          bottom: ["Context One", "Context Two"]
        )
      ]
    )

    XCTAssertTrue(
      try configuration.clearApplicationOverride(for: "com.example.editor")
    )
    XCTAssertFalse(
      try configuration.clearApplicationOverride(for: "com.example.editor")
    )
    XCTAssertEqual(configuration.applicationSpecific["com.example.editor"]?.bottom, [])
    XCTAssertEqual(configuration.zones.bottom, ["Global Bottom"])
    XCTAssertEqual(
      Set(configuration.actions.keys),
      ["Global Bottom", "Context One", "Context Two"]
    )

    XCTAssertTrue(
      try configuration.clearApplicationOverride(for: "com.example.new")
    )
    XCTAssertEqual(configuration.applicationSpecific["com.example.new"]?.bottom, [])
  }

  private func sampleConfiguration() -> MouseConfiguration {
    MouseConfiguration(
      actions: [
        "Search": .shortcut(
          ShortcutAction(
            key: "space",
            modifiers: [.command],
            repeatCount: 2,
            interTapDelayMilliseconds: 75
          )
        ),
        "Terminal": .application(ApplicationAction(bundleID: "com.apple.Terminal")),
        "Notes": .executable(
          ExecutableAction(executable: "/usr/bin/open", argv: ["-a", "Notes"])
        ),
        "Website": .url(URLAction(url: URL(string: "https://example.com/path")!)),
        "Music": .spotify(SpotifyAction(playback: .play)),
        "Finder Action": .shortcut(ShortcutAction(key: "f", modifiers: [.command])),
      ],
      zones: RingZones(
        top: ["Search"],
        right: ["Terminal", "Website"],
        bottom: [],
        left: ["Notes", "Music"]
      ),
      applicationSpecific: [
        "com.apple.finder": ApplicationSpecificActions(bottom: ["Finder Action"])
      ]
    )
  }

  private func assertActionError(
    name: String,
    action: ConfiguredAction,
    equals expected: ConfigurationError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    assertValidationError(
      MouseConfiguration(actions: [name: action], zones: RingZones(top: [name])),
      equals: expected,
      file: file,
      line: line
    )
  }

  private func assertValidationError(
    _ configuration: MouseConfiguration,
    equals expected: ConfigurationError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try configuration.validate(), file: file, line: line) { error in
      XCTAssertEqual(error as? ConfigurationError, expected, file: file, line: line)
    }
  }
}
