import LogiLiquidCore
import XCTest

@testable import LogiLiquidUI

final class OverlayTargetPresentationTests: XCTestCase {
  func testKnownDefaultsResolveToPurposeBuiltSymbols() {
    let expectations: [String: String] = [
      "Play Spotify": "play.fill",
      "Telegram": "paperplane.fill",
      "Twitter": "bird.fill",
      "ChatGPT Quick Chat": "text.bubble.fill",
      "Aqua Voice": "waveform",
      "CleanShot Capture": "camera.viewfinder",
      "CleanShot Record": "record.circle",
      "Mission Control": "rectangle.3.group",
    ]
    for (name, symbol) in expectations {
      let presentation = OverlayTargetSymbols.presentation(forActionNamed: name)
      XCTAssertEqual(presentation.symbolName, symbol, "symbol for \(name)")
      XCTAssertEqual(presentation.label, name, "label for \(name)")
      XCTAssertTrue(presentation.isKnownDefault, "\(name) should be a known default")
    }
  }

  func testEveryShippedDefaultActionHasAKnownSymbol() {
    // Guard: the default layout must never render as generic sparkles.
    let defaults = MouseConfiguration.logiLiquidDefault
    for name in defaults.actions.keys {
      let presentation = OverlayTargetSymbols.presentation(forActionNamed: name)
      XCTAssertTrue(
        presentation.isKnownDefault,
        "default action \(name) unexpectedly resolved to the generic symbol"
      )
      XCTAssertNotEqual(presentation.symbolName, OverlayTargetSymbols.genericSymbol)
    }
  }

  func testChatGPTUsesBundledTemplateMarkWithDeterministicFallback() {
    let presentation = OverlayTargetSymbols.presentation(
      forActionNamed: "ChatGPT Quick Chat"
    )
    XCTAssertEqual(
      presentation.icon,
      .bundledTemplate(
        resourceName: "OpenAIChatGPTMark",
        fallbackSymbol: "text.bubble.fill"
      )
    )
    XCTAssertEqual(presentation.symbolName, "text.bubble.fill")
  }

  func testTwitterUsesBundledBirdMarkWithDeterministicFallback() {
    let presentation = OverlayTargetSymbols.presentation(forActionNamed: "Twitter")
    XCTAssertEqual(
      presentation.icon,
      .bundledTemplate(
        resourceName: "TwitterBirdMark",
        fallbackSymbol: "bird.fill"
      )
    )
    XCTAssertEqual(presentation.symbolName, "bird.fill")
  }

  func testAquaVoiceUsesBundledStaticBarsWithDeterministicFallback() {
    let presentation = OverlayTargetSymbols.presentation(forActionNamed: "Aqua Voice")
    XCTAssertEqual(
      presentation.icon,
      .bundledTemplate(
        resourceName: "AquaVoiceBarsMark",
        fallbackSymbol: "waveform"
      )
    )
    XCTAssertEqual(presentation.symbolName, "waveform")
  }

  func testAgentConfiguredActionsGetTheGenericSymbol() {
    let presentation = OverlayTargetSymbols.presentation(forActionNamed: "Xcode Build")
    XCTAssertEqual(presentation.symbolName, OverlayTargetSymbols.genericSymbol)
    XCTAssertEqual(presentation.label, "Xcode Build")
    XCTAssertFalse(presentation.isKnownDefault)
  }
}
