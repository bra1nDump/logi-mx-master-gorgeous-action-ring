import Foundation
import LogiLiquidControl
import XCTest

@testable import LogiLiquidCLI

final class CLIRunnerTests: XCTestCase {
  func testOneShotCommandWritesStableResponseEnvelope() throws {
    let recorder = OutputRecorder()
    let transport = FakeTransport { request in
      XCTAssertEqual(request.requestID, "request-1")
      XCTAssertEqual(request.method, .status)
      XCTAssertEqual(request.params, [:])
      return .success(
        requestID: request.requestID,
        result: ["state": "ready", "pid": 42]
      )
    }
    var receivedSocketURL: URL?
    let cli = LogiLiquidCLI(
      makeTransport: {
        receivedSocketURL = $0
        return transport
      },
      requestID: { "request-1" },
      io: recorder.io
    )

    XCTAssertEqual(
      cli.run(arguments: ["--socket", "/tmp/test.sock", "status"]),
      .success
    )
    XCTAssertEqual(receivedSocketURL?.path, "/tmp/test.sock")
    XCTAssertEqual(
      recorder.standardOutput,
      #"{"error":null,"requestID":"request-1","result":{"pid":42,"state":"ready"},"schemaVersion":1}"#
        + "\n"
    )
    XCTAssertEqual(recorder.standardError, "")
  }

  func testDaemonErrorIsJSONOnStdoutAndUsesDedicatedExitCode() throws {
    let recorder = OutputRecorder()
    let transport = FakeTransport { request in
      .failure(
        requestID: request.requestID,
        error: ControlWireError(
          code: "no_device",
          message: "MX Master 4 is unavailable",
          data: ["retryable": true]
        )
      )
    }
    let cli = makeCLI(transport: transport, recorder: recorder)

    XCTAssertEqual(cli.run(arguments: ["doctor"]), .daemon)
    XCTAssertEqual(
      recorder.standardOutput,
      #"{"error":{"code":"no_device","data":{"retryable":true},"message":"MX Master 4 is unavailable"},"requestID":"fixed-request","result":null,"schemaVersion":1}"#
        + "\n"
    )
    XCTAssertEqual(
      recorder.standardError,
      "daemon error [no_device]: MX Master 4 is unavailable\n"
    )
  }

  func testTransportErrorsNeverPolluteJSONStdout() throws {
    let recorder = OutputRecorder()
    let transport = FakeTransport { _ in
      throw ControlTransportError.systemCall(operation: "connect", code: 61)
    }
    let cli = makeCLI(transport: transport, recorder: recorder)

    XCTAssertEqual(cli.run(arguments: ["status"]), .transport)
    XCTAssertEqual(recorder.standardOutput, "")
    XCTAssertEqual(
      recorder.standardError,
      "transport error: connect failed with errno 61\n"
    )
  }

  func testFollowWritesOnlyControlEventNDJSONAndSuppressesAcknowledgement() throws {
    let recorder = OutputRecorder()
    let stream = FakeEventStream(events: [
      ControlEvent(
        requestID: "fixed-request",
        event: "ring.invoked",
        payload: ["source": "simulation"]
      ),
      ControlEvent(
        requestID: "fixed-request",
        event: "ring.committed",
        payload: ["action": "Search"]
      ),
    ])
    let transport = FakeTransport(
      request: { _ in
        XCTFail("unexpected one-shot request")
        return .success(requestID: "", result: .null)
      },
      subscribe: { request in
        XCTAssertEqual(request.method, .eventsFollow)
        XCTAssertEqual(request.requestID, "fixed-request")
        return stream
      }
    )
    let cli = makeCLI(transport: transport, recorder: recorder)

    XCTAssertEqual(cli.run(arguments: ["events", "follow"]), .success)
    XCTAssertEqual(
      recorder.standardOutput,
      #"{"event":"ring.invoked","payload":{"source":"simulation"},"requestID":"fixed-request","schemaVersion":1}"#
        + "\n"
        + #"{"event":"ring.committed","payload":{"action":"Search"},"requestID":"fixed-request","schemaVersion":1}"#
        + "\n"
    )
    XCTAssertEqual(recorder.standardError, "")
  }

  func testFollowWireErrorUsesDaemonExitCode() throws {
    let recorder = OutputRecorder()
    let transport = FakeTransport(
      request: { _ in
        XCTFail("unexpected one-shot request")
        return .success(requestID: "", result: .null)
      },
      subscribe: { _ in
        throw ControlWireError(code: "busy", message: "already following")
      }
    )
    let cli = makeCLI(transport: transport, recorder: recorder)

    XCTAssertEqual(cli.run(arguments: ["reports", "follow"]), .daemon)
    XCTAssertEqual(recorder.standardOutput, "")
    XCTAssertEqual(recorder.standardError, "daemon error [busy]: already following\n")
  }

  func testUsageErrorDoesNotConstructTransport() throws {
    let recorder = OutputRecorder()
    var constructedTransport = false
    let cli = LogiLiquidCLI(
      makeTransport: { _ in
        constructedTransport = true
        return FakeTransport { _ in
          .success(requestID: "unexpected", result: .null)
        }
      },
      requestID: { "fixed-request" },
      io: recorder.io
    )

    XCTAssertEqual(cli.run(arguments: ["haptic", "play", "999"]), .usage)
    XCTAssertFalse(constructedTransport)
    XCTAssertEqual(recorder.standardOutput, "")
    XCTAssertTrue(recorder.standardError.hasPrefix("error: haptic waveform ID"))
    XCTAssertTrue(recorder.standardError.contains("usage: logi-liquid"))
  }

  func testHelpDoesNotConstructTransport() throws {
    let recorder = OutputRecorder()
    var constructedTransport = false
    let cli = LogiLiquidCLI(
      makeTransport: { _ in
        constructedTransport = true
        return FakeTransport { _ in
          .success(requestID: "unexpected", result: .null)
        }
      },
      io: recorder.io
    )

    XCTAssertEqual(cli.run(arguments: ["--help"]), .success)
    XCTAssertFalse(constructedTransport)
    XCTAssertTrue(recorder.standardOutput.hasPrefix("usage: logi-liquid"))
    XCTAssertEqual(recorder.standardError, "")
  }

  private func makeCLI(
    transport: FakeTransport,
    recorder: OutputRecorder
  ) -> LogiLiquidCLI {
    LogiLiquidCLI(
      makeTransport: { _ in transport },
      requestID: { "fixed-request" },
      io: recorder.io
    )
  }
}

private final class FakeEventStream: CLIControlEventStream {
  private var events: [ControlEvent]

  init(events: [ControlEvent]) {
    self.events = events
  }

  func next() throws -> ControlEvent? {
    guard !events.isEmpty else { return nil }
    return events.removeFirst()
  }
}

private final class FakeTransport: CLIControlTransport {
  typealias RequestHandler = (ControlRequest) throws -> ControlResponse
  typealias SubscribeHandler = (ControlRequest) throws -> any CLIControlEventStream

  private let requestHandler: RequestHandler
  private let subscribeHandler: SubscribeHandler

  init(
    request: @escaping RequestHandler,
    subscribe: @escaping SubscribeHandler = { _ in FakeEventStream(events: []) }
  ) {
    requestHandler = request
    subscribeHandler = subscribe
  }

  func request(_ request: ControlRequest) throws -> ControlResponse {
    try requestHandler(request)
  }

  func subscribe(_ request: ControlRequest) throws -> any CLIControlEventStream {
    try subscribeHandler(request)
  }
}

private final class OutputRecorder {
  private(set) var standardOutput = ""
  private(set) var standardError = ""

  var io: CLIIO {
    CLIIO(
      writeStandardOutput: { [weak self] in
        self?.standardOutput += String(decoding: $0, as: UTF8.self)
      },
      writeStandardError: { [weak self] in
        self?.standardError += String(decoding: $0, as: UTF8.self)
      }
    )
  }
}
