import AppKit
import Foundation
import ImageIO
import LogiLiquidCore
import XCTest

@testable import LogiLiquidJim

final class JimRendererTests: XCTestCase {
  private let compactConfiguration = JimRenderConfiguration(
    logicalWidth: 360,
    logicalHeight: 360,
    scale: 1
  )

  func testDemoTimelineCoversInvocationMovementSuctionCommitAndDismiss() throws {
    let configuration = JimDemoConfiguration(
      pixelWidth: 900,
      pixelHeight: 600,
      framesPerSecond: 30
    )
    let timeline = try JimDemoTimeline(configuration: configuration)
    let frames = (0..<configuration.frameCount).map(timeline.frame(at:))

    XCTAssertEqual(configuration.frameCount, 96)
    XCTAssertEqual(Set(frames.map(\.phase)), Set(JimDemoPhase.allCases))
    XCTAssertEqual(frames.first?.overallOpacity, 0)
    XCTAssertEqual(frames.last?.phase, .hidden)
    XCTAssertEqual(frames.last?.overallOpacity, 0)

    let travel = try XCTUnwrap(frames.last { $0.phase == .travel })
    let suction = try XCTUnwrap(frames.last { $0.phase == .suction })
    let committed = try XCTUnwrap(frames.first { $0.phase == .committed })
    XCTAssertNotEqual(travel.bubbleOffset, .zero)
    XCTAssertGreaterThan(travel.mergeProgress, 0)
    XCTAssertGreaterThan(suction.mergeProgress, travel.mergeProgress)
    XCTAssertEqual(committed.bubbleOffset, timeline.selectedTargetOffset)
    XCTAssertEqual(committed.mergeProgress, 1)

    let profile = RingInteractionProfile.default
    let thresholdDistance = hypot(
      timeline.latchThresholdOffset.x - timeline.selectedTargetOffset.x,
      timeline.latchThresholdOffset.y - timeline.selectedTargetOffset.y
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

    let encodedDuration = (0..<configuration.frameCount).reduce(0.0) {
      $0 + configuration.encodedFrameDelay(at: $1)
    }
    XCTAssertEqual(encodedDuration, configuration.duration, accuracy: 0.000_001)
    let firstDelays = (0..<3).map(configuration.encodedFrameDelay(at:))
    XCTAssertEqual(firstDelays[0], 0.03, accuracy: 0.000_001)
    XCTAssertEqual(firstDelays[1], 0.03, accuracy: 0.000_001)
    XCTAssertEqual(firstDelays[2], 0.04, accuracy: 0.000_001)
  }

  @MainActor
  func testCLIDemoWritesLoopingTransparentGIFAtExactDimensions() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "jim-demo-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    var standardOutput = Data()
    var standardError = Data()
    let exitCode = await JimCLI(currentDirectory: directory).run(
      arguments: [
        "demo", "--output", "demo.gif", "--width", "320", "--height", "320", "--fps", "15",
      ],
      standardOutput: { standardOutput.append($0) },
      standardError: { standardError.append($0) }
    )

    XCTAssertEqual(exitCode, 0)
    XCTAssertTrue(standardError.isEmpty)
    let output = try JSONDecoder().decode(JimCLIOutput.self, from: standardOutput)
    XCTAssertEqual(output.command, "demo")
    XCTAssertTrue(output.ok)

    let gifURL = directory.appending(path: "demo.gif")
    let artifact = try JimDemoRenderer.inspect(gifURL)
    XCTAssertEqual(artifact.pixelWidth, 320)
    XCTAssertEqual(artifact.pixelHeight, 320)
    XCTAssertEqual(artifact.frameCount, 48)
    XCTAssertEqual(artifact.loopCount, 0)
    XCTAssertEqual(artifact.frameDelay, 1.0 / 15.0, accuracy: 0.001)
    XCTAssertTrue(artifact.hasTransparentBackground)
    XCTAssertGreaterThan(artifact.byteCount, 10_000)
    XCTAssertLessThan(artifact.byteCount, 2_000_000)

    let source = try XCTUnwrap(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
    let visibleFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 10, nil))
    let bitmap = NSBitmapImageRep(cgImage: visibleFrame)
    XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
    XCTAssertGreaterThan(
      try XCTUnwrap(bitmap.colorAt(x: 160, y: 160)).alphaComponent,
      0.9,
      "a visible invocation frame must contain the moving bubble"
    )
  }

  func testRepresentativeScenariosComeFromRealCoreTransitions() throws {
    let size = CGSize(width: 720, height: 520)
    let invoked = try JimScenario.make(.invoked, logicalSize: size)
    let targeting = try JimScenario.make(.targeting, logicalSize: size)
    let latched = try JimScenario.make(.latchedSuctionThreshold, logicalSize: size)
    let committed = try JimScenario.make(.committed, logicalSize: size)

    XCTAssertEqual(invoked.transition.frame.phase, .invoked)
    XCTAssertNil(invoked.transition.frame.currentTarget)
    XCTAssertEqual(targeting.transition.frame.phase, .tracking)
    XCTAssertEqual(targeting.transition.frame.mergeProgress, 0.25, accuracy: 0.000_001)
    XCTAssertEqual(latched.transition.frame.phase, .latched)
    XCTAssertEqual(latched.transition.frame.mergeProgress, 1, accuracy: 0.000_001)
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
    XCTAssertEqual(latched.transition.actionToPerform?.name, "Play Spotify")
    XCTAssertEqual(latched.transition.hapticIntent, .play(waveformID: 0))
    XCTAssertEqual(committed.transition.frame.phase, .committed)
    XCTAssertEqual(committed.transition.frame.mergeProgress, 1, accuracy: 0.000_001)
    XCTAssertNil(committed.transition.actionToPerform)
    XCTAssertEqual(committed.transition.cursorVisibilityIntent, .restore)
  }

  @MainActor
  func testWindowHostedRendererWritesNonemptyPNGAtExactDimensions() async throws {
    let image = try await JimRenderer().render(
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
      path: "jim-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let workflow = JimSnapshotWorkflow()
    let manifest = try await workflow.record(
      directory: directory,
      configuration: compactConfiguration
    )
    XCTAssertEqual(manifest.snapshots.map(\.state), JimSnapshotState.allCases)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appending(path: JimSnapshotWorkflow.manifestFileName).path
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
    XCTAssertEqual(differences.map(\.state), JimSnapshotState.allCases)
    XCTAssertTrue(differences.allSatisfy(\.passed))
  }

  @MainActor
  func testCLIListIsStableJSONForAgents() async throws {
    var standardOutput = Data()
    var standardError = Data()
    let exitCode = await JimCLI().run(
      arguments: ["list"],
      standardOutput: { standardOutput.append($0) },
      standardError: { standardError.append($0) }
    )

    XCTAssertEqual(exitCode, 0)
    XCTAssertTrue(standardError.isEmpty)
    let output = try JSONDecoder().decode(JimCLIOutput.self, from: standardOutput)
    XCTAssertEqual(output.command, "list")
    XCTAssertTrue(output.ok)
    XCTAssertEqual(output.files, JimSnapshotState.allCases.map(\.rawValue))
  }

  func testCheckedInSnapshotBaselinesCoverEntireFrame() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let snapshotDirectory = repositoryRoot.appending(
      path: "jim/Snapshots",
      directoryHint: .isDirectory
    )

    for state in JimSnapshotState.allCases {
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
