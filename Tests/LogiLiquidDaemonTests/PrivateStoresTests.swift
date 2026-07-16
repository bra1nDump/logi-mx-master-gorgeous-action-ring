import Darwin
import Foundation
import LogiLiquidCore
import LogiLiquidDaemon
import LogiLiquidHID
import XCTest

final class PrivateStoresTests: XCTestCase {
  func testConfigurationCreatesPrivateParentAndFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "logi-liquid-private-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let configurationURL =
      root
      .appending(path: "mouse", directoryHint: .isDirectory)
      .appending(path: "config.json", directoryHint: .notDirectory)
    let repository = try PrivateMouseConfigurationRepository(url: configurationURL)

    try repository.ensureExists()
    XCTAssertEqual(try mode(of: configurationURL.deletingLastPathComponent()), 0o700)
    XCTAssertEqual(try mode(of: configurationURL), 0o600)
    XCTAssertEqual(try repository.load(), MouseConfiguration())
  }

  func testConfigurationSeedsRequestedPresetOnlyOnFirstCreation() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "logi-liquid-preset-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "config.json")
    let repository = try PrivateMouseConfigurationRepository(
      url: url,
      initialConfiguration: .logiLiquidDefault
    )

    try repository.ensureExists()
    XCTAssertEqual(try repository.load(), .logiLiquidDefault)

    var customized = MouseConfiguration.logiLiquidDefault
    customized.removeAction(named: "Play Spotify")
    try repository.save(customized)
    try repository.ensureExists()
    XCTAssertEqual(try repository.load(), customized)
  }

  func testConfigurationRejectsSymlinkFile() throws {
    let root = try makePrivateStoreDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "target.json")
    try Data("{}".utf8).write(to: target)
    let link = root.appending(path: "config.json")
    XCTAssertEqual(symlink(target.path, link.path), 0)
    let repository = try PrivateMouseConfigurationRepository(url: link)

    XCTAssertThrowsError(try repository.ensureExists()) { error in
      guard case MouseDaemonError.unsafePath = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testJournalUsesPrivateFileAndRoundTripsSnapshot() throws {
    let root = try makePrivateStoreDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "diversion.json")
    let journal = try SensePanelDiversionJournalStore(url: url)
    let snapshot = try makeDiversionSnapshot()

    try journal.save(snapshot, stableDeviceIdentity: "sha256:mouse-a")
    XCTAssertEqual(try mode(of: url), 0o600)
    XCTAssertEqual(try journal.load(), snapshot)
    XCTAssertEqual(
      try journal.loadEntry(),
      SensePanelDiversionJournalEntry(
        schemaVersion: 2,
        stableDeviceIdentity: "sha256:mouse-a",
        snapshot: snapshot
      )
    )
    try journal.remove()
    XCTAssertNil(try journal.load())
  }

  func testJournalSafelyDecodesLegacyVersionOneWithoutInventingIdentity() throws {
    struct LegacyRecord: Encodable {
      let version = 1
      let snapshot: SensePanelDiversionSnapshot
    }

    let root = try makePrivateStoreDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "diversion.json")
    let snapshot = try makeDiversionSnapshot()
    try JSONEncoder().encode(
      LegacyRecord(snapshot: snapshot)
    ).write(to: url, options: .atomic)
    XCTAssertEqual(chmod(url.path, 0o600), 0)

    let journal = try SensePanelDiversionJournalStore(url: url)
    let entry = try XCTUnwrap(journal.loadEntry())
    XCTAssertEqual(entry.schemaVersion, 1)
    XCTAssertNil(entry.stableDeviceIdentity)
    XCTAssertEqual(entry.snapshot, snapshot)
  }
}

private func makePrivateStoreDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "logi-liquid-store-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  guard chmod(directory.path, 0o700) == 0 else {
    throw POSIXError(.EIO)
  }
  return directory
}

private func mode(of url: URL) throws -> mode_t {
  var information = stat()
  guard lstat(url.path, &information) == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  return information.st_mode & 0o777
}
