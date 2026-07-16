import Darwin
import Foundation
import LogiLiquidCore
import LogiLiquidHID
import LogiLiquidService

public protocol MouseDaemonConfigurationRepository: MouseConfigurationLoading {
  var url: URL { get }

  func ensureExists() throws
  func save(_ configuration: MouseConfiguration) throws
}

/// File-backed configuration with a 0700 parent and a 0600 regular file.
/// Existing paths owned by another user, symbolic links, and hard links are
/// rejected before the core atomic store is allowed to read or replace them.
public final class PrivateMouseConfigurationRepository:
  MouseDaemonConfigurationRepository, @unchecked Sendable
{
  public let url: URL

  private let store: ConfigurationStore
  private let initialConfiguration: MouseConfiguration
  private let lock = NSLock()

  public init(
    url: URL,
    initialConfiguration: MouseConfiguration = MouseConfiguration()
  ) throws {
    guard url.isFileURL else {
      throw ConfigurationError.nonFileURL(url)
    }
    try initialConfiguration.validate()
    self.url = url
    self.initialConfiguration = initialConfiguration
    self.store = try ConfigurationStore(url: url)
  }

  public func ensureExists() throws {
    lock.lock()
    defer { lock.unlock() }

    try PrivatePathSecurity.ensurePrivateParent(of: url)
    if try !PrivatePathSecurity.pathExists(url) {
      try store.save(initialConfiguration)
    }
    try PrivatePathSecurity.secureRegularFile(url)
    _ = try store.load()
  }

  public func load() throws -> MouseConfiguration {
    lock.lock()
    defer { lock.unlock() }

    try PrivatePathSecurity.validatePrivateParent(of: url)
    try PrivatePathSecurity.validatePrivateRegularFile(url)
    return try store.load()
  }

  public func save(_ configuration: MouseConfiguration) throws {
    lock.lock()
    defer { lock.unlock() }

    try PrivatePathSecurity.ensurePrivateParent(of: url)
    if try PrivatePathSecurity.pathExists(url) {
      try PrivatePathSecurity.validateOwnedRegularFile(url)
    }
    try store.save(configuration)
    try PrivatePathSecurity.secureRegularFile(url)
  }
}

private struct DiversionJournalVersionProbe: Decodable {
  let version: Int
}

private struct LegacyDiversionJournalRecord: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  let version: Int
  let snapshot: SensePanelDiversionSnapshot
}

private struct DiversionJournalRecord: Codable, Equatable, Sendable {
  static let currentVersion = 2

  let version: Int
  let stableDeviceIdentity: String?
  let snapshot: SensePanelDiversionSnapshot

  init(
    version: Int = Self.currentVersion,
    stableDeviceIdentity: String?,
    snapshot: SensePanelDiversionSnapshot
  ) {
    self.version = version
    self.stableDeviceIdentity = stableDeviceIdentity
    self.snapshot = snapshot
  }
}

/// The recovery metadata retained alongside the exact pre-diversion reporting
/// state. Version 1 journals have no stable identity and are intentionally
/// marked so recovery can require the original IORegistry entry.
public struct SensePanelDiversionJournalEntry: Equatable, Sendable {
  public let schemaVersion: Int
  public let stableDeviceIdentity: String?
  public let snapshot: SensePanelDiversionSnapshot

  public init(
    schemaVersion: Int,
    stableDeviceIdentity: String?,
    snapshot: SensePanelDiversionSnapshot
  ) {
    self.schemaVersion = schemaVersion
    self.stableDeviceIdentity = stableDeviceIdentity
    self.snapshot = snapshot
  }
}

/// A durable pre-mutation snapshot. The production HID backend writes this
/// before enabling diversion and removes it only after verified restoration.
public final class SensePanelDiversionJournalStore: @unchecked Sendable {
  public let url: URL

  private let lock = NSLock()

  public init(url: URL) throws {
    guard url.isFileURL else {
      throw ConfigurationError.nonFileURL(url)
    }
    self.url = url
  }

  public func load() throws -> SensePanelDiversionSnapshot? {
    lock.lock()
    defer { lock.unlock() }

    return try loadEntryWithoutLock()?.snapshot
  }

  public func loadEntry() throws -> SensePanelDiversionJournalEntry? {
    lock.lock()
    defer { lock.unlock() }

    return try loadEntryWithoutLock()
  }

  private func loadEntryWithoutLock() throws -> SensePanelDiversionJournalEntry? {

    try PrivatePathSecurity.ensurePrivateParent(of: url)
    guard try PrivatePathSecurity.pathExists(url) else {
      return nil
    }
    try PrivatePathSecurity.validatePrivateRegularFile(url)
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    let version = try decoder.decode(
      DiversionJournalVersionProbe.self,
      from: data
    ).version

    switch version {
    case LegacyDiversionJournalRecord.schemaVersion:
      let record = try decoder.decode(
        LegacyDiversionJournalRecord.self,
        from: data
      )
      return SensePanelDiversionJournalEntry(
        schemaVersion: record.version,
        stableDeviceIdentity: nil,
        snapshot: record.snapshot
      )
    case DiversionJournalRecord.currentVersion:
      let record = try decoder.decode(DiversionJournalRecord.self, from: data)
      return SensePanelDiversionJournalEntry(
        schemaVersion: record.version,
        stableDeviceIdentity: record.stableDeviceIdentity,
        snapshot: record.snapshot
      )
    default:
      throw MouseDaemonError.unsupportedJournalVersion(version)
    }
  }

  public func save(
    _ snapshot: SensePanelDiversionSnapshot,
    stableDeviceIdentity: String? = nil
  ) throws {
    lock.lock()
    defer { lock.unlock() }

    try PrivatePathSecurity.ensurePrivateParent(of: url)
    if try PrivatePathSecurity.pathExists(url) {
      try PrivatePathSecurity.validateOwnedRegularFile(url)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(
      DiversionJournalRecord(
        stableDeviceIdentity: stableDeviceIdentity,
        snapshot: snapshot
      )
    )
    data.append(0x0A)
    try data.write(to: url, options: [.atomic])
    try PrivatePathSecurity.secureRegularFile(url)
  }

  public func remove() throws {
    lock.lock()
    defer { lock.unlock() }

    guard try PrivatePathSecurity.pathExists(url) else {
      return
    }
    try PrivatePathSecurity.validatePrivateRegularFile(url)
    guard unlink(url.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}

private enum PrivatePathSecurity {
  static func pathExists(_ url: URL) throws -> Bool {
    var information = stat()
    if lstat(url.path, &information) == 0 {
      return true
    }
    if errno == ENOENT {
      return false
    }
    throw posixError()
  }

  static func ensurePrivateParent(of fileURL: URL) throws {
    let parent = fileURL.deletingLastPathComponent()
    guard parent.path != fileURL.path else {
      throw MouseDaemonError.unsafePath(fileURL.path)
    }

    if try !pathExists(parent) {
      try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: true
      )
    }
    try validateOwnedDirectory(parent)
    guard chmod(parent.path, 0o700) == 0 else {
      throw posixError()
    }
    try validatePrivateParent(of: fileURL)
  }

  static func validatePrivateParent(of fileURL: URL) throws {
    let parent = fileURL.deletingLastPathComponent()
    let information = try ownedStat(parent)
    guard fileType(information.st_mode) == mode_t(S_IFDIR),
      information.st_mode & 0o077 == 0
    else {
      throw MouseDaemonError.unsafePath(parent.path)
    }
  }

  static func validateOwnedDirectory(_ url: URL) throws {
    let information = try ownedStat(url)
    guard fileType(information.st_mode) == mode_t(S_IFDIR) else {
      throw MouseDaemonError.unsafePath(url.path)
    }
  }

  static func validateOwnedRegularFile(_ url: URL) throws {
    let information = try ownedStat(url)
    guard fileType(information.st_mode) == mode_t(S_IFREG),
      information.st_nlink == 1
    else {
      throw MouseDaemonError.unsafePath(url.path)
    }
  }

  static func validatePrivateRegularFile(_ url: URL) throws {
    let information = try ownedStat(url)
    guard fileType(information.st_mode) == mode_t(S_IFREG),
      information.st_nlink == 1,
      information.st_mode & 0o077 == 0
    else {
      throw MouseDaemonError.unsafePath(url.path)
    }
  }

  static func secureRegularFile(_ url: URL) throws {
    try validateOwnedRegularFile(url)
    guard chmod(url.path, 0o600) == 0 else {
      throw posixError()
    }
    try validatePrivateRegularFile(url)
  }

  private static func ownedStat(_ url: URL) throws -> stat {
    var information = stat()
    guard lstat(url.path, &information) == 0 else {
      throw posixError()
    }
    guard information.st_uid == getuid() else {
      throw MouseDaemonError.unsafePath(url.path)
    }
    return information
  }

  private static func fileType(_ mode: mode_t) -> mode_t {
    mode & mode_t(S_IFMT)
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
