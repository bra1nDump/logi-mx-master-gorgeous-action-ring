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
      let gate = DaemonSupervisorGate()
      let host = try ProductionMouseDaemonFactory.make(
        configurationURL: options.configurationURL,
        socketURL: options.socketURL,
        selectedRegistryID: options.selectedRegistryID,
        terminalDeviceFailureHandler: { message in
          gate.signalDeviceFailure(message)
        }
      )
      try superviseUntilShutdown(host, gate: gate)
    } catch {
      DaemonLog.log(error.localizedDescription)
      Darwin.exit(1)
    }
  }

  /// Keeps one daemon process alive across mouse disconnects, sleep/wake, and
  /// half-awake Bluetooth reconnects. The control socket stays up throughout
  /// so `status` and the overlay keep working while the device is away;
  /// only the device session is torn down and retried. `KeepAlive` in the
  /// LaunchAgent remains the safety net for crashes and genuinely fatal
  /// errors, which still exit.
  private static func superviseUntilShutdown(
    _ host: MouseDaemonControlHost,
    gate: DaemonSupervisorGate
  ) throws {
    Darwin.signal(SIGINT, SIG_IGN)
    Darwin.signal(SIGTERM, SIG_IGN)

    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interrupt.setEventHandler { gate.signalShutdown() }
    terminate.setEventHandler { gate.signalShutdown() }
    interrupt.resume()
    terminate.resume()
    defer {
      interrupt.cancel()
      terminate.cancel()
    }

    try host.server.start()
    defer { host.server.stop() }

    var backoff = DaemonRetryBackoff()
    var lastLoggedFailure: String?
    var announcedActive = false

    supervision: while true {
      do {
        try host.coordinator.start()
      } catch let error as MouseDaemonError where error.preventsAutomaticDeviceRecovery {
        throw error
      } catch {
        // Device absent or not ready yet. Log transitions, not every retry.
        let message = error.localizedDescription
        if message != lastLoggedFailure {
          lastLoggedFailure = message
          DaemonLog.log("waiting for the MX Master 4: \(message)")
        }
        gate.reset()
        if gate.wait(timeout: backoff.next()) == .signal {
          break supervision
        }
        continue
      }

      if !announcedActive || lastLoggedFailure != nil {
        announcedActive = true
        lastLoggedFailure = nil
        DaemonLog.log("MX Master 4 connected; Sense Panel ring active")
      }
      backoff.reset()

      let event = gate.wait()
      // `stop()` waits for the HID backend's event loop to restore the exact
      // pre-diversion state (when the device is still reachable) before the
      // session is considered over.
      do {
        try host.coordinator.stop()
      } catch {
        DaemonLog.log(
          "could not restore the Sense Panel state (\(error.localizedDescription)); "
            + "the recovery journal restores it on reconnect"
        )
      }

      switch event {
      case .signal:
        break supervision
      case .deviceFailure(let message):
        DaemonLog.log("device session ended: \(message); reconnecting")
        lastLoggedFailure = message
        gate.reset()
        if gate.wait(timeout: backoff.next()) == .signal {
          break supervision
        }
      case .timeout:
        break
      }
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
