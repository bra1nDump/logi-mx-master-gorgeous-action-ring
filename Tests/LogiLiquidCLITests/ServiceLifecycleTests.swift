import Darwin
import Foundation
import XCTest

@testable import LogiLiquidCLI

final class ServiceLifecycleTests: XCTestCase {
  func testInstallAtomicallyCopiesDaemonWritesPlistAndBootstrapsUnloadedService() throws {
    let fixture = makeFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 113, output: "service not found"),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
      ]
    )
    fixture.fileSystem.executablePaths.insert(fixture.paths.sourceDaemonURL.path)

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
        "write:\(fixture.paths.launchAgentURL.path):384",
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
    XCTAssertFalse(fixture.fileSystem.existingPaths.contains(fixture.paths.configurationURL.path))
  }

  func testInstallBootsOutLoadedVersionBeforeBootstrapAndKickstart() throws {
    let fixture = makeFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
      ]
    )
    fixture.fileSystem.executablePaths.insert(fixture.paths.sourceDaemonURL.path)

    _ = try fixture.controller.perform(.install)

    XCTAssertEqual(
      fixture.processRunner.invocations.map(\.arguments),
      [
        ["print", fixture.paths.launchdTarget],
        ["bootout", fixture.paths.launchdTarget],
        ["bootstrap", fixture.paths.launchdDomain, fixture.paths.launchAgentURL.path],
        ["kickstart", "-k", fixture.paths.launchdTarget],
      ]
    )
  }

  func testStartAndRestartBootstrapOnlyWhenUnloaded() throws {
    let start = makeInstalledFixture(
      processResults: [
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
      ]
    )

    let restart = makeInstalledFixture(
      processResults: [
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
      ]
    )
  }

  func testStopAndStatusTreatAnAbsentLaunchdJobAsStateNotFailure() throws {
    let stop = makeInstalledFixture(
      processResults: [ServiceProcessResult(terminationStatus: 113)]
    )
    let stopResult = try stop.controller.perform(.stop)
    XCTAssertTrue(stopResult.installed)
    XCTAssertFalse(stopResult.loaded)
    XCTAssertEqual(
      stop.processRunner.invocations.map(\.arguments),
      [["print", stop.paths.launchdTarget]]
    )

    let status = makeFixture(
      processResults: [ServiceProcessResult(terminationStatus: 113)]
    )
    let statusResult = try status.controller.perform(.status)
    XCTAssertFalse(statusResult.installed)
    XCTAssertFalse(statusResult.loaded)
  }

  func testUninstallBootsOutAndRemovesOnlyManagedFilesKeepingConfiguration() throws {
    let fixture = makeInstalledFixture(
      processResults: [
        ServiceProcessResult(terminationStatus: 0),
        ServiceProcessResult(terminationStatus: 0),
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
      ]
    )
    XCTAssertEqual(
      fixture.fileSystem.operations.map(\ServiceFileOperation.summary),
      [
        "remove:\(fixture.paths.launchAgentURL.path)",
        "remove:\(fixture.paths.installedDaemonURL.path)",
      ]
    )
    XCTAssertTrue(fixture.fileSystem.existingPaths.contains(fixture.paths.configurationURL.path))
  }

  func testMissingInstallSourceAndLaunchctlFailuresAreStructured() throws {
    let missingSource = makeFixture(processResults: [])
    XCTAssertThrowsError(try missingSource.controller.perform(.install)) { error in
      XCTAssertEqual(
        error as? ServiceLifecycleError,
        .daemonExecutableMissing(missingSource.paths.sourceDaemonURL.path)
      )
    }
    XCTAssertTrue(missingSource.fileSystem.operations.isEmpty)
    XCTAssertTrue(missingSource.processRunner.invocations.isEmpty)

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

  private func makeInstalledFixture(
    processResults: [ServiceProcessResult]
  ) -> LifecycleFixture {
    let fixture = makeFixture(processResults: processResults)
    fixture.fileSystem.existingPaths.formUnion([
      fixture.paths.installedDaemonURL.path,
      fixture.paths.launchAgentURL.path,
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
    return LifecycleFixture(
      paths: paths,
      fileSystem: fileSystem,
      processRunner: processRunner,
      controller: ServiceLifecycleController(
        paths: paths,
        fileSystem: fileSystem,
        processRunner: processRunner
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
      daemonExecutablePath: paths.installedDaemonURL.path,
      launchAgentPath: paths.launchAgentURL.path,
      configurationPath: paths.configurationURL.path,
      socketPath: paths.socketURL.path
    )
  }
}

private struct LifecycleFixture {
  let paths: ServiceLifecyclePaths
  let fileSystem: RecordingServiceFileSystem
  let processRunner: RecordingServiceProcessRunner
  let controller: ServiceLifecycleController
}

private enum ServiceFileOperation: Equatable {
  case directory(path: String, permissions: Int)
  case copy(source: String, destination: String)
  case write(path: String, permissions: Int)
  case remove(path: String)

  var summary: String {
    switch self {
    case .directory(let path, let permissions):
      "directory:\(path):\(permissions)"
    case .copy(let source, let destination):
      "copy:\(source):\(destination)"
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
