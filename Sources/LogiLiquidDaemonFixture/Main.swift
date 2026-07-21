import Darwin
import Dispatch
import Foundation
import LogiLiquidControl
import LogiLiquidCore
import LogiLiquidDaemon
import LogiLiquidHID
import LogiLiquidService

@main
enum LogiLiquidDaemonFixtureMain {
  static func main() {
    do {
      let options = try FixtureLaunchOptions.parse(
        Array(CommandLine.arguments.dropFirst())
      )
      let repository = try PrivateMouseConfigurationRepository(
        url: options.configurationURL
      )
      let backend = FixtureHIDBackend()
      let events = MouseDaemonEventHub()
      let runtime = MouseRuntime(
        configurationLoader: repository,
        hidController: backend,
        eventPublisher: events,
        cursorPositionProvider: FixtureCursorPositionProvider(),
        actionExecutor: FixtureActionExecutor(events: events)
      )
      let coordinator = MouseDaemonCoordinator(
        configurationRepository: repository,
        runtime: runtime,
        hidBackend: backend,
        eventHub: events
      )
      let host = MouseDaemonControlHost(
        coordinator: coordinator,
        eventHub: events,
        socketURL: options.socketURL
      )
      try runUntilTerminated(host)
    } catch {
      FileHandle.standardError.write(
        Data("logi-liquid-daemon-fixture: \(error.localizedDescription)\n".utf8)
      )
      Darwin.exit(1)
    }
  }

  private static func runUntilTerminated(_ host: MouseDaemonControlHost) throws {
    let termination = DispatchSemaphore(value: 0)
    Darwin.signal(SIGINT, SIG_IGN)
    Darwin.signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interrupt.setEventHandler { termination.signal() }
    terminate.setEventHandler { termination.signal() }
    interrupt.resume()
    terminate.resume()

    try host.start()
    termination.wait()
    try host.stop()

    interrupt.cancel()
    terminate.cancel()
  }
}

private final class FixtureHIDBackend: MouseDaemonHIDBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var active = false

  var isActive: Bool {
    lock.withLock { active }
  }

  var lastFailureDescription: String? { nil }

  func start(
    eventHandler _: @escaping @Sendable (MouseDaemonHIDEvent) -> Void
  ) throws {
    lock.withLock { active = true }
  }

  func stop() throws {
    lock.withLock { active = false }
  }

  func inspect() throws -> MouseDeviceInspection {
    let control = try ReprogrammableControlsV4.parseControlInfo(
      from: HIDPPPacket(
        featureIndex: 0x0D,
        functionID: 0x01,
        parameters: [
          0x01, 0xA0,
          0x00, 0x00,
          0x31,
          0x00, 0x00, 0x00,
          0x05,
        ]
      ),
      index: 0
    )
    return MouseDeviceInspection(
      registryID: 42,
      vendorID: LogitechHIDDevice.logitechVendorID,
      productID: LogitechHIDDevice.mxMaster4ProductID,
      product: "MX Master 4 (gym fixture)",
      transport: "Bluetooth Low Energy",
      isMXMaster4DirectBluetooth: true,
      supportsHIDPPLongReports: true,
      protocolMajor: 4,
      protocolMinor: 5,
      pingEchoMatched: true,
      features: [
        MouseHIDFeatureInspection(
          id: HIDPPFeatureID.reprogrammableControlsV4.rawValue,
          runtimeIndex: 0x0D,
          version: 4
        ),
        MouseHIDFeatureInspection(
          id: HIDPPFeatureID.hapticFeedback.rawValue,
          runtimeIndex: 0x0B,
          version: 1
        ),
      ],
      sensePanelControl: control,
      sensePanelReporting: ControlReportingState(
        controlID: ReprogrammableControlsV4.sensePanelControlID,
        diverted: isActive,
        persistentlyDiverted: false,
        rawXY: isActive,
        forceRawXY: false,
        remappedTo: nil,
        analyticsKeyEvents: false,
        rawWheel: false
      ),
      diversionActive: isActive
    )
  }

  func requestHealthProbe(generation _: UInt64) {}

  func suspendInputForSleep() {}

  func resumeInputAfterSleep() {}

  func playHaptic(waveformID _: UInt8) throws {}
}

private struct FixtureCursorPositionProvider: CursorPositionProviding, Sendable {
  func currentPosition() throws -> Vector2 {
    Vector2(x: 0, y: 0)
  }
}

private struct FixtureActionExecutor: ActionExecuting, Sendable {
  let events: MouseDaemonEventHub

  func execute(_ invocation: ActionInvocation) throws {
    events.publish(
      stream: .events,
      event: "fixture.action.executed",
      payload: try MouseDaemonJSON.encode(invocation)
    )
  }
}

private struct FixtureLaunchOptions {
  let configurationURL: URL
  let socketURL: URL

  static func parse(_ arguments: [String]) throws -> Self {
    var configurationURL: URL?
    var socketURL: URL?
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--foreground":
        index += 1
      case "--config", "--socket":
        guard index + 1 < arguments.count else {
          throw FixtureLaunchError.missingValue(argument)
        }
        let value = arguments[index + 1]
        guard value.hasPrefix("/"), !value.contains("\0") else {
          throw FixtureLaunchError.invalidPath(option: argument, path: value)
        }
        let url = URL(filePath: value, directoryHint: .notDirectory)
        if argument == "--config" {
          configurationURL = url
        } else {
          socketURL = url
        }
        index += 2
      default:
        throw FixtureLaunchError.unknownArgument(argument)
      }
    }
    guard let configurationURL else {
      throw FixtureLaunchError.missingOption("--config")
    }
    guard let socketURL else {
      throw FixtureLaunchError.missingOption("--socket")
    }
    return Self(configurationURL: configurationURL, socketURL: socketURL)
  }
}

private enum FixtureLaunchError: LocalizedError {
  case unknownArgument(String)
  case missingValue(String)
  case invalidPath(option: String, path: String)
  case missingOption(String)

  var errorDescription: String? {
    switch self {
    case .unknownArgument(let argument):
      "Unknown argument \(argument.debugDescription)."
    case .missingValue(let option):
      "\(option) requires a value."
    case .invalidPath(let option, let path):
      "Invalid path \(path.debugDescription) for \(option)."
    case .missingOption(let option):
      "Required option \(option) is missing."
    }
  }
}
