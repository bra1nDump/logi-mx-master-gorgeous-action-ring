import Foundation
import LogiLiquidControl
import LogiLiquidCore
import LogiLiquidDaemon
import XCTest

final class MouseDaemonControlHostTests: XCTestCase {
  func testUnixHostStreamsTransitionNDJSONAndRemovesSocketOnStop() throws {
    var configuration = MouseConfiguration()
    try configuration.putAction(
      named: "terminal",
      action: .application(ApplicationAction(bundleID: "com.apple.Terminal"))
    )
    let fixture = makeTestCoordinator(configuration: configuration)
    let directory = URL(
      fileURLWithPath: "/tmp/rmd-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let socketURL = directory.appending(path: "control.sock")
    let host = MouseDaemonControlHost(
      coordinator: fixture.coordinator,
      eventHub: fixture.events,
      socketURL: socketURL
    )
    try host.start()

    let client = UnixControlClient(socketURL: socketURL)
    let subscription = try client.subscribe(
      ControlRequest(requestID: "events", method: .eventsFollow)
    )
    let response = try client.request(
      ControlRequest(
        requestID: "invoke",
        method: .simulateInvoke,
        params: .object([
          "origin": .object(["x": .number(10), "y": .number(20)])
        ])
      )
    )
    XCTAssertNil(response.error)

    let event = try XCTUnwrap(subscription.next())
    XCTAssertEqual(event.requestID, "events")
    XCTAssertEqual(event.event, "ring.transition")
    let transition = try MouseDaemonJSON.decode(
      RingTransition.self,
      from: event.payload
    )
    XCTAssertEqual(transition.frame.phase, .invoked)

    try host.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
  }
}
