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

  public let homeDirectory: URL
  public let sourceDaemonURL: URL
  public let sourceOverlayURL: URL
  public let applicationSupportDirectory: URL
  public let binDirectory: URL
  public let installedDaemonURL: URL
  public let installedOverlayURL: URL
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
  case notInstalled(String)
  case fileSystem(operation: String, message: String)
  case process(operation: String, message: String)
  case launchctl(arguments: [String], status: Int32, output: String)

  public var code: String {
    switch self {
    case .daemonExecutableMissing: "daemon_executable_missing"
    case .overlayExecutableMissing: "overlay_executable_missing"
    case .notInstalled: "not_installed"
    case .fileSystem: "filesystem_failed"
    case .process: "process_failed"
    case .launchctl: "launchctl_failed"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .daemonExecutableMissing(let path):
      return "Sibling logi-liquid-daemon executable is missing or not executable at \(path)."
    case .overlayExecutableMissing(let path):
      return "Sibling logi-liquid-overlay executable is missing or not executable at \(path)."
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

  public init(
    paths: ServiceLifecyclePaths = .live,
    fileSystem: any ServiceFileSystem = LocalServiceFileSystem(),
    processRunner: any ServiceProcessRunning = FoundationServiceProcessRunner()
  ) {
    self.paths = paths
    self.fileSystem = fileSystem
    self.processRunner = processRunner
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
          if try isLoaded(agent) {
            try runLaunchctl(["bootout", agent.launchdTarget])
          }
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
          if try isLoaded(agent) {
            try runLaunchctl(["bootout", agent.launchdTarget])
          }
        }
        for agent in agents {
          try fileSystem.removeItemIfExists(at: agent.agentURL)
          try fileSystem.removeItemIfExists(at: agent.installedURL)
        }
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
    }
  }

  private func install() throws -> ServiceLifecycleResult {
    guard fileSystem.isExecutableFile(at: paths.sourceDaemonURL) else {
      throw ServiceLifecycleError.daemonExecutableMissing(paths.sourceDaemonURL.path)
    }
    guard fileSystem.isExecutableFile(at: paths.sourceOverlayURL) else {
      throw ServiceLifecycleError.overlayExecutableMissing(paths.sourceOverlayURL.path)
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
      if try isLoaded(agent) {
        try runLaunchctl(["bootout", agent.launchdTarget])
      }
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
    let result = try runProcess(["print", agent.launchdTarget])
    return result.terminationStatus == 0
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
