import Foundation
import LogiLiquidControl
import LogiLiquidCore
import XCTest

@testable import LogiLiquidCLI

final class CLIArgumentParserTests: XCTestCase {
  private let defaultSocket = URL(filePath: "/tmp/default.sock")

  func testSimpleCommandsMapToStableControlMethods() throws {
    let parser = makeParser()
    let cases: [([String], CLICommand)] = [
      (["status"], .request(method: .status, params: [:])),
      (["doctor"], .request(method: .doctor, params: [:])),
      (["device", "inspect"], .request(method: .deviceInspect, params: [:])),
      (["events", "follow"], .follow(method: .eventsFollow, params: [:])),
      (["reports", "follow"], .follow(method: .reportsFollow, params: [:])),
      (["actions", "list"], .request(method: .actionsList, params: [:])),
      (["simulate", "complete"], .request(method: .simulateComplete, params: [:])),
      (["simulate", "cancel"], .request(method: .simulateCancel, params: [:])),
    ]

    for (arguments, expectedCommand) in cases {
      let invocation = try parser.parse(arguments: arguments)
      XCTAssertEqual(invocation.socketURL, defaultSocket, "arguments: \(arguments)")
      XCTAssertEqual(invocation.command, expectedCommand, "arguments: \(arguments)")
    }
  }

  func testServiceCommandsAreLocalAndRejectSocketOverride() throws {
    let parser = makeParser()
    for command in ServiceCommand.allCases {
      XCTAssertEqual(
        try parser.parse(arguments: ["service", command.rawValue]).command,
        .service(command)
      )
    }

    XCTAssertThrowsError(
      try parser.parse(
        arguments: ["--socket", "/tmp/ignored.sock", "service", "status"]
      )
    ) { error in
      XCTAssertEqual(
        error as? CLIUsageError,
        CLIUsageError("--socket does not apply to local service commands")
      )
    }
    XCTAssertThrowsError(try parser.parse(arguments: ["service", "enable"]))
  }

  func testSocketOverrideMustPrecedeCommandAndBeAbsolute() throws {
    let parser = makeParser()
    XCTAssertEqual(
      try parser.parse(arguments: ["--socket", "/tmp/custom.sock", "status"]),
      CLIInvocation(
        socketURL: URL(filePath: "/tmp/custom.sock"),
        command: .request(method: .status, params: [:])
      )
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["--socket=/tmp/equals.sock", "doctor"]).socketURL.path,
      "/tmp/equals.sock"
    )
    XCTAssertThrowsError(
      try parser.parse(arguments: ["--socket", "relative.sock", "status"])
    ) { error in
      XCTAssertEqual(
        error as? CLIUsageError,
        CLIUsageError("--socket path must be absolute")
      )
    }
  }

  func testActionCommandsProduceTaggedCoreActionJSON() throws {
    let parser = makeParser()

    XCTAssertEqual(
      try parser.parse(
        arguments: [
          "actions", "put-shortcut", "Search", "space", "--modifiers", "command,shift",
        ]
      ).command,
      .request(
        method: .actionsPut,
        params: [
          "name": "Search",
          "zone": "top",
          "action": [
            "type": "shortcut",
            "key": "space",
            "modifiers": ["command", "shift"],
            "repeatCount": 1,
          ],
        ]
      )
    )
    XCTAssertEqual(
      try parser.parse(
        arguments: ["actions", "put-application", "Mail", "com.apple.mail"]
      ).command,
      .request(
        method: .actionsPut,
        params: [
          "name": "Mail",
          "zone": "top",
          "action": ["type": "application", "bundleID": "com.apple.mail"],
        ]
      )
    )

    XCTAssertEqual(
      try parser.parse(
        arguments: [
          "actions", "put-command", "Build", "/usr/bin/env", "--", "swift", "test", "--quiet",
        ]
      ).command,
      .request(
        method: .actionsPut,
        params: [
          "name": "Build",
          "zone": "top",
          "action": [
            "type": "executable",
            "executable": "/usr/bin/env",
            "argv": ["swift", "test", "--quiet"],
          ],
        ]
      )
    )

    XCTAssertEqual(
      try parser.parse(arguments: ["actions", "remove", "Mail"]).command,
      .request(method: .actionsRemove, params: ["name": "Mail"])
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["actions", "move", "Build", "0"]).command,
      .request(method: .actionsMove, params: ["name": "Build", "index": 0])
    )
  }

  func testActionPlacementRepeatURLAndSpotifyProduceTypedParameters() throws {
    let parser = makeParser()

    XCTAssertEqual(
      try parser.parse(
        arguments: [
          "actions", "put-shortcut", "Aqua Voice", "fn",
          "--press-count", "2", "--zone", "left",
        ]
      ).command,
      .request(
        method: .actionsPut,
        params: [
          "name": "Aqua Voice",
          "zone": "left",
          "action": [
            "type": "shortcut",
            "key": "fn",
            "modifiers": [],
            "repeatCount": 2,
          ],
        ]
      )
    )

    XCTAssertEqual(
      try parser.parse(
        arguments: [
          "actions", "put-url", "CleanShot Capture", "cleanshot://capture-area",
          "--zone=left",
        ]
      ).command,
      .request(
        method: .actionsPut,
        params: [
          "name": "CleanShot Capture",
          "zone": "left",
          "action": ["type": "url", "url": "cleanshot://capture-area"],
        ]
      )
    )

    XCTAssertEqual(
      try parser.parse(
        arguments: ["actions", "put-spotify-play", "Play Spotify", "--zone", "top"]
      ).command,
      .request(
        method: .actionsPut,
        params: [
          "name": "Play Spotify",
          "zone": "top",
          "action": ["type": "spotify", "playback": "play"],
        ]
      )
    )

    XCTAssertEqual(
      try parser.parse(
        arguments: [
          "actions", "put-application", "App Tool", "com.example.tool",
          "--zone", "bottom", "--when-app", "com.apple.dt.Xcode",
        ]
      ).command,
      .request(
        method: .actionsPut,
        params: [
          "name": "App Tool",
          "zone": "bottom",
          "applicationBundleID": "com.apple.dt.Xcode",
          "action": ["type": "application", "bundleID": "com.example.tool"],
        ]
      )
    )
  }

  func testResolvedActionsUseFrontmostOrSuppliedApplication() throws {
    let parser = makeParser()
    XCTAssertEqual(
      try parser.parse(arguments: ["actions", "resolve"]).command,
      .request(method: .actionsResolve, params: [:])
    )
    XCTAssertEqual(
      try parser.parse(
        arguments: ["actions", "resolve", "--app", "com.openai.chat"]
      ).command,
      .request(
        method: .actionsResolve,
        params: ["bundleID": "com.openai.chat"]
      )
    )
  }

  func testScopedMoveIsUnambiguousAndGlobalMoveStaysCompatible() throws {
    let parser = makeParser()
    XCTAssertEqual(
      try parser.parse(
        arguments: [
          "actions", "move", "Context Action", "1", "--zone", "bottom",
          "--when-app", "com.apple.dt.Xcode",
        ]
      ).command,
      .request(
        method: .actionsMove,
        params: [
          "name": "Context Action",
          "index": 1,
          "zone": "bottom",
          "applicationBundleID": "com.apple.dt.Xcode",
        ]
      )
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["actions", "move", "Global", "0"]).command,
      .request(method: .actionsMove, params: ["name": "Global", "index": 0])
    )
  }

  func testScopedRemoveAndClearPreserveExplicitApplicationBottomScope() throws {
    let parser = makeParser()

    XCTAssertEqual(
      try parser.parse(
        arguments: [
          "actions", "remove", "Context Action", "--zone", "bottom",
          "--when-app", "com.apple.dt.Xcode",
        ]
      ).command,
      .request(
        method: .actionsRemove,
        params: [
          "name": "Context Action",
          "zone": "bottom",
          "applicationBundleID": "com.apple.dt.Xcode",
        ]
      )
    )
    XCTAssertEqual(
      try parser.parse(
        arguments: [
          "actions", "clear", "--zone=bottom",
          "--when-app=com.apple.dt.Xcode",
        ]
      ).command,
      .request(
        method: .actionsClear,
        params: [
          "zone": "bottom",
          "applicationBundleID": "com.apple.dt.Xcode",
        ]
      )
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["actions", "remove", "Shared"]).command,
      .request(method: .actionsRemove, params: ["name": "Shared"])
    )
  }

  func testScopedRemoveAndClearRequireCompleteBottomApplicationScope() {
    let parser = makeParser()

    for arguments in [
      ["actions", "remove", "Shared", "--zone", "bottom"],
      ["actions", "remove", "Shared", "--when-app", "com.example.App"],
      [
        "actions", "remove", "Shared", "--zone", "top",
        "--when-app", "com.example.App",
      ],
      ["actions", "clear", "--zone", "bottom"],
      ["actions", "clear", "--when-app", "com.example.App"],
    ] {
      XCTAssertThrowsError(try parser.parse(arguments: arguments))
    }
  }

  func testHapticAndDirectSimulationParametersAreTyped() throws {
    let parser = makeParser()
    XCTAssertEqual(
      try parser.parse(arguments: ["haptic", "play"]).command,
      .request(method: .hapticPlay, params: ["waveformID": 0])
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["haptic", "play", "255"]).command,
      .request(method: .hapticPlay, params: ["waveformID": 255])
    )
    XCTAssertEqual(
      try parser.parse(
        arguments: [
          "simulate", "invoke", "400.5", "300", "--app", "com.openai.chat",
        ]
      ).command,
      .request(
        method: .simulateInvoke,
        params: [
          "origin": ["x": .number(400.5), "y": .number(300)],
          "bundleID": "com.openai.chat",
        ]
      )
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["simulate", "move", "-2", "9.25"]).command,
      .request(
        method: .simulateMove,
        params: ["delta": ["x": .number(-2), "y": .number(9.25)]]
      )
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["simulate", "invoke", "10", "20"]).command,
      .request(
        method: .simulateInvoke,
        params: ["origin": ["x": .number(10), "y": .number(20)]]
      )
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["simulate", "release"]).command,
      .request(method: .simulateRelease, params: [:])
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["simulate", "click"]).command,
      .request(method: .simulateClick, params: [:])
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["simulate", "complete"]).command,
      .request(method: .simulateComplete, params: [:])
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["simulate", "dismiss"]).command,
      .request(method: .simulateDismiss, params: [:])
    )
  }

  func testSimulationPlayAcceptsArrayAndNDJSON() throws {
    let array = Data(
      #"[{"type":"invoke","origin":{"x":10,"y":20}},{"type":"cancel"}]"#.utf8
    )
    let ndjson = Data(
      """
      {"type":"invoke","origin":{"x":10,"y":20}}

      {"type":"pointerDelta","delta":{"x":0,"y":-113}}
      """.utf8
    )
    let parser = CLIArgumentParser(defaultSocketURL: defaultSocket) { path in
      switch path {
      case "array.json": array
      case "scenario.ndjson": ndjson
      default: throw CocoaError(.fileNoSuchFile)
      }
    }

    XCTAssertEqual(
      try parser.parse(arguments: ["simulate", "play", "array.json"]).command,
      .request(
        method: .simulatePlay,
        params: [
          "inputs": [
            ["type": "invoke", "origin": ["x": 10, "y": 20]],
            ["type": "cancel"],
          ]
        ]
      )
    )
    XCTAssertEqual(
      try parser.parse(arguments: ["simulate", "play", "scenario.ndjson"]).command,
      .request(
        method: .simulatePlay,
        params: [
          "inputs": [
            ["type": "invoke", "origin": ["x": 10, "y": 20]],
            ["type": "pointerDelta", "delta": ["x": 0, "y": -113]],
          ]
        ]
      )
    )
  }

  func testSimulationPlayAcceptsClickMenuInputsAndApplicationContext() throws {
    let scenario = Data(
      #"""
      [
        {"type":"panelTrigger","origin":{"x":10,"y":20},"frontmostApplication":{"bundleID":"com.apple.dt.Xcode"}},
        {"type":"panelRelease"},
        {"type":"primaryClick"},
        {"type":"completeCommit"},
        {"type":"dismiss"}
      ]
      """#.utf8
    )
    let parser = CLIArgumentParser(defaultSocketURL: defaultSocket) { path in
      XCTAssertEqual(path, "click-menu.json")
      return scenario
    }

    XCTAssertEqual(
      try parser.parse(arguments: ["simulate", "play", "click-menu.json"]).command,
      .request(
        method: .simulatePlay,
        params: [
          "inputs": [
            [
              "type": "panelTrigger",
              "origin": ["x": 10, "y": 20],
              "frontmostApplication": ["bundleID": "com.apple.dt.Xcode"],
            ],
            ["type": "panelRelease"],
            ["type": "primaryClick"],
            ["type": "completeCommit"],
            ["type": "dismiss"],
          ]
        ]
      )
    )
  }

  func testInvalidValuesFailBeforeConnecting() throws {
    let parser = makeParser()
    let invalidArguments: [[String]] = [
      [],
      ["status", "extra"],
      ["actions", "put-shortcut", "Search", "space", "--modifiers", "command,command"],
      ["actions", "put-command", "Run", "relative"],
      ["actions", "put-command", "Run", "/bin/echo", "unbounded"],
      ["actions", "put-shortcut", "Aqua", "fn", "--press-count", "0"],
      ["actions", "put-shortcut", "Aqua", "fn", "--zone", "middle"],
      [
        "actions", "put-application", "Context", "com.example.Context",
        "--zone", "left", "--when-app", "com.apple.dt.Xcode",
      ],
      ["actions", "put-url", "Site", "relative/path"],
      ["actions", "resolve", "--app", ""],
      ["actions", "resolve", "--frontmost"],
      ["actions", "move", "Search", "-1"],
      ["actions", "move", "Search", "0", "--when-app", "com.example.App"],
      ["haptic", "play", "256"],
      ["simulate", "move", "nan", "1"],
      ["simulate", "invoke", "1", "2", "--app", ""],
      ["simulate", "click", "extra"],
    ]

    for arguments in invalidArguments {
      XCTAssertThrowsError(
        try parser.parse(arguments: arguments),
        "arguments: \(arguments)"
      ) { error in
        XCTAssertNotNil(error as? CLIUsageError)
      }
    }
  }

  private func makeParser() -> CLIArgumentParser {
    CLIArgumentParser(defaultSocketURL: defaultSocket) { _ in
      throw CocoaError(.fileNoSuchFile)
    }
  }
}
