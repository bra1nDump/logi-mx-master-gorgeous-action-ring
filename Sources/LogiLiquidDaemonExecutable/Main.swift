import Darwin
import Dispatch
import Foundation
import LogiLiquidControl
import LogiLiquidDaemon

@main
enum LogiLiquidDaemonMain {
  static func main() {
    do {
      let options = try DaemonLaunchOptions.parse(
        Array(CommandLine.arguments.dropFirst())
      )
      let termination = DaemonTerminationGate()
      let host = try ProductionMouseDaemonFactory.make(
        configurationURL: options.configurationURL,
        socketURL: options.socketURL,
        selectedRegistryID: options.selectedRegistryID,
        terminalDeviceFailureHandler: { message in
          termination.signal(.deviceFailure(message))
        }
      )
      try runUntilTerminated(host, termination: termination)
    } catch {
      FileHandle.standardError.write(
        Data("logi-liquid-daemon: \(error.localizedDescription)\n".utf8)
      )
      Darwin.exit(1)
    }
  }

  private static func runUntilTerminated(
    _ host: MouseDaemonControlHost,
    termination: DaemonTerminationGate
  ) throws {
    Darwin.signal(SIGINT, SIG_IGN)
    Darwin.signal(SIGTERM, SIG_IGN)

    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interrupt.setEventHandler { termination.signal(.signal) }
    terminate.setEventHandler { termination.signal(.signal) }
    interrupt.resume()
    terminate.resume()
    defer {
      interrupt.cancel()
      terminate.cancel()
    }

    try host.start()
    let reason = termination.wait()
    // `stop()` waits for the HID backend's event loop to restore the exact
    // pre-diversion state before this process is allowed to exit.
    try host.stop()

    if case .deviceFailure(let message) = reason {
      throw DaemonRuntimeError.deviceTerminated(message)
    }
  }
}

private enum DaemonTerminationReason: Sendable {
  case signal
  case deviceFailure(String)
}

private final class DaemonTerminationGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var reason: DaemonTerminationReason?

  func signal(_ reason: DaemonTerminationReason) {
    condition.lock()
    if self.reason == nil {
      self.reason = reason
      condition.broadcast()
    }
    condition.unlock()
  }

  func wait() -> DaemonTerminationReason {
    condition.lock()
    while reason == nil {
      condition.wait()
    }
    let result = reason!
    condition.unlock()
    return result
  }
}

private enum DaemonRuntimeError: LocalizedError {
  case deviceTerminated(String)

  var errorDescription: String? {
    switch self {
    case .deviceTerminated(let message):
      "The MX Master 4 HID session terminated: \(message)"
    }
  }
}

private struct DaemonLaunchOptions {
  let configurationURL: URL
  let socketURL: URL
  let selectedRegistryID: UInt64?

  static func parse(_ arguments: [String]) throws -> Self {
    var configurationURL = ProductionMouseDaemonFactory.defaultConfigurationURL
    var socketURL = LogiLiquidControlProtocol.defaultSocketURL
    var selectedRegistryID: UInt64?
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--foreground":
        index += 1
      case "--config":
        configurationURL = try absoluteFileURL(
          value(after: argument, at: index, in: arguments),
          option: argument
        )
        index += 2
      case "--socket":
        socketURL = try absoluteFileURL(
          value(after: argument, at: index, in: arguments),
          option: argument
        )
        index += 2
      case "--registry-id":
        let rawValue = try value(after: argument, at: index, in: arguments)
        guard let value = UInt64(rawValue) else {
          throw LaunchError.invalidValue(option: argument, value: rawValue)
        }
        selectedRegistryID = value
        index += 2
      default:
        throw LaunchError.unknownArgument(argument)
      }
    }

    return Self(
      configurationURL: configurationURL,
      socketURL: socketURL,
      selectedRegistryID: selectedRegistryID
    )
  }

  private static func value(
    after option: String,
    at index: Int,
    in arguments: [String]
  ) throws -> String {
    guard index + 1 < arguments.count else {
      throw LaunchError.missingValue(option)
    }
    return arguments[index + 1]
  }

  private static func absoluteFileURL(_ value: String, option: String) throws -> URL {
    guard value.hasPrefix("/"), !value.contains("\0") else {
      throw LaunchError.invalidValue(option: option, value: value)
    }
    return URL(filePath: value, directoryHint: .notDirectory)
  }
}

private enum LaunchError: LocalizedError {
  case unknownArgument(String)
  case missingValue(String)
  case invalidValue(option: String, value: String)

  var errorDescription: String? {
    switch self {
    case .unknownArgument(let argument):
      "Unknown argument \(argument.debugDescription)."
    case .missingValue(let option):
      "\(option) requires a value."
    case .invalidValue(let option, let value):
      "Invalid value \(value.debugDescription) for \(option)."
    }
  }
}
