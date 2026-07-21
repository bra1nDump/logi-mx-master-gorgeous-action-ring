import AppKit
import Foundation
import ImageIO
import LogiLiquidCore
import XCTest

@testable import LogiLiquidGym

final class GymRendererTests: XCTestCase {
  private let compactConfiguration = GymRenderConfiguration(
    logicalWidth: 360,
    logicalHeight: 360,
    scale: 1
  )

  func testDemoTimelineCoversTeaseDismissRebloomCommitAndRecording() throws {
    let configuration = GymDemoConfiguration(
      pixelWidth: 900,
      pixelHeight: 600,
      framesPerSecond: 30
    )
    let timeline = try GymDemoTimeline(configuration: configuration)
    let frames = (0..<configuration.frameCount).map(timeline.frame(at:))

    XCTAssertEqual(configuration.frameCount, 225)
    XCTAssertEqual(Set(frames.map(\.phase)), Set(GymDemoPhase.allCases))

    // The first frame already shows the bloomed ring, so the result is
    // visible immediately.
    let first = try XCTUnwrap(frames.first)
    XCTAssertEqual(first.phase, .bloom)
    XCTAssertFalse(first.cursorVisible)
    XCTAssertEqual(first.overallOpacity, 1)
    XCTAssertEqual(first.presentationProgress, 1)

    // The video ends on the recording HUD with the cursor back on the desktop.
    let last = try XCTUnwrap(frames.last)
    XCTAssertEqual(last.phase, .recording)
    XCTAssertTrue(last.cursorVisible)
    XCTAssertEqual(last.recordingProgress, 1)

    // Every buzz surfaces at its real moment: the toggle-close press, the
    // reopen press, and the haptic fired when the action latches.
    let buzzFrames = frames.filter { $0.buzzProgress > 0 }
    XCTAssertFalse(buzzFrames.isEmpty)
    XCTAssertTrue(buzzFrames.contains { $0.phase == .dismissing })
    XCTAssertTrue(buzzFrames.contains { $0.phase == .rebloom })
    XCTAssertTrue(buzzFrames.contains { $0.phase == .suction })

    // Act 1 never latches: the tease stops at a partial approach with no
    // metaball merge, then the ring dismisses and the cursor returns.
    let tease = try XCTUnwrap(frames.last { $0.phase == .tease })
    XCTAssertEqual(tease.activeTargetID, timeline.teaseTargetID)
    XCTAssertGreaterThan(tease.approachProgress, 0.1)
    XCTAssertLessThan(tease.approachProgress, 0.4)
    XCTAssertEqual(tease.mergeProgress, 0)
    let dwellFrames = frames.filter { $0.phase == .dwell }
    XCTAssertFalse(dwellFrames.isEmpty)
    XCTAssertTrue(dwellFrames.allSatisfy { $0.activeTargetID == timeline.teaseTargetID })
    let firstDismissing = try XCTUnwrap(frames.first { $0.phase == .dismissing })
    XCTAssertTrue(firstDismissing.cursorVisible)
    let desktop = try XCTUnwrap(frames.first { $0.phase == .desktop })
    XCTAssertTrue(desktop.cursorVisible)
    XCTAssertEqual(desktop.overallOpacity, 0)

    // The pointer hides while the ring is active in act 2 and returns after
    // the commit, matching the product's cursor hide/restore.
    let ringFrames = frames.filter {
      [.rebloom, .travel, .suction, .committed].contains($0.phase)
    }
    XCTAssertTrue(ringFrames.allSatisfy { !$0.cursorVisible })

    let travel = try XCTUnwrap(frames.last { $0.phase == .travel })
    let suction = try XCTUnwrap(frames.last { $0.phase == .suction })
    let committed = try XCTUnwrap(frames.first { $0.phase == .committed })
    XCTAssertEqual(travel.activeTargetID, timeline.commitTargetID)
    XCTAssertNotEqual(travel.bubbleOffset, .zero)
    XCTAssertGreaterThan(travel.mergeProgress, 0)
    XCTAssertGreaterThan(suction.mergeProgress, travel.mergeProgress)
    XCTAssertEqual(committed.bubbleOffset, timeline.commitTargetOffset)
    XCTAssertEqual(committed.mergeProgress, 1)
    XCTAssertEqual(committed.approachProgress, 1)

    // The travel endpoint is exactly Core's overlap latch boundary.
    let profile = RingInteractionProfile.default
    let thresholdDistance = hypot(
      timeline.latchThresholdOffset.x - timeline.commitTargetOffset.x,
      timeline.latchThresholdOffset.y - timeline.commitTargetOffset.y
    )
    XCTAssertEqual(
      CircleIntersectionGeometry.overlapFractionOfCircleA(
        radiusA: profile.movingBubbleRadius,
        radiusB: profile.targetBubbleRadius,
        centerDistance: thresholdDistance
      ),
      RingInteractionThresholds.latchOverlapFraction,
      accuracy: 0.000_001
    )
  }

  @MainActor
  func testCLIDemoWritesH264VideoAndPosterAtExactDimensions() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "gym-demo-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    var standardOutput = Data()
    var standardError = Data()
    let exitCode = await GymCLI(currentDirectory: directory).run(
      arguments: [
        "demo", "--output", "demo.mp4", "--poster", "poster.png",
        "--width", "320", "--height", "320", "--fps", "15",
      ],
      standardOutput: { standardOutput.append($0) },
      standardError: { standardError.append($0) }
    )

    XCTAssertEqual(exitCode, 0)
    XCTAssertTrue(standardError.isEmpty)
    let output = try JSONDecoder().decode(GymCLIOutput.self, from: standardOutput)
    XCTAssertEqual(output.command, "demo")
    XCTAssertTrue(output.ok)
    XCTAssertEqual(
      output.files,
      [
        directory.appending(path: "demo.mp4").path,
        directory.appending(path: "poster.png").path,
      ]
    )

    let videoURL = directory.appending(path: "demo.mp4")
    let artifact = try await GymDemoRenderer.inspect(videoURL)
    XCTAssertEqual(artifact.pixelWidth, 320)
    XCTAssertEqual(artifact.pixelHeight, 320)
    XCTAssertEqual(artifact.frameCount, 113)
    XCTAssertEqual(artifact.duration, 7.5, accuracy: 0.05)
    XCTAssertTrue(artifact.isH264)
    XCTAssertTrue(artifact.hasOpaqueBackground)
    XCTAssertGreaterThan(artifact.byteCount, 10_000)
    XCTAssertLessThan(artifact.byteCount, 5_000_000)

    let posterData = try Data(
      contentsOf: directory.appending(path: "poster.png")
    )
    let poster = try XCTUnwrap(NSBitmapImageRep(data: posterData))
    XCTAssertEqual(poster.pixelsWide, 320)
    XCTAssertEqual(poster.pixelsHigh, 320)
    try assertBackdropCoversEntireFrame(posterData)
  }

  func testRepresentativeScenariosComeFromRealCoreTransitions() throws {
    let size = CGSize(width: 720, height: 520)
    let invoked = try GymScenario.make(.invoked, logicalSize: size)
    let targeting = try GymScenario.make(.targeting, logicalSize: size)
    let latched = try GymScenario.make(.latchedSuctionThreshold, logicalSize: size)
    let committed = try GymScenario.make(.committed, logicalSize: size)

    XCTAssertEqual(invoked.transition.frame.phase, .invoked)
    XCTAssertNil(invoked.transition.frame.currentTarget)
    XCTAssertEqual(targeting.transition.frame.phase, .tracking)
    XCTAssertEqual(targeting.transition.frame.mergeProgress, 0.25, accuracy: 0.000_001)
    XCTAssertEqual(
      targeting.transition.frame.approachProgress,
      1 - (0.75 * RingInteractionProfile.default.mergeStartDistance)
        / RingInteractionProfile.default.ringRadius,
      accuracy: 0.000_001
    )
    XCTAssertEqual(latched.transition.frame.phase, .latched)
    XCTAssertEqual(latched.transition.frame.mergeProgress, 1, accuracy: 0.000_001)
    XCTAssertEqual(latched.transition.frame.approachProgress, 1, accuracy: 0.000_001)
    let latchedTarget = try XCTUnwrap(latched.transition.frame.currentTarget)
    let centerDistance = latched.transition.frame.accumulatedPointerDelta.distance(
      to: latchedTarget.vectorFromOrigin
    )
    XCTAssertEqual(
      CircleIntersectionGeometry.overlapFractionOfCircleA(
        radiusA: RingInteractionProfile.default.movingBubbleRadius,
        radiusB: RingInteractionProfile.default.targetBubbleRadius,
        centerDistance: centerDistance
      ),
      RingInteractionThresholds.latchOverlapFraction,
      accuracy: 0.000_001
    )
    XCTAssertEqual(latched.transition.actionToPerform?.name, "Mission Control")
    XCTAssertEqual(latched.transition.hapticIntent, .play(waveformID: 0))
    XCTAssertEqual(committed.transition.frame.phase, .committed)
    XCTAssertEqual(committed.transition.frame.mergeProgress, 1, accuracy: 0.000_001)
    XCTAssertNil(committed.transition.actionToPerform)
    XCTAssertEqual(committed.transition.cursorVisibilityIntent, .restore)
  }

  @MainActor
  func testWindowHostedRendererWritesNonemptyPNGAtExactDimensions() async throws {
    let image = try await GymRenderer().render(
      state: .latchedSuctionThreshold,
      configuration: compactConfiguration
    )

    XCTAssertEqual(image.pixelWidth, 360)
    XCTAssertEqual(image.pixelHeight, 360)
    XCTAssertGreaterThan(image.pngData.count, 1_000)

    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.pngData))
    XCTAssertEqual(bitmap.pixelsWide, 360)
    XCTAssertEqual(bitmap.pixelsHigh, 360)
    let bitmapData = try XCTUnwrap(bitmap.bitmapData)
    let bytes = UnsafeBufferPointer(
      start: bitmapData,
      count: bitmap.bytesPerRow * bitmap.pixelsHigh
    )
    XCTAssertGreaterThan(Set(bytes).count, 16, "render must contain real pixel variation")
  }

  @MainActor
  func testRecordThenVerifySnapshotWorkflow() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "gym-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let workflow = GymSnapshotWorkflow()
    let manifest = try await workflow.record(
      directory: directory,
      configuration: compactConfiguration
    )
    XCTAssertEqual(manifest.snapshots.map(\.state), GymSnapshotState.allCases)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appending(path: GymSnapshotWorkflow.manifestFileName).path
      )
    )
    for entry in manifest.snapshots {
      XCTAssertEqual(entry.pixelWidth, 360)
      XCTAssertEqual(entry.pixelHeight, 360)
      XCTAssertGreaterThan(entry.byteCount, 1_000)
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: directory.appending(path: entry.file).path
        )
      )
      try assertBackdropCoversEntireFrame(
        Data(contentsOf: directory.appending(path: entry.file))
      )
    }

    let differences = try await workflow.verify(directory: directory)
    XCTAssertEqual(differences.map(\.state), GymSnapshotState.allCases)
    XCTAssertTrue(differences.allSatisfy(\.passed))
  }

  @MainActor
  func testCLIListIsStableJSONForAgents() async throws {
    var standardOutput = Data()
    var standardError = Data()
    let exitCode = await GymCLI().run(
      arguments: ["list"],
      standardOutput: { standardOutput.append($0) },
      standardError: { standardError.append($0) }
    )

    XCTAssertEqual(exitCode, 0)
    XCTAssertTrue(standardError.isEmpty)
    let output = try JSONDecoder().decode(GymCLIOutput.self, from: standardOutput)
    XCTAssertEqual(output.command, "list")
    XCTAssertTrue(output.ok)
    XCTAssertEqual(output.files, GymSnapshotState.allCases.map(\.rawValue))
  }

  func testCheckedInSnapshotBaselinesCoverEntireFrame() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let snapshotDirectory = repositoryRoot.appending(
      path: "gym/visual/Snapshots",
      directoryHint: .isDirectory
    )

    for state in GymSnapshotState.allCases {
      let data = try Data(
        contentsOf: snapshotDirectory.appending(path: state.fileName)
      )
      try assertBackdropCoversEntireFrame(data)
    }
  }

  private func assertBackdropCoversEntireFrame(
    _ pngData: Data,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: pngData), file: file, line: line)
    let inset = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 64)
    let points = [
      NSPoint(x: inset, y: inset),
      NSPoint(x: bitmap.pixelsWide - inset - 1, y: inset),
      NSPoint(x: inset, y: bitmap.pixelsHigh - inset - 1),
      NSPoint(
        x: bitmap.pixelsWide - inset - 1,
        y: bitmap.pixelsHigh - inset - 1
      ),
      NSPoint(x: bitmap.pixelsWide / 2, y: inset),
      NSPoint(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - inset - 1),
      NSPoint(x: inset, y: bitmap.pixelsHigh / 2),
      NSPoint(x: bitmap.pixelsWide - inset - 1, y: bitmap.pixelsHigh / 2),
    ]

    for point in points {
      let color = try XCTUnwrap(
        bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB),
        file: file,
        line: line
      )
      let brightestChannel = max(color.redComponent, color.greenComponent, color.blueComponent)
      XCTAssertGreaterThan(
        brightestChannel,
        0.025,
        "deterministic backdrop must reach every edge; found a black margin at \(point)",
        file: file,
        line: line
      )
      XCTAssertGreaterThan(color.alphaComponent, 0.99, file: file, line: line)
    }
  }
}
