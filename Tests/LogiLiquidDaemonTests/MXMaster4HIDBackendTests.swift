import Darwin
import Foundation
import LogiLiquidCore
import LogiLiquidDaemon
import LogiLiquidHID
import XCTest

private enum TestDriverError: Error {
  case eventRead
  case apply
  case restore
}

private final class FakeMXMaster4Driver: MXMaster4HIDDriving, @unchecked Sendable {
  private let condition = NSCondition()
  private let snapshot: SensePanelDiversionSnapshot
  let stableDeviceIdentity: String?
  private var reports: [Result<HIDPPPacket?, any Error>] = []
  private var closed = false
  private var failApply = false
  private var failRestore = false
  private var failReporting = false
  private var reportingDiverted = true
  private(set) var calls: [String] = []
  private(set) var haptics: [UInt8] = []
  private(set) var restoredSnapshots: [SensePanelDiversionSnapshot] = []

  init(
    snapshot: SensePanelDiversionSnapshot,
    stableDeviceIdentity: String? = "sha256:mouse-a"
  ) {
    self.snapshot = snapshot
    self.stableDeviceIdentity = stableDeviceIdentity
  }

  func setFailApply(_ value: Bool) {
    condition.lock()
    failApply = value
    condition.unlock()
  }

  func setFailRestore(_ value: Bool) {
    condition.lock()
    failRestore = value
    condition.unlock()
  }

  func enqueue(_ result: Result<HIDPPPacket?, any Error>) {
    condition.lock()
    reports.append(result)
    condition.broadcast()
    condition.unlock()
  }

  func inspect(diversionActive: Bool) throws -> MouseDeviceInspection {
    record("inspect")
    return MouseDeviceInspection(
      registryID: snapshot.deviceRegistryID,
      vendorID: LogitechHIDDevice.logitechVendorID,
      productID: LogitechHIDDevice.mxMaster4ProductID,
      product: "MX Master 4",
      transport: "Bluetooth Low Energy",
      isMXMaster4DirectBluetooth: true,
      supportsHIDPPLongReports: true,
      protocolMajor: 4,
      protocolMinor: 5,
      pingEchoMatched: true,
      features: [
        MouseHIDFeatureInspection(
          id: HIDPPFeatureID.reprogrammableControlsV4.rawValue,
          runtimeIndex: snapshot.featureIndex,
          version: 4
        ),
        MouseHIDFeatureInspection(
          id: HIDPPFeatureID.hapticFeedback.rawValue,
          runtimeIndex: 0x0B,
          version: 1
        ),
      ],
      sensePanelControl: snapshot.control,
      sensePanelReporting: snapshot.originalReporting,
      diversionActive: diversionActive
    )
  }

  func prepareDiversion() throws -> SensePanelDiversionSnapshot {
    record("prepare")
    return snapshot
  }

  func applyDiversion(_ snapshot: SensePanelDiversionSnapshot) throws {
    condition.lock()
    calls.append("apply")
    let shouldFail = failApply
    if !shouldFail { reportingDiverted = true }
    condition.unlock()
    if shouldFail { throw TestDriverError.apply }
  }

  /// Simulates the device silently dropping its volatile diversion, as
  /// observed across system sleep.
  func dropDiversion() {
    condition.lock()
    reportingDiverted = false
    condition.unlock()
  }

  func setFailReporting(_ value: Bool) {
    condition.lock()
    failReporting = value
    condition.unlock()
  }

  func sensePanelReportingState(
    featureIndex: UInt8,
    controlID: UInt16
  ) throws -> ControlReportingState {
    condition.lock()
    calls.append("reporting-state")
    let diverted = reportingDiverted
    let shouldFail = failReporting
    condition.unlock()
    if shouldFail { throw TestDriverError.eventRead }
    return ControlReportingState(
      controlID: controlID,
      diverted: diverted,
      persistentlyDiverted: false,
      rawXY: diverted,
      forceRawXY: false,
      remappedTo: nil,
      analyticsKeyEvents: false,
      rawWheel: false
    )
  }

  func restoreDiversion(_ snapshot: SensePanelDiversionSnapshot) throws {
    condition.lock()
    calls.append("restore")
    restoredSnapshots.append(snapshot)
    let shouldFail = failRestore
    condition.unlock()
    if shouldFail { throw TestDriverError.restore }
  }

  func nextReport(timeoutMilliseconds: Int32) throws -> HIDPPPacket? {
    condition.lock()
    if reports.isEmpty, !closed {
      _ = condition.wait(
        until: Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
      )
    }
    let result = reports.isEmpty ? nil : reports.removeFirst()
    condition.unlock()
    return try result?.get()
  }

  func playHaptic(waveformID: UInt8) throws {
    condition.lock()
    haptics.append(waveformID)
    condition.unlock()
  }

  func close() {
    condition.lock()
    calls.append("close")
    closed = true
    condition.broadcast()
    condition.unlock()
  }

  func callSnapshot() -> [String] {
    condition.lock()
    defer { condition.unlock() }
    return calls
  }

  private func record(_ call: String) {
    condition.lock()
    calls.append(call)
    condition.unlock()
  }
}

private struct FakeMXMaster4DriverFactory: MXMaster4HIDDriverFactory {
  let driver: FakeMXMaster4Driver

  func makeDriver(
    matchingStableIdentity _: String?
  ) throws -> any MXMaster4HIDDriving {
    driver
  }
}

final class MXMaster4HIDBackendTests: XCTestCase {
  func testRawXYDiscardsFirstSamplePerPressAndNeverEmitsAfterRelease() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 10
    )
    let acceptedDeltas = expectation(description: "armed raw XY deltas")
    acceptedDeltas.expectedFulfillmentCount = 2
    let recorder = PointerDeltaRecorder()

    try backend.start { event in
      if case .pointerDelta(let delta) = event {
        recorder.append(delta)
        acceptedDeltas.fulfill()
      }
    }

    driver.enqueue(
      .success(
        try sensePanelPacket(featureIndex: snapshot.featureIndex, pressed: true)
      )
    )
    driver.enqueue(
      .success(
        try rawXYPacket(
          featureIndex: snapshot.featureIndex,
          dx: -3_091,
          dy: -7_254
        )
      )
    )
    driver.enqueue(
      .success(
        try sensePanelPacket(featureIndex: snapshot.featureIndex, pressed: true)
      )
    )
    driver.enqueue(
      .success(
        try rawXYPacket(featureIndex: snapshot.featureIndex, dx: 7, dy: -11)
      )
    )
    driver.enqueue(
      .success(
        try sensePanelPacket(featureIndex: snapshot.featureIndex, pressed: false)
      )
    )
    driver.enqueue(
      .success(
        try rawXYPacket(featureIndex: snapshot.featureIndex, dx: 99, dy: 99)
      )
    )
    driver.enqueue(
      .success(
        try sensePanelPacket(featureIndex: snapshot.featureIndex, pressed: true)
      )
    )
    driver.enqueue(
      .success(
        try rawXYPacket(featureIndex: snapshot.featureIndex, dx: 1, dy: 1)
      )
    )
    driver.enqueue(
      .success(
        try rawXYPacket(featureIndex: snapshot.featureIndex, dx: 3, dy: 4)
      )
    )

    wait(for: [acceptedDeltas], timeout: 1)
    try backend.stop()
    XCTAssertEqual(
      recorder.deltas,
      [Vector2(x: 7, y: -11), Vector2(x: 3, y: 4)]
    )
  }

  func testDuplicatePressedReportsEmitOneEdgeUntilRelease() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 10
    )
    let acceptedEdges = expectation(description: "accepted Sense Panel edges")
    acceptedEdges.expectedFulfillmentCount = 3
    let recorder = SensePanelEdgeRecorder()

    try backend.start { event in
      switch event {
      case .sensePanelPressed:
        recorder.recordPress()
        acceptedEdges.fulfill()
      case .sensePanelReleased:
        recorder.recordRelease()
        acceptedEdges.fulfill()
      case .rawReport, .pointerDelta, .wakeHealthProbeSucceeded, .terminated:
        break
      }
    }

    let pressed = try sensePanelPacket(
      featureIndex: snapshot.featureIndex,
      pressed: true
    )
    let released = try sensePanelPacket(
      featureIndex: snapshot.featureIndex,
      pressed: false
    )
    driver.enqueue(.success(pressed))
    driver.enqueue(.success(pressed))
    driver.enqueue(.success(pressed))
    driver.enqueue(.success(released))
    driver.enqueue(.success(pressed))

    wait(for: [acceptedEdges], timeout: 1)
    XCTAssertEqual(recorder.pressCount, 2)
    XCTAssertEqual(recorder.releaseCount, 1)
    try backend.stop()
  }

  func testWakeProbeRearmsPressEdgeWithoutNeedingALostRelease() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 5,
      healthProbeInterval: 3_600
    )
    let presses = expectation(description: "pre-sleep and post-wake presses")
    presses.expectedFulfillmentCount = 2
    let probeSucceeded = expectation(description: "wake probe succeeded")
    let recorder = SensePanelEdgeRecorder()

    try backend.start { event in
      switch event {
      case .sensePanelPressed:
        recorder.recordPress()
        presses.fulfill()
      case .wakeHealthProbeSucceeded:
        probeSucceeded.fulfill()
      case .rawReport, .sensePanelReleased, .pointerDelta, .terminated:
        break
      }
    }

    let pressed = try sensePanelPacket(
      featureIndex: snapshot.featureIndex,
      pressed: true
    )
    driver.enqueue(.success(pressed))
    try waitUntil("pre-sleep press was accepted") {
      recorder.pressCount == 1
    }
    backend.suspendInputForSleep()
    backend.requestHealthProbe(generation: 1)
    driver.enqueue(.success(pressed))

    wait(for: [presses, probeSucceeded], timeout: 2)
    try backend.stop()
  }

  func testDisplayWakeRearmsPressEdgeWithoutRequestingHealthProbe() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 5,
      healthProbeInterval: 3_600
    )
    let presses = expectation(description: "pre-display-sleep and post-display-wake presses")
    presses.expectedFulfillmentCount = 2
    let recorder = SensePanelEdgeRecorder()

    try backend.start { event in
      if case .sensePanelPressed = event {
        recorder.recordPress()
        presses.fulfill()
      }
    }

    let pressed = try sensePanelPacket(
      featureIndex: snapshot.featureIndex,
      pressed: true
    )
    driver.enqueue(.success(pressed))
    try waitUntil("pre-display-sleep press was accepted") {
      recorder.pressCount == 1
    }
    backend.suspendInputForSleep()
    backend.resumeInputAfterSleep()
    driver.enqueue(.success(pressed))

    wait(for: [presses], timeout: 2)
    try backend.stop()
  }

  func testJournalsBeforeApplyAndRestoresExactlyOnCleanStop() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 10
    )

    try backend.start { _ in }
    XCTAssertTrue(backend.isActive)
    XCTAssertEqual(try journal.load(), snapshot)
    XCTAssertEqual(
      Array(driver.callSnapshot().prefix(3)),
      ["inspect", "prepare", "apply"]
    )

    try backend.stop()
    XCTAssertFalse(backend.isActive)
    XCTAssertNil(try journal.load())
    XCTAssertEqual(driver.callSnapshot().suffix(2), ["restore", "close"])
  }

  func testRecoversPriorJournalBeforeTakingNewDiversion() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    try journal.save(snapshot)
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 10
    )

    try backend.start { _ in }
    XCTAssertEqual(
      Array(driver.callSnapshot().prefix(4)),
      ["inspect", "restore", "prepare", "apply"]
    )
    try backend.stop()
    XCTAssertNil(try journal.load())
  }

  func testRecoverySurvivesRegistryIDChangeForSameStablePhysicalDevice() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let priorSnapshot = try makeDiversionSnapshot(registryID: 42)
    let currentSnapshot = try makeDiversionSnapshot(
      registryID: 99,
      featureIndex: 0x2D
    )
    let driver = FakeMXMaster4Driver(
      snapshot: currentSnapshot,
      stableDeviceIdentity: "sha256:mouse-a"
    )
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    try journal.save(
      priorSnapshot,
      stableDeviceIdentity: "sha256:mouse-a"
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 10
    )

    try backend.start { _ in }
    let restored = try XCTUnwrap(driver.restoredSnapshots.first)
    XCTAssertEqual(restored.deviceRegistryID, 99)
    XCTAssertEqual(restored.featureIndex, 0x2D)
    XCTAssertEqual(restored.originalReporting, priorSnapshot.originalReporting)
    XCTAssertEqual(try journal.load(), currentSnapshot)
    XCTAssertEqual(try journal.loadEntry()?.stableDeviceIdentity, "sha256:mouse-a")

    try backend.stop()
    XCTAssertNil(try journal.load())
  }

  func testRecoveryRefusesWrongSameModelDeviceAndKeepsJournal() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let priorSnapshot = try makeDiversionSnapshot(registryID: 42)
    let currentSnapshot = try makeDiversionSnapshot(registryID: 99)
    let driver = FakeMXMaster4Driver(
      snapshot: currentSnapshot,
      stableDeviceIdentity: "sha256:mouse-b"
    )
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    try journal.save(
      priorSnapshot,
      stableDeviceIdentity: "sha256:mouse-a"
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 10
    )

    XCTAssertThrowsError(try backend.start { _ in }) { error in
      XCTAssertEqual(
        error as? MouseDaemonError,
        .diversionRecoveryDeviceIdentityMismatch
      )
    }
    XCTAssertTrue(driver.restoredSnapshots.isEmpty)
    XCTAssertEqual(try journal.load(), priorSnapshot)
    XCTAssertEqual(try journal.loadEntry()?.stableDeviceIdentity, "sha256:mouse-a")
  }

  func testLegacyJournalWithChangedRegistryIDFailsClosedAndIsPreserved() throws {
    struct LegacyRecord: Encodable {
      let version = 1
      let snapshot: SensePanelDiversionSnapshot
    }

    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let journalURL = directory.appending(path: "diversion.json")
    let priorSnapshot = try makeDiversionSnapshot(registryID: 42)
    try JSONEncoder().encode(
      LegacyRecord(snapshot: priorSnapshot)
    ).write(to: journalURL, options: .atomic)
    XCTAssertEqual(chmod(journalURL.path, 0o600), 0)

    let driver = FakeMXMaster4Driver(
      snapshot: try makeDiversionSnapshot(registryID: 99),
      stableDeviceIdentity: "sha256:mouse-a"
    )
    let journal = try SensePanelDiversionJournalStore(url: journalURL)
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 10
    )

    XCTAssertThrowsError(try backend.start { _ in }) { error in
      XCTAssertEqual(
        error as? MouseDaemonError,
        .diversionRecoveryDeviceMismatch(expected: 42, actual: 99)
      )
    }
    XCTAssertTrue(driver.restoredSnapshots.isEmpty)
    XCTAssertEqual(try journal.loadEntry()?.schemaVersion, 1)
    XCTAssertEqual(try journal.load(), priorSnapshot)
  }

  func testFailedApplyRestoresAndClearsJournalBeforeReturningError() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    driver.setFailApply(true)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 10
    )

    XCTAssertThrowsError(try backend.start { _ in })
    XCTAssertFalse(backend.isActive)
    XCTAssertNil(try journal.load())
    XCTAssertEqual(
      Array(driver.callSnapshot().prefix(5)),
      ["inspect", "prepare", "apply", "restore", "close"]
    )
  }

  func testEventReadFailureEmitsTerminationAndRestores() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 10
    )
    let terminated = expectation(description: "termination event")

    try backend.start { event in
      if case .terminated = event {
        terminated.fulfill()
      }
    }
    driver.enqueue(.failure(TestDriverError.eventRead))
    wait(for: [terminated], timeout: 1)

    let deadline = Date().addingTimeInterval(1)
    while backend.isActive, Date() < deadline {
      usleep(1_000)
    }
    XCTAssertFalse(backend.isActive)
    XCTAssertNil(try journal.load())
    XCTAssertEqual(driver.callSnapshot().suffix(2), ["restore", "close"])
  }

  func testFailedRestorationKeepsRecoveryJournal() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 10
    )

    try backend.start { _ in }
    driver.setFailRestore(true)
    XCTAssertThrowsError(try backend.stop()) { error in
      guard case MouseDaemonError.restorationFailed = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try journal.load(), snapshot)
  }

  func testHealthProbeReappliesSilentlyDroppedDiversion() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 5,
      healthProbeInterval: 0.02
    )

    try backend.start { _ in }
    try waitUntil("first probe ran") {
      driver.callSnapshot().contains("reporting-state")
    }
    XCTAssertEqual(driver.callSnapshot().filter { $0 == "apply" }.count, 1)

    driver.dropDiversion()
    try waitUntil("diversion re-applied") {
      driver.callSnapshot().filter { $0 == "apply" }.count >= 2
    }
    XCTAssertTrue(backend.isActive, "a re-applied diversion must not end the session")
    try backend.stop()
  }

  func testSleepJumpTriggersImmediateProbeDespiteLongInterval() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let wallClockOffset = WallClockOffset()
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 5,
      healthProbeInterval: 3_600,
      wallClockProvider: { Date().addingTimeInterval(wallClockOffset.value) }
    )

    try backend.start { _ in }
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertFalse(
      driver.callSnapshot().contains("reporting-state"),
      "an hour-long interval must not probe during a short awake run"
    )

    driver.dropDiversion()
    // The wall clock leaps while uptime does not: the machine slept.
    wallClockOffset.value = 120
    try waitUntil("post-wake probe re-applied the diversion") {
      driver.callSnapshot().filter { $0 == "apply" }.count >= 2
    }
    try backend.stop()
  }

  func testRequestedWakeProbeRunsImmediatelyDespiteLongInterval() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 5,
      healthProbeInterval: 3_600
    )

    try backend.start { _ in }
    Thread.sleep(forTimeInterval: 0.05)
    XCTAssertFalse(driver.callSnapshot().contains("reporting-state"))

    driver.dropDiversion()
    backend.requestHealthProbe(generation: 1)
    try waitUntil("requested wake probe re-applied the diversion") {
      driver.callSnapshot().filter { $0 == "apply" }.count >= 2
    }
    try backend.stop()
  }

  func testHealthProbeFailureTerminatesSessionForSupervisorReconnect() throws {
    let directory = try makePrivateTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = try makeDiversionSnapshot()
    let driver = FakeMXMaster4Driver(snapshot: snapshot)
    let journal = try SensePanelDiversionJournalStore(
      url: directory.appending(path: "diversion.json")
    )
    let backend = try MXMaster4HIDBackend(
      driverFactory: FakeMXMaster4DriverFactory(driver: driver),
      journal: journal,
      eventPollMilliseconds: 5,
      healthProbeInterval: 0.02
    )
    let terminated = expectation(description: "session terminated")

    try backend.start { event in
      if case .terminated = event {
        terminated.fulfill()
      }
    }
    try waitUntil("first probe ran") {
      driver.callSnapshot().contains("reporting-state")
    }
    driver.setFailReporting(true)
    wait(for: [terminated], timeout: 2)
    try waitUntil("session cleaned up") { !backend.isActive }
  }

  private func waitUntil(
    _ what: String,
    deadline: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
  ) throws {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
      if condition() { return }
      Thread.sleep(forTimeInterval: 0.005)
    }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
    throw POSIXError(.ETIMEDOUT)
  }
}

private final class WallClockOffset: @unchecked Sendable {
  private let lock = NSLock()
  private var offset: TimeInterval = 0

  var value: TimeInterval {
    get {
      lock.lock()
      defer { lock.unlock() }
      return offset
    }
    set {
      lock.lock()
      offset = newValue
      lock.unlock()
    }
  }
}

private final class SensePanelEdgeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var presses = 0
  private var releases = 0

  var pressCount: Int {
    lock.withLock { presses }
  }

  var releaseCount: Int {
    lock.withLock { releases }
  }

  func recordPress() {
    lock.withLock { presses += 1 }
  }

  func recordRelease() {
    lock.withLock { releases += 1 }
  }
}

private final class PointerDeltaRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Vector2] = []

  var deltas: [Vector2] {
    lock.withLock { storage }
  }

  func append(_ delta: Vector2) {
    lock.withLock { storage.append(delta) }
  }
}

private func sensePanelPacket(
  featureIndex: UInt8,
  pressed: Bool
) throws -> HIDPPPacket {
  try HIDPPPacket(
    featureIndex: featureIndex,
    functionID: 0,
    softwareID: 0,
    parameters: pressed ? [0x01, 0xA0] : [0, 0]
  )
}

private func rawXYPacket(
  featureIndex: UInt8,
  dx: Int16,
  dy: Int16
) throws -> HIDPPPacket {
  let dxBits = UInt16(bitPattern: dx)
  let dyBits = UInt16(bitPattern: dy)
  return try HIDPPPacket(
    featureIndex: featureIndex,
    functionID: 1,
    softwareID: 0,
    parameters: [
      UInt8(truncatingIfNeeded: dxBits >> 8),
      UInt8(truncatingIfNeeded: dxBits),
      UInt8(truncatingIfNeeded: dyBits >> 8),
      UInt8(truncatingIfNeeded: dyBits),
    ]
  )
}

private func makePrivateTemporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "logi-liquid-daemon-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  guard chmod(directory.path, 0o700) == 0 else {
    throw POSIXError(.EIO)
  }
  return directory
}
