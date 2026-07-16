import Foundation
import LogiLiquidControl
import XCTest

@testable import LogiLiquidCLI

final class ServiceCLIRunnerTests: XCTestCase {
  func testServiceCommandBypassesSocketTransportAndWritesJSON() throws {
    let recorder = ServiceOutputRecorder()
    let controller = StubServiceController { command in
      XCTAssertEqual(command, .status)
      return ServiceLifecycleResult(
        operation: command,
        installed: true,
        loaded: false,
        daemonLoaded: true,
        overlayLoaded: false,
        daemonExecutablePath:
          "/Users/tester/Library/Application Support/Logi Liquid Controls/bin/logi-liquid-daemon",
        overlayExecutablePath:
          "/Users/tester/Library/Application Support/Logi Liquid Controls/bin/logi-liquid-overlay",
        launchAgentPath: "/Users/tester/Library/LaunchAgents/com.logiliquid.controls.daemon.plist",
        overlayLaunchAgentPath:
          "/Users/tester/Library/LaunchAgents/com.logiliquid.controls.overlay.plist",
        configurationPath:
          "/Users/tester/Library/Application Support/Logi Liquid Controls/config.json",
        socketPath: "/Users/tester/.logi-liquid-controls/run/mouse-control.sock",
        logsPath: "/Users/tester/Library/Application Support/Logi Liquid Controls/logs"
      )
    }
    var transportConstructed = false
    let cli = LogiLiquidCLI(
      makeTransport: { _ in
        transportConstructed = true
        return UnusedServiceCLITransport()
      },
      io: recorder.io,
      serviceLifecycle: controller
    )

    XCTAssertEqual(cli.run(arguments: ["service", "status"]), .success)
    XCTAssertFalse(transportConstructed)
    XCTAssertEqual(
      recorder.standardOutput,
      #"{"configurationPath":"/Users/tester/Library/Application Support/Logi Liquid Controls/config.json","daemonExecutablePath":"/Users/tester/Library/Application Support/Logi Liquid Controls/bin/logi-liquid-daemon","daemonLoaded":true,"installed":true,"label":"com.logiliquid.controls.daemon","launchAgentPath":"/Users/tester/Library/LaunchAgents/com.logiliquid.controls.daemon.plist","loaded":false,"logsPath":"/Users/tester/Library/Application Support/Logi Liquid Controls/logs","operation":"status","overlayExecutablePath":"/Users/tester/Library/Application Support/Logi Liquid Controls/bin/logi-liquid-overlay","overlayLabel":"com.logiliquid.controls.overlay","overlayLaunchAgentPath":"/Users/tester/Library/LaunchAgents/com.logiliquid.controls.overlay.plist","overlayLoaded":false,"schemaVersion":2,"socketPath":"/Users/tester/.logi-liquid-controls/run/mouse-control.sock"}"#
        + "\n"
    )
    XCTAssertEqual(recorder.standardError, "")
  }

  func testServiceFailureHasDedicatedExitCodeAndNoStdout() throws {
    let recorder = ServiceOutputRecorder()
    let controller = StubServiceController { _ in
      throw ServiceLifecycleError.notInstalled("/missing/service.plist")
    }
    let cli = LogiLiquidCLI(
      makeTransport: { _ in UnusedServiceCLITransport() },
      io: recorder.io,
      serviceLifecycle: controller
    )

    XCTAssertEqual(cli.run(arguments: ["service", "start"]), .service)
    XCTAssertEqual(recorder.standardOutput, "")
    XCTAssertEqual(
      recorder.standardError,
      "service error [not_installed]: Mouse service is not installed; expected /missing/service.plist.\n"
    )
  }
}

private final class StubServiceController: ServiceLifecycleControlling {
  private let handler: (ServiceCommand) throws -> ServiceLifecycleResult

  init(handler: @escaping (ServiceCommand) throws -> ServiceLifecycleResult) {
    self.handler = handler
  }

  func perform(_ command: ServiceCommand) throws -> ServiceLifecycleResult {
    try handler(command)
  }
}

private final class UnusedServiceCLITransport: CLIControlTransport {
  func request(_ request: ControlRequest) throws -> ControlResponse {
    XCTFail("service command must not make a socket request")
    return .success(requestID: request.requestID, result: .null)
  }

  func subscribe(_ request: ControlRequest) throws -> any CLIControlEventStream {
    throw ControlTransportError.notAStreamingMethod(request.method)
  }
}

private final class ServiceOutputRecorder {
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
