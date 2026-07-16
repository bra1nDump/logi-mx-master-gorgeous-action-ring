import LogiLiquidCore
import XCTest

@testable import LogiLiquidUI

final class OverlayTargetPresentationTests: XCTestCase {
  func testKnownDefaultsResolveToPurposeBuiltSymbols() {
    let expectations: [String: String] = [
      "Play Spotify": "play.fill",
      "Telegram": "paperplane.fill",
      "ChatGPT Quick Chat": "text.bubble.fill",
      "Aqua Voice": "mic.fill",
      "CleanShot Capture": "camera.viewfinder",
      "CleanShot Record": "record.circle",
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

  func testAgentConfiguredActionsGetTheGenericSymbol() {
    let presentation = OverlayTargetSymbols.presentation(forActionNamed: "Xcode Build")
    XCTAssertEqual(presentation.symbolName, OverlayTargetSymbols.genericSymbol)
    XCTAssertEqual(presentation.label, "Xcode Build")
    XCTAssertFalse(presentation.isKnownDefault)
  }
}
