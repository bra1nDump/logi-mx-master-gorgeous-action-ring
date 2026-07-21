import AppKit
import Darwin
import Dispatch
import Foundation
import LogiLiquidControl
import LogiLiquidDaemon

@main
enum LogiLiquidDaemonMain {
  static func main() {
    Darwin.signal(SIGINT, SIG_IGN)
    Darwin.signal(SIGTERM, SIG_IGN)
    do {
      let options = try DaemonLaunchOptions.parse(
        Array(CommandLine.arguments.dropFirst())
      )
      let gate = DaemonSupervisorGate()
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
      let host = try ProductionMouseDaemonFactory.make(
        configurationURL: options.configurationURL,
        socketURL: options.socketURL,
        selectedRegistryID: options.selectedRegistryID,
        terminalDeviceFailureHandler: { message in
          gate.signalDeviceFailure(message)
        },
        wakeHealthProbeSuccessHandler: { generation in
          gate.clearWakeRetry(generation: generation)
        }
      )
      let powerMonitor = SystemPowerMonitor(
        onScreenSleep: { host.coordinator.prepareForScreenSleep() },
        onSystemSleep: { host.coordinator.prepareForSystemSleep() },
        onScreenWake: { host.coordinator.resumeAfterScreenWake() },
        onSystemWake: {
          let generation = gate.signalWake()
          host.coordinator.resumeAfterWake(generation: generation)
        }
      )
      let application = NSApplication.shared
      let processInfo = ProcessInfo.processInfo
      processInfo.disableAutomaticTermination("CommandBloom daemon device service")
      processInfo.disableSuddenTermination()
      // Accessory gives NSWorkspace its documented AppKit event lifecycle while
      // keeping this LaunchAgent out of the Dock, menu bar, and activation flow.
      application.setActivationPolicy(.accessory)
      let applicationDelegate = DaemonApplicationDelegate(gate: gate)
      application.delegate = applicationDelegate
      application.finishLaunching()
      guard powerMonitor.start() else {
        throw MouseDaemonError.restorationFailed(
          "The macOS sleep/wake monitor did not start."
        )
      }

      let outcome = DaemonSupervisionOutcome()
      let supervisor = Thread {
        do {
          try superviseUntilShutdown(host, gate: gate)
          outcome.finish(with: .success(()))
        } catch {
          outcome.finish(with: .failure(error))
        }
        DispatchQueue.main.async {
          if !powerMonitor.stop() {
            DaemonLog.log("sleep/wake monitor shutdown exceeded its lifecycle deadline")
          }
          do {
            try outcome.get()
            Darwin.exit(0)
          } catch {
            DaemonLog.log(error.localizedDescription)
            Darwin.exit(1)
          }
        }
      }
      supervisor.name = "com.logiliquid.controls.daemon.supervisor"
      supervisor.start()
      withExtendedLifetime(applicationDelegate) {
        application.run()
      }
      gate.signalShutdown()
      if !powerMonitor.stop() {
        DaemonLog.log("sleep/wake monitor shutdown exceeded its lifecycle deadline")
      }
      if !outcome.wait(timeout: SystemPowerMonitor.defaultLifecycleTimeout) {
        DaemonLog.log("daemon restoration exceeded its lifecycle deadline")
      }
      throw MouseDaemonError.restorationFailed(
        "The daemon application event loop ended unexpectedly."
      )
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
    try host.server.start()
    defer { host.server.stop() }
    var backoff = DaemonRetryBackoff()
    var lastLoggedFailure: String?
    var announcedActive = false

    supervision: while true {
      do {
        gate.reset()
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
        let retryEvent = gate.wait(timeout: backoff.next())
        if retryEvent == .signal {
          break supervision
        }
        if case .wake = retryEvent {
          backoff.reset()
          _ = gate.consumeWakeRetry()
          DaemonLog.log("system wake detected; retrying the MX Master 4 immediately")
        }
        continue
      }

      if !announcedActive || lastLoggedFailure != nil {
        announcedActive = true
        lastLoggedFailure = nil
        DaemonLog.log("MX Master 4 connected; Sense Panel ring active")
      }
      backoff.reset()

      var event = gate.wait()
      while case .wake = event {
        backoff.reset()
        DaemonLog.log("system wake detected; active HID session remains connected")
        event = gate.wait()
      }
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
        let retryEvent = gate.wait(
          timeout: backoff.next(afterWake: gate.consumeWakeRetry())
        )
        if retryEvent == .signal {
          break supervision
        }
        if case .wake = retryEvent {
          backoff.reset()
          _ = gate.consumeWakeRetry()
          DaemonLog.log("system wake detected; retrying the MX Master 4 immediately")
        }
      case .wake:
        // Consumed by the loop above so a healthy session is never restarted.
        break
      case .timeout:
        break
      }
    }
  }
}

private final class DaemonApplicationDelegate: NSObject, NSApplicationDelegate {
  private let gate: DaemonSupervisorGate

  init(gate: DaemonSupervisorGate) {
    self.gate = gate
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    gate.signalShutdown()
    return .terminateLater
  }
}

private final class DaemonSupervisionOutcome: @unchecked Sendable {
  private let condition = NSCondition()
  private var result: Result<Void, any Error>?

  func finish(with result: Result<Void, any Error>) {
    condition.lock()
    self.result = result
    condition.broadcast()
    condition.unlock()
  }

  func get() throws {
    condition.lock()
    let result = result
    condition.unlock()
    guard let result else {
      throw MouseDaemonError.restorationFailed(
        "The daemon application loop ended before supervision completed."
      )
    }
    try result.get()
  }

  func wait(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(max(timeout, 0))
    condition.lock()
    defer { condition.unlock() }
    while result == nil {
      guard condition.wait(until: deadline) else { return false }
    }
    return true
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
