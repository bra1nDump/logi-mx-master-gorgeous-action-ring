import Darwin
import Foundation

public enum ServiceCommand: String, Codable, CaseIterable, Equatable {
  case install
  case start
  case stop
  case restart
  case status
  case uninstall
}

public struct ServiceLifecyclePaths: Equatable {
  public static let label = "com.logiliquid.controls.daemon"
  public static let overlayLabel = "com.logiliquid.controls.overlay"
  public static let uiResourceBundleName = "CommandBloom_LogiLiquidUI.bundle"

  public let homeDirectory: URL
  public let sourceDaemonURL: URL
  public let sourceOverlayURL: URL
  public let sourceUIResourceBundleURL: URL
  public let applicationSupportDirectory: URL
  public let binDirectory: URL
  public let installedDaemonURL: URL
  public let installedOverlayURL: URL
  public let installedUIResourceBundleURL: URL
  public let logsDirectory: URL
  public let configurationURL: URL
  public let socketURL: URL
  public let launchAgentsDirectory: URL
  public let launchAgentURL: URL
  public let overlayLaunchAgentURL: URL
  public let launchctlURL: URL
  public let userID: uid_t

  public var launchdDomain: String { "gui/\(userID)" }
  public var launchdTarget: String { "\(launchdDomain)/\(Self.label)" }
  public var overlayLaunchdTarget: String { "\(launchdDomain)/\(Self.overlayLabel)" }

  public init(
    homeDirectory: URL,
    sourceDaemonURL: URL,
    userID: uid_t,
    launchctlURL: URL = URL(filePath: "/bin/launchctl")
  ) {
    self.homeDirectory = homeDirectory
    self.sourceDaemonURL = sourceDaemonURL
    sourceOverlayURL =
      sourceDaemonURL
      .deletingLastPathComponent()
      .appending(path: "logi-liquid-overlay", directoryHint: .notDirectory)
    sourceUIResourceBundleURL =
      sourceDaemonURL
      .deletingLastPathComponent()
      .appending(path: Self.uiResourceBundleName, directoryHint: .isDirectory)
    applicationSupportDirectory =
      homeDirectory
      .appending(
        path: "Library/Application Support/Logi Liquid Controls", directoryHint: .isDirectory)
    binDirectory =
      applicationSupportDirectory
      .appending(path: "bin", directoryHint: .isDirectory)
    installedDaemonURL =
      binDirectory
      .appending(path: "logi-liquid-daemon", directoryHint: .notDirectory)
    installedOverlayURL =
      binDirectory
      .appending(path: "logi-liquid-overlay", directoryHint: .notDirectory)
    installedUIResourceBundleURL =
      binDirectory
      .appending(path: Self.uiResourceBundleName, directoryHint: .isDirectory)
    logsDirectory =
      applicationSupportDirectory
      .appending(path: "logs", directoryHint: .isDirectory)
    configurationURL =
      applicationSupportDirectory
      .appending(path: "config.json", directoryHint: .notDirectory)
    socketURL =
      homeDirectory
      .appending(path: ".logi-liquid-controls/run/mouse-control.sock", directoryHint: .notDirectory)
    launchAgentsDirectory =
      homeDirectory
      .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
    launchAgentURL =
      launchAgentsDirectory
      .appending(path: "\(Self.label).plist", directoryHint: .notDirectory)
    overlayLaunchAgentURL =
      launchAgentsDirectory
      .appending(path: "\(Self.overlayLabel).plist", directoryHint: .notDirectory)
    self.launchctlURL = launchctlURL
    self.userID = userID
  }

  public static var live: ServiceLifecyclePaths {
    let currentExecutable =
      Bundle.main.executableURL
      ?? URL(filePath: CommandLine.arguments[0]).standardizedFileURL
    return ServiceLifecyclePaths(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      sourceDaemonURL: currentExecutable.deletingLastPathComponent()
        .appending(path: "logi-liquid-daemon", directoryHint: .notDirectory),
      userID: getuid()
    )
  }
}

public struct ServiceLifecycleResult: Codable, Equatable {
  public static let currentSchemaVersion = 2

  public let schemaVersion: Int
  public let operation: ServiceCommand
  public let label: String
  public let overlayLabel: String
  public let installed: Bool
  public let loaded: Bool
  public let daemonLoaded: Bool
  public let overlayLoaded: Bool
  public let daemonExecutablePath: String
  public let overlayExecutablePath: String
  public let launchAgentPath: String
  public let overlayLaunchAgentPath: String
  public let configurationPath: String
  public let socketPath: String
  public let logsPath: String

  public init(
    schemaVersion: Int = ServiceLifecycleResult.currentSchemaVersion,
    operation: ServiceCommand,
    label: String = ServiceLifecyclePaths.label,
    overlayLabel: String = ServiceLifecyclePaths.overlayLabel,
    installed: Bool,
    loaded: Bool,
    daemonLoaded: Bool,
    overlayLoaded: Bool,
    daemonExecutablePath: String,
    overlayExecutablePath: String,
    launchAgentPath: String,
    overlayLaunchAgentPath: String,
    configurationPath: String,
    socketPath: String,
    logsPath: String
  ) {
    self.schemaVersion = schemaVersion
    self.operation = operation
    self.label = label
    self.overlayLabel = overlayLabel
    self.installed = installed
    self.loaded = loaded
    self.daemonLoaded = daemonLoaded
    self.overlayLoaded = overlayLoaded
    self.daemonExecutablePath = daemonExecutablePath
    self.overlayExecutablePath = overlayExecutablePath
    self.launchAgentPath = launchAgentPath
    self.overlayLaunchAgentPath = overlayLaunchAgentPath
    self.configurationPath = configurationPath
    self.socketPath = socketPath
    self.logsPath = logsPath
  }
}

public enum ServiceLifecycleError: Error, Equatable, LocalizedError {
  case daemonExecutableMissing(String)
  case overlayExecutableMissing(String)
  case overlayResourceBundleMissing(String)
  case notInstalled(String)
  case fileSystem(operation: String, message: String)
  case process(operation: String, message: String)
  case launchctl(arguments: [String], status: Int32, output: String)
  case launchdTransitionTimedOut(target: String, timeout: TimeInterval)

  public var code: String {
    switch self {
    case .daemonExecutableMissing: "daemon_executable_missing"
    case .overlayExecutableMissing: "overlay_executable_missing"
    case .overlayResourceBundleMissing: "overlay_resource_bundle_missing"
    case .notInstalled: "not_installed"
    case .fileSystem: "filesystem_failed"
    case .process: "process_failed"
    case .launchctl: "launchctl_failed"
    case .launchdTransitionTimedOut: "launchd_transition_timed_out"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .daemonExecutableMissing(let path):
      return "Sibling logi-liquid-daemon executable is missing or not executable at \(path)."
    case .overlayExecutableMissing(let path):
      return "Sibling logi-liquid-overlay executable is missing or not executable at \(path)."
    case .overlayResourceBundleMissing(let path):
      return "Sibling CommandBloom UI resource bundle is missing at \(path)."
    case .notInstalled(let path):
      return "Mouse service is not installed; expected \(path)."
    case .fileSystem(let operation, let message):
      return "\(operation) failed: \(message)"
    case .process(let operation, let message):
      return "\(operation) failed: \(message)"
    case .launchctl(let arguments, let status, let output):
      let command = (["/bin/launchctl"] + arguments).joined(separator: " ")
      let suffix = output.isEmpty ? "" : ": \(output)"
      return "\(command) exited with status \(status)\(suffix)"
    case .launchdTransitionTimedOut(let target, let timeout):
      return
        "launchd still reported \(target) after waiting \(timeout) seconds for bootout."
    }
  }
}

public protocol ServiceLifecycleControlling {
  func perform(_ command: ServiceCommand) throws -> ServiceLifecycleResult
}

public protocol ServiceFileSystem {
  func itemExists(at url: URL) -> Bool
  func isExecutableFile(at url: URL) -> Bool
  func ensureDirectory(at url: URL, permissions: Int) throws
  func copyExecutableAtomically(from sourceURL: URL, to destinationURL: URL) throws
  func copyDirectoryAtomically(from sourceURL: URL, to destinationURL: URL) throws
  func writeAtomically(_ data: Data, to destinationURL: URL, permissions: Int) throws
  func removeItemIfExists(at url: URL) throws
}

public struct ServiceProcessResult: Equatable {
  public let terminationStatus: Int32
  public let output: String

  public init(terminationStatus: Int32, output: String = "") {
    self.terminationStatus = terminationStatus
    self.output = output
  }
}

public protocol ServiceProcessRunning {
  func run(executableURL: URL, arguments: [String]) throws -> ServiceProcessResult
}

protocol ServiceLifecycleTiming {
  var monotonicTime: TimeInterval { get }
  func wait(for interval: TimeInterval)
}

private struct LiveServiceLifecycleTiming: ServiceLifecycleTiming {
  var monotonicTime: TimeInterval { ProcessInfo.processInfo.systemUptime }

  func wait(for interval: TimeInterval) {
    Thread.sleep(forTimeInterval: interval)
  }
}

public final class LocalServiceFileSystem: ServiceFileSystem {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func itemExists(at url: URL) -> Bool {
    fileManager.fileExists(atPath: url.path)
  }

  public func isExecutableFile(at url: URL) -> Bool {
    fileManager.isExecutableFile(atPath: url.path)
  }

  public func ensureDirectory(at url: URL, permissions: Int) throws {
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: permissions]
    )
    try fileManager.setAttributes(
      [.posixPermissions: permissions],
      ofItemAtPath: url.path
    )
  }

  public func copyExecutableAtomically(from sourceURL: URL, to destinationURL: URL) throws {
    let temporaryURL = temporarySibling(of: destinationURL)
    defer { try? fileManager.removeItem(at: temporaryURL) }

    try fileManager.copyItem(at: sourceURL, to: temporaryURL)
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: temporaryURL.path
    )
    try renameReplacing(source: temporaryURL, destination: destinationURL)
  }

  public func copyDirectoryAtomically(from sourceURL: URL, to destinationURL: URL) throws {
    let temporaryURL = temporarySibling(of: destinationURL)
    defer { try? fileManager.removeItem(at: temporaryURL) }

    try fileManager.copyItem(at: sourceURL, to: temporaryURL)
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: temporaryURL.path
    )
    if fileManager.fileExists(atPath: destinationURL.path) {
      guard Darwin.renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_SWAP)) == 0
      else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } else {
      try renameReplacing(source: temporaryURL, destination: destinationURL)
    }
  }

  public func writeAtomically(_ data: Data, to destinationURL: URL, permissions: Int) throws {
    let temporaryURL = temporarySibling(of: destinationURL)
    defer { try? fileManager.removeItem(at: temporaryURL) }

    try data.write(to: temporaryURL, options: .withoutOverwriting)
    try fileManager.setAttributes(
      [.posixPermissions: permissions],
      ofItemAtPath: temporaryURL.path
    )
    try renameReplacing(source: temporaryURL, destination: destinationURL)
  }

  public func removeItemIfExists(at url: URL) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private func temporarySibling(of destinationURL: URL) -> URL {
    destinationURL.deletingLastPathComponent().appending(
      path: ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
      directoryHint: .notDirectory
    )
  }

  private func renameReplacing(source: URL, destination: URL) throws {
    guard Darwin.rename(source.path, destination.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}

public final class FoundationServiceProcessRunner: ServiceProcessRunning {
  public init() {}

  public func run(executableURL: URL, arguments: [String]) throws -> ServiceProcessResult {
    let process = Process()
    let combinedOutput = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = combinedOutput
    process.standardError = combinedOutput

    try process.run()
    let data = combinedOutput.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ServiceProcessResult(
      terminationStatus: process.terminationStatus,
      output: String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}

public final class ServiceLifecycleController: ServiceLifecycleControlling {
  static let launchdTransitionTimeout: TimeInterval = 15
  private static let initialLaunchdPollInterval: TimeInterval = 0.05
  private static let maximumLaunchdPollInterval: TimeInterval = 0.5

  /// One launchd job managed by the lifecycle. The daemon and overlay are
  /// installed, started, and removed together; permissions stay tied only to
  /// the daemon binary.
  private struct ManagedAgent {
    let sourceURL: URL
    let installedURL: URL
    let agentURL: URL
    let launchdTarget: String
  }

  private let paths: ServiceLifecyclePaths
  private let fileSystem: any ServiceFileSystem
  private let processRunner: any ServiceProcessRunning
  private let timing: any ServiceLifecycleTiming

  public convenience init(
    paths: ServiceLifecyclePaths = .live,
    fileSystem: any ServiceFileSystem = LocalServiceFileSystem(),
    processRunner: any ServiceProcessRunning = FoundationServiceProcessRunner()
  ) {
    self.init(
      paths: paths,
      fileSystem: fileSystem,
      processRunner: processRunner,
      timing: LiveServiceLifecycleTiming()
    )
  }

  init(
    paths: ServiceLifecyclePaths,
    fileSystem: any ServiceFileSystem,
    processRunner: any ServiceProcessRunning,
    timing: any ServiceLifecycleTiming
  ) {
    self.paths = paths
    self.fileSystem = fileSystem
    self.processRunner = processRunner
    self.timing = timing
  }

  private var daemonAgent: ManagedAgent {
    ManagedAgent(
      sourceURL: paths.sourceDaemonURL,
      installedURL: paths.installedDaemonURL,
      agentURL: paths.launchAgentURL,
      launchdTarget: paths.launchdTarget
    )
  }

  private var overlayAgent: ManagedAgent {
    ManagedAgent(
      sourceURL: paths.sourceOverlayURL,
      installedURL: paths.installedOverlayURL,
      agentURL: paths.overlayLaunchAgentURL,
      launchdTarget: paths.overlayLaunchdTarget
    )
  }

  private var agents: [ManagedAgent] { [daemonAgent, overlayAgent] }

  public func perform(_ command: ServiceCommand) throws -> ServiceLifecycleResult {
    do {
      switch command {
      case .install:
        return try install()
      case .start, .restart:
        try requireInstalled()
        for agent in agents {
          if try !isLoaded(agent) {
            try runLaunchctl(["bootstrap", paths.launchdDomain, agent.agentURL.path])
          }
          try runLaunchctl(["kickstart", "-k", agent.launchdTarget])
        }
        return result(for: command, installed: true, daemonLoaded: true, overlayLoaded: true)
      case .stop:
        for agent in agents {
          try bootOutIfLoaded(agent)
        }
        return result(
          for: command, installed: isInstalled, daemonLoaded: false, overlayLoaded: false)
      case .status:
        return try result(
          for: command,
          installed: isInstalled,
          daemonLoaded: isLoaded(daemonAgent),
          overlayLoaded: isLoaded(overlayAgent)
        )
      case .uninstall:
        for agent in agents {
          try bootOutIfLoaded(agent)
        }
        for agent in agents {
          try fileSystem.removeItemIfExists(at: agent.agentURL)
          try fileSystem.removeItemIfExists(at: agent.installedURL)
        }
        try fileSystem.removeItemIfExists(at: paths.installedUIResourceBundleURL)
        return result(for: command, installed: false, daemonLoaded: false, overlayLoaded: false)
      }
    } catch let error as ServiceLifecycleError {
      throw error
    } catch {
      throw ServiceLifecycleError.fileSystem(
        operation: command.rawValue,
        message: error.localizedDescription
      )
    }
  }

  public func launchAgentPropertyList() throws -> Data {
    let propertyList: [String: Any] = [
      "Label": ServiceLifecyclePaths.label,
      "ProgramArguments": [
        paths.installedDaemonURL.path,
        "--socket",
        paths.socketURL.path,
        "--config",
        paths.configurationURL.path,
      ],
      "RunAtLoad": true,
      "KeepAlive": true,
      "ProcessType": "Interactive",
      "LimitLoadToSessionType": "Aqua",
      "WorkingDirectory": paths.applicationSupportDirectory.path,
      "StandardOutPath": paths.logsDirectory.appending(path: "daemon.log").path,
      "StandardErrorPath": paths.logsDirectory.appending(path: "daemon.error.log").path,
    ]
    return try PropertyListSerialization.data(
      fromPropertyList: propertyList,
      format: .xml,
      options: 0
    )
  }

  public func overlayLaunchAgentPropertyList() throws -> Data {
    let propertyList: [String: Any] = [
      "Label": ServiceLifecyclePaths.overlayLabel,
      "ProgramArguments": [
        paths.installedOverlayURL.path
      ],
      "RunAtLoad": true,
      "KeepAlive": true,
      "ProcessType": "Interactive",
      "LimitLoadToSessionType": "Aqua",
      "WorkingDirectory": paths.applicationSupportDirectory.path,
      "StandardOutPath": paths.logsDirectory.appending(path: "overlay.log").path,
      "StandardErrorPath": paths.logsDirectory.appending(path: "overlay.error.log").path,
    ]
    return try PropertyListSerialization.data(
      fromPropertyList: propertyList,
      format: .xml,
      options: 0
    )
  }

  private var isInstalled: Bool {
    agents.allSatisfy {
      fileSystem.itemExists(at: $0.installedURL) && fileSystem.itemExists(at: $0.agentURL)
    } && fileSystem.itemExists(at: paths.installedUIResourceBundleURL)
  }

  private func install() throws -> ServiceLifecycleResult {
    guard fileSystem.isExecutableFile(at: paths.sourceDaemonURL) else {
      throw ServiceLifecycleError.daemonExecutableMissing(paths.sourceDaemonURL.path)
    }
    guard fileSystem.isExecutableFile(at: paths.sourceOverlayURL) else {
      throw ServiceLifecycleError.overlayExecutableMissing(paths.sourceOverlayURL.path)
    }
    guard fileSystem.itemExists(at: paths.sourceUIResourceBundleURL) else {
      throw ServiceLifecycleError.overlayResourceBundleMissing(
        paths.sourceUIResourceBundleURL.path
      )
    }

    try fileSystem.ensureDirectory(at: paths.applicationSupportDirectory, permissions: 0o700)
    try fileSystem.ensureDirectory(at: paths.binDirectory, permissions: 0o700)
    try fileSystem.ensureDirectory(at: paths.logsDirectory, permissions: 0o700)
    try fileSystem.ensureDirectory(at: paths.launchAgentsDirectory, permissions: 0o755)
    try fileSystem.copyExecutableAtomically(
      from: paths.sourceDaemonURL,
      to: paths.installedDaemonURL
    )
    try fileSystem.copyExecutableAtomically(
      from: paths.sourceOverlayURL,
      to: paths.installedOverlayURL
    )
    try fileSystem.copyDirectoryAtomically(
      from: paths.sourceUIResourceBundleURL,
      to: paths.installedUIResourceBundleURL
    )
    try fileSystem.writeAtomically(
      launchAgentPropertyList(),
      to: paths.launchAgentURL,
      permissions: 0o600
    )
    try fileSystem.writeAtomically(
      overlayLaunchAgentPropertyList(),
      to: paths.overlayLaunchAgentURL,
      permissions: 0o600
    )

    for agent in agents {
      try bootOutIfLoaded(agent)
      try runLaunchctl(["bootstrap", paths.launchdDomain, agent.agentURL.path])
      try runLaunchctl(["kickstart", "-k", agent.launchdTarget])
    }
    return result(for: .install, installed: true, daemonLoaded: true, overlayLoaded: true)
  }

  private func requireInstalled() throws {
    guard isInstalled else {
      throw ServiceLifecycleError.notInstalled(paths.launchAgentURL.path)
    }
  }

  private func isLoaded(_ agent: ManagedAgent) throws -> Bool {
    let arguments = ["print", agent.launchdTarget]
    let result = try runProcess(arguments)
    if result.terminationStatus == 0 {
      return true
    }
    // launchctl uses 113 when the requested service target does not exist.
    // Every other status is a query failure, not evidence that bootout is done.
    guard result.terminationStatus == 113 else {
      throw ServiceLifecycleError.launchctl(
        arguments: arguments,
        status: result.terminationStatus,
        output: result.output
      )
    }
    return false
  }

  private func bootOutIfLoaded(_ agent: ManagedAgent) throws {
    guard try isLoaded(agent) else { return }
    try runLaunchctl(["bootout", agent.launchdTarget])

    let deadline = timing.monotonicTime + Self.launchdTransitionTimeout
    var pollInterval = Self.initialLaunchdPollInterval
    while try isLoaded(agent) {
      let remaining = deadline - timing.monotonicTime
      guard remaining > 0 else {
        throw ServiceLifecycleError.launchdTransitionTimedOut(
          target: agent.launchdTarget,
          timeout: Self.launchdTransitionTimeout
        )
      }
      timing.wait(for: min(pollInterval, remaining))
      pollInterval = min(pollInterval * 2, Self.maximumLaunchdPollInterval)
    }
  }

  private func runLaunchctl(_ arguments: [String]) throws {
    let result = try runProcess(arguments)
    guard result.terminationStatus == 0 else {
      throw ServiceLifecycleError.launchctl(
        arguments: arguments,
        status: result.terminationStatus,
        output: result.output
      )
    }
  }

  private func runProcess(_ arguments: [String]) throws -> ServiceProcessResult {
    do {
      return try processRunner.run(
        executableURL: paths.launchctlURL,
        arguments: arguments
      )
    } catch let error as ServiceLifecycleError {
      throw error
    } catch {
      throw ServiceLifecycleError.process(
        operation: "launchctl",
        message: error.localizedDescription
      )
    }
  }

  private func result(
    for command: ServiceCommand,
    installed: Bool,
    daemonLoaded: Bool,
    overlayLoaded: Bool
  ) -> ServiceLifecycleResult {
    ServiceLifecycleResult(
      operation: command,
      installed: installed,
      loaded: daemonLoaded && overlayLoaded,
      daemonLoaded: daemonLoaded,
      overlayLoaded: overlayLoaded,
      daemonExecutablePath: paths.installedDaemonURL.path,
      overlayExecutablePath: paths.installedOverlayURL.path,
      launchAgentPath: paths.launchAgentURL.path,
      overlayLaunchAgentPath: paths.overlayLaunchAgentURL.path,
      configurationPath: paths.configurationURL.path,
      socketPath: paths.socketURL.path,
      logsPath: paths.logsDirectory.path
    )
  }
}
