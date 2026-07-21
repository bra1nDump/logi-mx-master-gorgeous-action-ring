import Foundation
import XCTest

@testable import LogiLiquidCore

final class SerializationTests: XCTestCase {
  func testRingInputsUseStableTaggedJSONAndRoundTrip() throws {
    let context = FrontmostApplicationContext(
      bundleID: "com.apple.finder",
      localizedName: "Finder"
    )
    let inputs: [RingInput] = [
      .invoke(origin: Vector2(x: 12.5, y: 24.5)),
      .panelTrigger(
        origin: Vector2(x: 1, y: 2),
        frontmostApplication: context
      ),
      .panelRelease,
      .pointerDelta(Vector2(x: -3, y: 7)),
      .primaryClick,
      .completeCommit,
      .escape,
      .dismiss,
      .cancel,
      .reset,
    ]

    let json = try inputs.map(encodeSorted)
    XCTAssertEqual(json[0], #"{"origin":{"x":12.5,"y":24.5},"type":"invoke"}"#)
    XCTAssertEqual(
      json[1],
      #"{"frontmostApplication":{"bundleID":"com.apple.finder","localizedName":"Finder"},"origin":{"x":1,"y":2},"type":"panelTrigger"}"#
    )
    XCTAssertEqual(json[2], #"{"type":"panelRelease"}"#)
    XCTAssertEqual(json[3], #"{"delta":{"x":-3,"y":7},"type":"pointerDelta"}"#)
    XCTAssertEqual(json[4], #"{"type":"primaryClick"}"#)
    XCTAssertEqual(json[5], #"{"type":"completeCommit"}"#)
    XCTAssertEqual(json[6], #"{"type":"escape"}"#)
    XCTAssertEqual(json[7], #"{"type":"dismiss"}"#)
    XCTAssertEqual(json[8], #"{"type":"cancel"}"#)
    XCTAssertEqual(json[9], #"{"type":"reset"}"#)

    let decoder = JSONDecoder()
    for (input, line) in zip(inputs, json) {
      XCTAssertEqual(
        try decoder.decode(RingInput.self, from: Data(line.utf8)),
        input
      )
    }
  }

  func testPanelTriggerDecoderDefaultsMissingContextToUnknown() throws {
    let line = #"{"origin":{"x":0,"y":0},"type":"panelTrigger"}"#
    XCTAssertEqual(
      try JSONDecoder().decode(RingInput.self, from: Data(line.utf8)),
      .panelTrigger(origin: .zero, frontmostApplication: .unknown)
    )
  }

  func testLegacyShortcutPayloadDefaultsNewRepeatFields() throws {
    let line = #"{"type":"shortcut","key":"space","modifiers":["option"]}"#
    XCTAssertEqual(
      try JSONDecoder().decode(ConfiguredAction.self, from: Data(line.utf8)),
      .shortcut(
        ShortcutAction(
          key: "space",
          modifiers: [.option],
          repeatCount: 1,
          interTapDelayMilliseconds: nil
        )
      )
    )
  }

  func testNewActionsUseStableTaggedJSONAndRoundTrip() throws {
    let actions: [ConfiguredAction] = [
      .url(URLAction(url: URL(string: "cleanshot://capture-area")!)),
      .spotify(SpotifyAction(playback: .play)),
      .shortcut(
        ShortcutAction(
          key: "fn",
          repeatCount: 2,
          interTapDelayMilliseconds: 120
        )
      ),
    ]
    let lines = try actions.map(encodeSorted)
    XCTAssertEqual(lines[0], #"{"type":"url","url":"cleanshot://capture-area"}"#)
    XCTAssertEqual(lines[1], #"{"playback":"play","type":"spotify"}"#)
    XCTAssertEqual(
      lines[2],
      #"{"interTapDelayMilliseconds":120,"key":"fn","modifiers":[],"repeatCount":2,"type":"shortcut"}"#
    )

    for (action, line) in zip(actions, lines) {
      XCTAssertEqual(
        try JSONDecoder().decode(ConfiguredAction.self, from: Data(line.utf8)),
        action
      )
    }
  }

  func testHapticIntentsUseStableTaggedJSONAndRoundTrip() throws {
    let intents: [HapticIntent] = [.none, .play(waveformID: 0), .play(waveformID: 255)]
    let json = try intents.map(encodeSorted)
    XCTAssertEqual(json[0], #"{"type":"none"}"#)
    XCTAssertEqual(json[1], #"{"type":"play","waveformID":0}"#)
    XCTAssertEqual(json[2], #"{"type":"play","waveformID":255}"#)

    let decoder = JSONDecoder()
    for (intent, line) in zip(intents, json) {
      XCTAssertEqual(
        try decoder.decode(HapticIntent.self, from: Data(line.utf8)),
        intent
      )
    }
  }

  func testTransitionIncludesContextZoneMetadataAndRoundTripsAsNDJSON() throws {
    let context = FrontmostApplicationContext(
      bundleID: "com.apple.finder",
      localizedName: "Finder"
    )
    let transitions = try RingSimulation.run(
      configuration: MouseConfiguration.logiLiquidDefault,
      inputs: [
        .panelTrigger(
          origin: Vector2(x: 400, y: 300),
          frontmostApplication: context
        )
      ]
    )
    let transition = try XCTUnwrap(transitions.first)

    let line = try encodeSorted(transition)
    XCTAssertFalse(line.contains("\n"))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    )
    XCTAssertEqual(object["cursorVisibilityIntent"] as? String, "hide")
    XCTAssertTrue(object["actionToPerform"] is NSNull)
    let frame = try XCTUnwrap(object["frame"] as? [String: Any])
    XCTAssertEqual(frame["phase"] as? String, "invoked")
    XCTAssertTrue(frame["currentTarget"] is NSNull)
    let application = try XCTUnwrap(
      frame["frontmostApplication"] as? [String: Any]
    )
    XCTAssertEqual(application["bundleID"] as? String, "com.apple.finder")
    let targets = try XCTUnwrap(frame["targetVectors"] as? [[String: Any]])
    XCTAssertEqual(targets.first?["zone"] as? String, "right")
    let zoneLayouts = try XCTUnwrap(frame["zoneLayouts"] as? [[String: Any]])
    let top = try XCTUnwrap(zoneLayouts.first { $0["zone"] as? String == "top" })
    XCTAssertEqual(top["actionNames"] as? [String], [])
    let bottom = try XCTUnwrap(zoneLayouts.first { $0["zone"] as? String == "bottom" })
    XCTAssertEqual(bottom["isPlaceholder"] as? Bool, false)

    XCTAssertEqual(
      try JSONDecoder().decode(RingTransition.self, from: Data(line.utf8)),
      transition
    )
  }

  private func encodeSorted<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try String(decoding: encoder.encode(value), as: UTF8.self)
  }
}
