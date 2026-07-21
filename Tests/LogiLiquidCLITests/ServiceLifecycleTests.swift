import Darwin
import Foundation
import XCTest

@testable import LogiLiquidCLI

final class ServiceLifecycleTests: XCTestCase {
  func testInstallAtomicallyCopiesExecutablesWritesPlistsAndBootstrapsUnloadedServices() throws {
    let fixture = makeFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 113, output: "service not found"),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 113, output: "service not found"),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
      ]
    )
    fixture.fileSystem.executablePaths.insert(fixture.paths.sourceDaemonURL.path)
    fixture.fileSystem.executablePaths.insert(fixture.paths.sourceOverlayURL.path)
    fixture.fileSystem.existingPaths.insert(fixture.paths.sourceUIResourceBundleURL.path)

    let result = try fixture.controller.perform(.install)

    XCTAssertEqual(
      result,
      expectedResult(paths: fixture.paths, operation: .install, installed: true, loaded: true)
    )
    XCTAssertEqual(
      fixture.fileSystem.operations.map(\ServiceFileOperation.summary),
      [
        "directory:\(fixture.paths.applicationSupportDirectory.path):448",
        "directory:\(fixture.paths.binDirectory.path):448",
        "directory:\(fixture.paths.logsDirectory.path):448",
        "directory:\(fixture.paths.launchAgentsDirectory.path):493",
        "copy:\(fixture.paths.sourceDaemonURL.path):\(fixture.paths.installedDaemonURL.path)",
        "copy:\(fixture.paths.sourceOverlayURL.path):\(fixture.paths.installedOverlayURL.path)",
        "copy-directory:\(fixture.paths.sourceUIResourceBundleURL.path):\(fixture.paths.installedUIResourceBundleURL.path)",
        "write:\(fixture.paths.launchAgentURL.path):384",
        "write:\(fixture.paths.overlayLaunchAgentURL.path):384",
      ]
    )
    XCTAssertEqual(
      fixture.processRunner.invocations,
      [
        LaunchctlInvocation(
          executableURL: fixture.paths.launchctlURL,
          arguments: ["print", fixture.paths.launchdTarget]
        ),
        LaunchctlInvocation(
          executableURL: fixture.paths.launchctlURL,
          arguments: [
            "bootstrap", fixture.paths.launchdDomain, fixture.paths.launchAgentURL.path,
          ]
        ),
        LaunchctlInvocation(
          executableURL: fixture.paths.launchctlURL,
          arguments: ["kickstart", "-k", fixture.paths.launchdTarget]
        ),
        LaunchctlInvocation(
          executableURL: fixture.paths.launchctlURL,
          arguments: ["print", fixture.paths.overlayLaunchdTarget]
        ),
        LaunchctlInvocation(
          executableURL: fixture.paths.launchctlURL,
          arguments: [
            "bootstrap", fixture.paths.launchdDomain, fixture.paths.overlayLaunchAgentURL.path,
          ]
        ),
        LaunchctlInvocation(
          executableURL: fixture.paths.launchctlURL,
          arguments: ["kickstart", "-k", fixture.paths.overlayLaunchdTarget]
        ),
      ]
    )

    let plistData = try XCTUnwrap(fixture.fileSystem.writtenData[fixture.paths.launchAgentURL.path])
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: plistData, format: nil)
        as? [String: Any]
    )
    XCTAssertEqual(plist["Label"] as? String, ServiceLifecyclePaths.label)
    XCTAssertEqual(
      plist["ProgramArguments"] as? [String],
      [
        fixture.paths.installedDaemonURL.path,
        "--socket",
        fixture.paths.socketURL.path,
        "--config",
        fixture.paths.configurationURL.path,
      ]
    )
    XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
    XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
    XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")

    let overlayPlistData = try XCTUnwrap(
      fixture.fileSystem.writtenData[fixture.paths.overlayLaunchAgentURL.path]
    )
    let overlayPlist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: overlayPlistData, format: nil)
        as? [String: Any]
    )
    XCTAssertEqual(overlayPlist["Label"] as? String, ServiceLifecyclePaths.overlayLabel)
    XCTAssertEqual(
      overlayPlist["ProgramArguments"] as? [String],
      [fixture.paths.installedOverlayURL.path]
    )
    XCTAssertEqual(overlayPlist["RunAtLoad"] as? Bool, true)
    XCTAssertEqual(overlayPlist["KeepAlive"] as? Bool, true)
    XCTAssertEqual(overlayPlist["LimitLoadToSessionType"] as? String, "Aqua")
    XCTAssertEqual(
      overlayPlist["StandardOutPath"] as? String,
      fixture.paths.logsDirectory.appending(path: "overlay.log").path
    )
    XCTAssertEqual(
      overlayPlist["StandardErrorPath"] as? String,
      fixture.paths.logsDirectory.appending(path: "overlay.error.log").path
    )
    XCTAssertFalse(fixture.fileSystem.existingPaths.contains(fixture.paths.configurationURL.path))
  }

  func testInstallBootsOutLoadedVersionsBeforeBootstrapAndKickstart() throws {
    let fixture = makeFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 113),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 113),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
      ]
    )
    fixture.fileSystem.executablePaths.insert(fixture.paths.sourceDaemonURL.path)
    fixture.fileSystem.executablePaths.insert(fixture.paths.sourceOverlayURL.path)
    fixture.fileSystem.existingPaths.insert(fixture.paths.sourceUIResourceBundleURL.path)

    _ = try fixture.controller.perform(.install)

    XCTAssertEqual(
      fixture.processRunner.invocations.map(\.arguments),
      [
        ["print", fixture.paths.launchdTarget],
        ["bootout", fixture.paths.launchdTarget],
        ["print", fixture.paths.launchdTarget],
        ["bootstrap", fixture.paths.launchdDomain, fixture.paths.launchAgentURL.path],
        ["kickstart", "-k", fixture.paths.launchdTarget],
        ["print", fixture.paths.overlayLaunchdTarget],
        ["bootout", fixture.paths.overlayLaunchdTarget],
        ["print", fixture.paths.overlayLaunchdTarget],
        ["bootstrap", fixture.paths.launchdDomain, fixture.paths.overlayLaunchAgentURL.path],
        ["kickstart", "-k", fixture.paths.overlayLaunchdTarget],
      ]
    )
  }

  func testStartAndRestartBootstrapOnlyWhenUnloaded() throws {
    let start = makeInstalledFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 113),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 113),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
      ]
    )
    XCTAssertEqual(try start.controller.perform(.start).loaded, true)
    XCTAssertEqual(
      start.processRunner.invocations.map(\.arguments),
      [
        ["print", start.paths.launchdTarget],
        ["bootstrap", start.paths.launchdDomain, start.paths.launchAgentURL.path],
        ["kickstart", "-k", start.paths.launchdTarget],
        ["print", start.paths.overlayLaunchdTarget],
        ["bootstrap", start.paths.launchdDomain, start.paths.overlayLaunchAgentURL.path],
        ["kickstart", "-k", start.paths.overlayLaunchdTarget],
      ]
    )

    let restart = makeInstalledFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
      ]
    )
    XCTAssertEqual(try restart.controller.perform(.restart).loaded, true)
    XCTAssertEqual(
      restart.processRunner.invocations.map(\.arguments),
      [
        ["print", restart.paths.launchdTarget],
        ["kickstart", "-k", restart.paths.launchdTarget],
        ["print", restart.paths.overlayLaunchdTarget],
        ["kickstart", "-k", restart.paths.overlayLaunchdTarget],
      ]
    )
  }

  func testStopAndStatusTreatAnAbsentLaunchdJobAsStateNotFailure() throws {
    let stop = makeInstalledFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 113),
        ServiceProcessResult(terminationStatus: 113),
      ]
    )
    let stopResult = try stop.controller.perform(.stop)
    XCTAssertTrue(stopResult.installed)
    XCTAssertFalse(stopResult.loaded)
    XCTAssertEqual(
      stop.processRunner.invocations.map(\.arguments),
      [
        ["print", stop.paths.launchdTarget],
        ["print", stop.paths.overlayLaunchdTarget],
      ]
    )

    let status = makeFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 113),
        ServiceProcessResult(terminationStatus: 113),
      ]
    )
    let statusResult = try status.controller.perform(.status)
    XCTAssertFalse(statusResult.installed)
    XCTAssertFalse(statusResult.loaded)
  }

  func testStatusReportsDaemonAndOverlayLoadStatesSeparately() throws {
    // The exact "cursor hides but no ring appears" failure: the daemon runs
    // while the overlay job is gone.
    let fixture = makeInstalledFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 113),
      ]
    )
    let result = try fixture.controller.perform(.status)
    XCTAssertTrue(result.installed)
    XCTAssertTrue(result.daemonLoaded)
    XCTAssertFalse(result.overlayLoaded)
    XCTAssertFalse(result.loaded)
  }

  func testUninstallBootsOutAndRemovesOnlyManagedFilesKeepingConfiguration() throws {
    let fixture = makeInstalledFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 113),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 113),
      ]
    )
    fixture.fileSystem.existingPaths.insert(fixture.paths.configurationURL.path)

    let result = try fixture.controller.perform(.uninstall)

    XCTAssertFalse(result.installed)
    XCTAssertFalse(result.loaded)
    XCTAssertEqual(
      fixture.processRunner.invocations.map(\.arguments),
      [
        ["print", fixture.paths.launchdTarget],
        ["bootout", fixture.paths.launchdTarget],
        ["print", fixture.paths.launchdTarget],
        ["print", fixture.paths.overlayLaunchdTarget],
        ["bootout", fixture.paths.overlayLaunchdTarget],
        ["print", fixture.paths.overlayLaunchdTarget],
      ]
    )
    XCTAssertEqual(
      fixture.fileSystem.operations.map(\ServiceFileOperation.summary),
      [
        "remove:\(fixture.paths.launchAgentURL.path)",
        "remove:\(fixture.paths.installedDaemonURL.path)",
        "remove:\(fixture.paths.overlayLaunchAgentURL.path)",
        "remove:\(fixture.paths.installedOverlayURL.path)",
        "remove:\(fixture.paths.installedUIResourceBundleURL.path)",
      ]
    )
    XCTAssertTrue(fixture.fileSystem.existingPaths.contains(fixture.paths.configurationURL.path))
  }

  func testMissingInstallSourcesAndLaunchctlFailuresAreStructured() throws {
    let missingDaemon = makeFixture(processResults: [])
    XCTAssertThrowsError(try missingDaemon.controller.perform(.install)) { error in
      XCTAssertEqual(
        error as? ServiceLifecycleError,
        .daemonExecutableMissing(missingDaemon.paths.sourceDaemonURL.path)
      )
    }
    XCTAssertTrue(missingDaemon.fileSystem.operations.isEmpty)
    XCTAssertTrue(missingDaemon.processRunner.invocations.isEmpty)

    let missingOverlay = makeFixture(processResults: [])
    missingOverlay.fileSystem.executablePaths.insert(missingOverlay.paths.sourceDaemonURL.path)
    XCTAssertThrowsError(try missingOverlay.controller.perform(.install)) { error in
      XCTAssertEqual(
        error as? ServiceLifecycleError,
        .overlayExecutableMissing(missingOverlay.paths.sourceOverlayURL.path)
      )
    }
    XCTAssertTrue(missingOverlay.fileSystem.operations.isEmpty)

    let missingResources = makeFixture(processResults: [])
    missingResources.fileSystem.executablePaths.formUnion([
      missingResources.paths.sourceDaemonURL.path,
      missingResources.paths.sourceOverlayURL.path,
    ])
    XCTAssertThrowsError(try missingResources.controller.perform(.install)) { error in
      XCTAssertEqual(
        error as? ServiceLifecycleError,
        .overlayResourceBundleMissing(missingResources.paths.sourceUIResourceBundleURL.path)
      )
    }
    XCTAssertTrue(missingResources.fileSystem.operations.isEmpty)

    let bootstrapFailure = makeInstalledFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 113),
        ServiceProcessResult(terminationStatus: 5, output: "Input/output error"),
      ]
    )
    XCTAssertThrowsError(try bootstrapFailure.controller.perform(.start)) { error in
      XCTAssertEqual(
        error as? ServiceLifecycleError,
        .launchctl(
          arguments: [
            "bootstrap", bootstrapFailure.paths.launchdDomain,
            bootstrapFailure.paths.launchAgentURL.path,
          ],
          status: 5,
          output: "Input/output error"
        )
      )
    }
  }

  func testInstallWaitsForBootoutStateBeforeBootstrapWithoutFixedDelay() throws {
    let fixture = makeFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 113),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 113),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
      ]
    )
    fixture.fileSystem.executablePaths.insert(fixture.paths.sourceDaemonURL.path)
    fixture.fileSystem.executablePaths.insert(fixture.paths.sourceOverlayURL.path)
    fixture.fileSystem.existingPaths.insert(fixture.paths.sourceUIResourceBundleURL.path)

    XCTAssertTrue(try fixture.controller.perform(.install).loaded)
    XCTAssertEqual(
      fixture.processRunner.invocations.map(\.arguments),
      [
        ["print", fixture.paths.launchdTarget],
        ["bootout", fixture.paths.launchdTarget],
        ["print", fixture.paths.launchdTarget],
        ["print", fixture.paths.launchdTarget],
        ["print", fixture.paths.launchdTarget],
        ["bootstrap", fixture.paths.launchdDomain, fixture.paths.launchAgentURL.path],
        ["kickstart", "-k", fixture.paths.launchdTarget],
        ["print", fixture.paths.overlayLaunchdTarget],
        ["bootstrap", fixture.paths.launchdDomain, fixture.paths.overlayLaunchAgentURL.path],
        ["kickstart", "-k", fixture.paths.overlayLaunchdTarget],
      ]
    )
    XCTAssertEqual(fixture.timing.waitedIntervals, [0.05, 0.1])
  }

  func testBootoutStateWaitHasStructuredBoundedTimeout() throws {
    let fixture = makeInstalledFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
      ]
        + Array(
          repeating: ServiceProcessResult(terminationStatus: 0),
          count: 36
        )
    )

    XCTAssertThrowsError(try fixture.controller.perform(.stop)) { error in
      XCTAssertEqual(
        error as? ServiceLifecycleError,
        .launchdTransitionTimedOut(
          target: fixture.paths.launchdTarget,
          timeout: ServiceLifecycleController.launchdTransitionTimeout
        )
      )
    }
    XCTAssertEqual(fixture.timing.monotonicTime, 15, accuracy: 0.000_001)
  }

  func testLaunchctlPrintFailureIsNotTreatedAsAnAbsentJob() throws {
    let fixture = makeInstalledFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 5, output: "Input/output error")
      ]
    )

    XCTAssertThrowsError(try fixture.controller.perform(.uninstall)) { error in
      XCTAssertEqual(
        error as? ServiceLifecycleError,
        .launchctl(
          arguments: ["print", fixture.paths.launchdTarget],
          status: 5,
          output: "Input/output error"
        )
      )
    }
    XCTAssertTrue(fixture.fileSystem.operations.isEmpty)
  }

  func testLocalFileSystemReplacesExecutableAtomicallyWithPrivatePermissions() throws {
    let root = URL(
      filePath: "/tmp/logi-liquid-service-fs-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "source")
    let destination = root.appending(path: "logi-liquid-daemon")
    try Data("new daemon".utf8).write(to: source)
    try Data("old daemon".utf8).write(to: destination)

    let fileSystem = LocalServiceFileSystem()
    try fileSystem.copyExecutableAtomically(from: source, to: destination)

    XCTAssertEqual(try Data(contentsOf: destination), Data("new daemon".utf8))
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertFalse(siblings.contains { $0.hasSuffix(".tmp") })
  }

  func testLocalFileSystemAtomicallySwapsResourceBundleDirectory() throws {
    let root = URL(
      filePath: "/tmp/logi-liquid-service-resources-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.bundle", directoryHint: .isDirectory)
    let destination = root.appending(path: "installed.bundle", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("new resource".utf8).write(to: source.appending(path: "mark.svg"))
    try Data("old resource".utf8).write(to: destination.appending(path: "old.svg"))

    let fileSystem = LocalServiceFileSystem()
    try fileSystem.copyDirectoryAtomically(from: source, to: destination)

    XCTAssertEqual(
      try Data(contentsOf: destination.appending(path: "mark.svg")),
      Data("new resource".utf8)
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: destination.appending(path: "old.svg").path))
    let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertFalse(siblings.contains { $0.hasSuffix(".tmp") })
  }

  private func makeInstalledFixture(
    processResults: [ServiceProcessResult]
  ) -> LifecycleFixture {
    let fixture = makeFixture(processResults: processResults)
    fixture.fileSystem.existingPaths.formUnion([
      fixture.paths.installedDaemonURL.path,
      fixture.paths.launchAgentURL.path,
      fixture.paths.installedOverlayURL.path,
      fixture.paths.overlayLaunchAgentURL.path,
      fixture.paths.installedUIResourceBundleURL.path,
    ])
    return fixture
  }

  private func makeFixture(
    processResults: [ServiceProcessResult]
  ) -> LifecycleFixture {
    let paths = ServiceLifecyclePaths(
      homeDirectory: URL(filePath: "/Users/tester", directoryHint: .isDirectory),
      sourceDaemonURL: URL(filePath: "/build/logi-liquid-daemon"),
      userID: 501
    )
    let fileSystem = RecordingServiceFileSystem()
    let processRunner = RecordingServiceProcessRunner(results: processResults)
    let timing = RecordingServiceLifecycleTiming()
    return LifecycleFixture(
      paths: paths,
      fileSystem: fileSystem,
      processRunner: processRunner,
      timing: timing,
      controller: ServiceLifecycleController(
        paths: paths,
        fileSystem: fileSystem,
        processRunner: processRunner,
        timing: timing
      )
    )
  }

  private func expectedResult(
    paths: ServiceLifecyclePaths,
    operation: ServiceCommand,
    installed: Bool,
    loaded: Bool
  ) -> ServiceLifecycleResult {
    ServiceLifecycleResult(
      operation: operation,
      installed: installed,
      loaded: loaded,
      daemonLoaded: loaded,
      overlayLoaded: loaded,
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

private struct LifecycleFixture {
  let paths: ServiceLifecyclePaths
  let fileSystem: RecordingServiceFileSystem
  let processRunner: RecordingServiceProcessRunner
  let timing: RecordingServiceLifecycleTiming
  let controller: ServiceLifecycleController
}

private final class RecordingServiceLifecycleTiming: ServiceLifecycleTiming {
  private(set) var monotonicTime: TimeInterval = 0
  private(set) var waitedIntervals: [TimeInterval] = []

  func wait(for interval: TimeInterval) {
    waitedIntervals.append(interval)
    monotonicTime += interval
  }
}

private enum ServiceFileOperation: Equatable {
  case directory(path: String, permissions: Int)
  case copy(source: String, destination: String)
  case copyDirectory(source: String, destination: String)
  case write(path: String, permissions: Int)
  case remove(path: String)

  var summary: String {
    switch self {
    case .directory(let path, let permissions):
      "directory:\(path):\(permissions)"
    case .copy(let source, let destination):
      "copy:\(source):\(destination)"
    case .copyDirectory(let source, let destination):
      "copy-directory:\(source):\(destination)"
    case .write(let path, let permissions):
      "write:\(path):\(permissions)"
    case .remove(let path):
      "remove:\(path)"
    }
  }
}

private final class RecordingServiceFileSystem: ServiceFileSystem {
  var existingPaths = Set<String>()
  var executablePaths = Set<String>()
  var writtenData: [String: Data] = [:]
  private(set) var operations: [ServiceFileOperation] = []

  func itemExists(at url: URL) -> Bool {
    existingPaths.contains(url.path)
  }

  func isExecutableFile(at url: URL) -> Bool {
    executablePaths.contains(url.path)
  }

  func ensureDirectory(at url: URL, permissions: Int) throws {
    operations.append(.directory(path: url.path, permissions: permissions))
    existingPaths.insert(url.path)
  }

  func copyExecutableAtomically(from sourceURL: URL, to destinationURL: URL) throws {
    operations.append(.copy(source: sourceURL.path, destination: destinationURL.path))
    existingPaths.insert(destinationURL.path)
    executablePaths.insert(destinationURL.path)
  }

  func copyDirectoryAtomically(from sourceURL: URL, to destinationURL: URL) throws {
    operations.append(.copyDirectory(source: sourceURL.path, destination: destinationURL.path))
    existingPaths.insert(destinationURL.path)
  }

  func writeAtomically(_ data: Data, to destinationURL: URL, permissions: Int) throws {
    operations.append(.write(path: destinationURL.path, permissions: permissions))
    writtenData[destinationURL.path] = data
    existingPaths.insert(destinationURL.path)
  }

  func removeItemIfExists(at url: URL) throws {
    operations.append(.remove(path: url.path))
    existingPaths.remove(url.path)
    executablePaths.remove(url.path)
    writtenData.removeValue(forKey: url.path)
  }
}

private struct LaunchctlInvocation: Equatable {
  let executableURL: URL
  let arguments: [String]
}

private final class RecordingServiceProcessRunner: ServiceProcessRunning {
  private var results: [ServiceProcessResult]
  private(set) var invocations: [LaunchctlInvocation] = []

  init(results: [ServiceProcessResult]) {
    self.results = results
  }

  func run(executableURL: URL, arguments: [String]) throws -> ServiceProcessResult {
    invocations.append(LaunchctlInvocation(executableURL: executableURL, arguments: arguments))
    guard !results.isEmpty else {
      throw CocoaError(.coderInvalidValue)
    }
    return results.removeFirst()
  }
}
