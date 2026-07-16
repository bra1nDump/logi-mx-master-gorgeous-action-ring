import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LogiLiquidCore
import LogiLiquidUI
import QuartzCore
import ScreenCaptureKit
import SwiftUI

/// Deterministic output settings for the transparent CommandBloom demo.
public struct JimDemoConfiguration: Codable, Equatable, Sendable {
  public static let `default` = JimDemoConfiguration(
    pixelWidth: 1_200,
    pixelHeight: 800,
    framesPerSecond: 60,
    duration: 3.2
  )

  public let pixelWidth: Int
  public let pixelHeight: Int
  public let framesPerSecond: Int
  public let duration: Double

  public init(
    pixelWidth: Int,
    pixelHeight: Int,
    framesPerSecond: Int,
    duration: Double = 3.2
  ) {
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.framesPerSecond = framesPerSecond
    self.duration = duration
  }

  public var frameCount: Int {
    Int((duration * Double(framesPerSecond)).rounded())
  }

  public var frameDelay: Double {
    1 / Double(framesPerSecond)
  }

  /// GIF timing is stored in centiseconds. Distributing adjacent centisecond
  /// delays preserves the requested average frame rate without timing drift.
  public func encodedFrameDelay(at index: Int) -> Double {
    let startTick = Int(
      (Double(index) * 100 / Double(framesPerSecond)).rounded(.down)
    )
    let endTick = Int(
      (Double(index + 1) * 100 / Double(framesPerSecond)).rounded(.down)
    )
    return Double(max(1, endTick - startTick)) / 100
  }

  public func validate() throws {
    guard (320...1_920).contains(pixelWidth) else {
      throw JimError.invalidDimension(name: "demo width", value: pixelWidth)
    }
    guard (320...1_200).contains(pixelHeight) else {
      throw JimError.invalidDimension(name: "demo height", value: pixelHeight)
    }
    guard (12...60).contains(framesPerSecond) else {
      throw JimError.invalidFrameRate(framesPerSecond)
    }
    guard duration.isFinite, (2...8).contains(duration) else {
      throw JimError.invalidDuration(duration)
    }
  }
}

@MainActor
private final class JimDemoWindowHost {
  private let timeline: JimDemoTimeline
  private let window: NSWindow
  private let hostingView: NSHostingView<JimDemoOverlayScene>
  private let shareableWindow: SCWindow
  private let captureConfiguration: SCStreamConfiguration

  init(timeline: JimDemoTimeline) async throws {
    self.timeline = timeline
    let configuration = timeline.configuration
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    application.appearance = NSAppearance(named: .darkAqua)
    application.finishLaunching()

    let firstScene = JimDemoOverlayScene(
      frame: timeline.frame(at: 0),
      timeline: timeline
    )
    hostingView = NSHostingView(rootView: firstScene)
    let contentFrame = CGRect(
      x: 0,
      y: 0,
      width: configuration.pixelWidth,
      height: configuration.pixelHeight
    )
    hostingView.frame = contentFrame
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor

    window = NSWindow(
      contentRect: contentFrame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.appearance = NSAppearance(named: .darkAqua)
    window.collectionBehavior = [.stationary]
    window.level = .floating
    let windowTitle = "Jim CommandBloom Demo \(UUID().uuidString)"
    window.title = windowTitle
    if let screen = NSScreen.screens.max(by: {
      $0.visibleFrame.width * $0.visibleFrame.height
        < $1.visibleFrame.width * $1.visibleFrame.height
    }) {
      window.setFrame(
        CGRect(
          x: screen.visibleFrame.midX - (contentFrame.width / 2),
          y: screen.visibleFrame.midY - (contentFrame.height / 2),
          width: contentFrame.width,
          height: contentFrame.height
        ),
        display: false
      )
    }
    window.contentView = hostingView
    window.orderFrontRegardless()
    window.displayIfNeeded()

    let windowID = CGWindowID(window.windowNumber)
    var resolvedWindow: SCWindow?
    for _ in 0..<30 {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: false
      )
      resolvedWindow = content.windows.first(where: {
        $0.windowID == windowID && $0.title == windowTitle
      })
      if resolvedWindow != nil { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard let resolvedWindow else {
      window.orderOut(nil)
      window.close()
      throw JimError.hostedWindowUnavailable(window.windowNumber)
    }
    shareableWindow = resolvedWindow

    captureConfiguration = SCStreamConfiguration()
    captureConfiguration.width = configuration.pixelWidth
    captureConfiguration.height = configuration.pixelHeight
    captureConfiguration.showsCursor = false
    captureConfiguration.capturesAudio = false
    captureConfiguration.ignoreShadowsSingleWindow = true
    captureConfiguration.shouldBeOpaque = false
    try await Task.sleep(for: .milliseconds(100))
  }

  func capture(_ frame: JimDemoFrame) async throws -> CGImage {
    hostingView.rootView = JimDemoOverlayScene(frame: frame, timeline: timeline)
    hostingView.layoutSubtreeIfNeeded()
    hostingView.needsDisplay = true
    hostingView.displayIfNeeded()
    window.displayIfNeeded()
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(8))

    let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
    return try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: captureConfiguration
    )
  }

  func close() {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }
}

private struct JimDemoOverlayScene: View {
  let frame: JimDemoFrame
  let timeline: JimDemoTimeline

  var body: some View {
    let configuration = timeline.configuration
    OverlayView(
      model: model,
      localOrigin: CGPoint(
        x: CGFloat(configuration.pixelWidth) / 2,
        y: CGFloat(configuration.pixelHeight) / 2
      ),
      presentationProgress: CGFloat(frame.presentationProgress),
      onPrimaryClick: {}
    )
    .frame(
      width: CGFloat(configuration.pixelWidth),
      height: CGFloat(configuration.pixelHeight)
    )
    .scaleEffect(sceneScale)
    .opacity(frame.overallOpacity)
    .transaction { transaction in
      transaction.animation = nil
      transaction.disablesAnimations = true
    }
  }

  private var sceneScale: CGFloat {
    min(
      CGFloat(timeline.configuration.pixelWidth) / 600,
      CGFloat(timeline.configuration.pixelHeight) / 400
    )
  }

  private var model: OverlayRenderModel {
    let isSelected = frame.selectionStrength > 0.5
    let targets = timeline.targets.map { target in
      OverlayTargetModel(
        id: target.id,
        actionName: target.actionName,
        zone: target.zone,
        presentation: target.presentation,
        offset: target.offset,
        isCurrent: target.id == timeline.selectedTargetID && isSelected
      )
    }
    let phase: RingInteractionPhase =
      switch frame.phase {
      case .invocation: .invoked
      case .travel: .tracking
      case .suction, .committed, .dismissing: .latched
      case .hidden: .idle
      }
    return OverlayRenderModel(
      phase: phase,
      cgOrigin: .zero,
      targets: targets,
      bubbleOffset: frame.bubbleOffset,
      mergeProgress: frame.mergeProgress,
      currentTargetID: isSelected ? timeline.selectedTargetID : nil
    )
  }
}

public enum JimDemoPhase: String, CaseIterable, Sendable {
  case invocation
  case travel
  case suction
  case committed
  case dismissing
  case hidden
}

/// One deterministic visual frame. Geometry remains in the production
/// overlay's logical point space and is scaled only by the native renderer.
public struct JimDemoFrame: Equatable, Sendable {
  public let index: Int
  public let phase: JimDemoPhase
  public let presentationProgress: Double
  public let overallOpacity: Double
  public let bubbleOffset: CGPoint
  public let mergeProgress: Double
  public let selectionStrength: Double
  public let invocationPulse: Double
  public let commitPulse: Double

  public init(
    index: Int,
    phase: JimDemoPhase,
    presentationProgress: Double,
    overallOpacity: Double,
    bubbleOffset: CGPoint,
    mergeProgress: Double,
    selectionStrength: Double,
    invocationPulse: Double,
    commitPulse: Double
  ) {
    self.index = index
    self.phase = phase
    self.presentationProgress = presentationProgress
    self.overallOpacity = overallOpacity
    self.bubbleOffset = bubbleOffset
    self.mergeProgress = mergeProgress
    self.selectionStrength = selectionStrength
    self.invocationPulse = invocationPulse
    self.commitPulse = commitPulse
  }
}

/// A clock-free animation authored from the real Core/Jim scenarios. It starts
/// at a transparent frame, invokes the bloom, moves to Core's configured overlap
/// boundary, performs the 160 ms suction, commits, and dismisses to transparent.
public struct JimDemoTimeline: Sendable {
  private enum Timing {
    static let invocationEnd = 0.48
    static let travelStart = 0.62
    static let travelEnd = 1.62
    static let suctionEnd = 1.78
    static let dismissStart = 2.24
    static let dismissEnd = 2.62
  }

  public let configuration: JimDemoConfiguration
  public let targets: [OverlayTargetModel]
  public let selectedTargetID: String
  public let selectedTargetOffset: CGPoint
  public let latchThresholdOffset: CGPoint

  public init(configuration: JimDemoConfiguration = .default) throws {
    try configuration.validate()
    let logicalSize = CGSize(width: configuration.pixelWidth, height: configuration.pixelHeight)
    let invoked = try JimScenario.make(.invoked, logicalSize: logicalSize)
    let latched = try JimScenario.make(.latchedSuctionThreshold, logicalSize: logicalSize)
    guard
      let selected = invoked.model.targets.first(where: { $0.zone == .top }),
      latched.transition.frame.phase == .latched
    else {
      throw JimError.invalidDemoScenario
    }

    self.configuration = configuration
    targets = invoked.model.targets
    selectedTargetID = selected.id
    selectedTargetOffset = selected.offset
    latchThresholdOffset = CGPoint(
      x: latched.transition.frame.accumulatedPointerDelta.x,
      y: latched.transition.frame.accumulatedPointerDelta.y
    )
  }

  public func frame(at index: Int) -> JimDemoFrame {
    let clampedIndex = min(max(index, 0), configuration.frameCount - 1)
    let time = Double(clampedIndex) / Double(configuration.framesPerSecond)

    if time < Timing.invocationEnd {
      let progress = Self.smoothstep(time / Timing.invocationEnd)
      return JimDemoFrame(
        index: clampedIndex,
        phase: .invocation,
        presentationProgress: progress,
        overallOpacity: min(1, progress * 1.7),
        bubbleOffset: .zero,
        mergeProgress: 0,
        selectionStrength: 0,
        invocationPulse: progress,
        commitPulse: 0
      )
    }

    if time < Timing.travelStart {
      return steadyFrame(index: clampedIndex, phase: .invocation)
    }

    if time < Timing.travelEnd {
      let progress = Self.smootherstep(
        (time - Timing.travelStart) / (Timing.travelEnd - Timing.travelStart)
      )
      // A restrained lateral arc makes pointer motion legible without changing
      // the exact terminal overlap point used by Core.
      let lateralArc = 10 * sin(.pi * progress)
      let offset = CGPoint(
        x: Self.interpolate(0, latchThresholdOffset.x, progress) + lateralArc,
        y: Self.interpolate(0, latchThresholdOffset.y, progress)
      )
      return JimDemoFrame(
        index: clampedIndex,
        phase: .travel,
        presentationProgress: 1,
        overallOpacity: 1,
        bubbleOffset: offset,
        mergeProgress: mergeProgress(at: offset),
        selectionStrength: Self.smoothstep((progress - 0.08) / 0.28),
        invocationPulse: 1,
        commitPulse: 0
      )
    }

    if time < Timing.suctionEnd {
      let progress = Self.smootherstep(
        (time - Timing.travelEnd) / (Timing.suctionEnd - Timing.travelEnd)
      )
      let thresholdMerge = mergeProgress(at: latchThresholdOffset)
      return JimDemoFrame(
        index: clampedIndex,
        phase: .suction,
        presentationProgress: 1,
        overallOpacity: 1,
        bubbleOffset: Self.interpolate(latchThresholdOffset, selectedTargetOffset, progress),
        mergeProgress: Self.interpolate(thresholdMerge, 1, progress),
        selectionStrength: 1,
        invocationPulse: 1,
        commitPulse: 0
      )
    }

    if time < Timing.dismissStart {
      let progress = (time - Timing.suctionEnd) / (Timing.dismissStart - Timing.suctionEnd)
      return JimDemoFrame(
        index: clampedIndex,
        phase: .committed,
        presentationProgress: 1,
        overallOpacity: 1,
        bubbleOffset: selectedTargetOffset,
        mergeProgress: 1,
        selectionStrength: 1,
        invocationPulse: 1,
        commitPulse: min(max(progress, 0), 1)
      )
    }

    if time < Timing.dismissEnd {
      let progress = Self.smootherstep(
        (time - Timing.dismissStart) / (Timing.dismissEnd - Timing.dismissStart)
      )
      return JimDemoFrame(
        index: clampedIndex,
        phase: .dismissing,
        presentationProgress: 1 - (0.12 * progress),
        overallOpacity: 1 - progress,
        bubbleOffset: selectedTargetOffset,
        mergeProgress: 1,
        selectionStrength: 1 - progress,
        invocationPulse: 1,
        commitPulse: 1
      )
    }

    return JimDemoFrame(
      index: clampedIndex,
      phase: .hidden,
      presentationProgress: 0,
      overallOpacity: 0,
      bubbleOffset: .zero,
      mergeProgress: 0,
      selectionStrength: 0,
      invocationPulse: 0,
      commitPulse: 0
    )
  }

  private func steadyFrame(index: Int, phase: JimDemoPhase) -> JimDemoFrame {
    JimDemoFrame(
      index: index,
      phase: phase,
      presentationProgress: 1,
      overallOpacity: 1,
      bubbleOffset: .zero,
      mergeProgress: 0,
      selectionStrength: 0,
      invocationPulse: 1,
      commitPulse: 0
    )
  }

  private func mergeProgress(at offset: CGPoint) -> Double {
    let distance = hypot(
      offset.x - selectedTargetOffset.x,
      offset.y - selectedTargetOffset.y
    )
    return min(max(1 - (distance / RingInteractionProfile.default.mergeStartDistance), 0), 1)
  }

  private static func interpolate(_ start: Double, _ end: Double, _ progress: Double) -> Double {
    start + ((end - start) * progress)
  }

  private static func interpolate(
    _ start: CGPoint,
    _ end: CGPoint,
    _ progress: Double
  ) -> CGPoint {
    CGPoint(
      x: interpolate(start.x, end.x, progress),
      y: interpolate(start.y, end.y, progress)
    )
  }

  private static func smoothstep(_ value: Double) -> Double {
    let value = min(max(value, 0), 1)
    return value * value * (3 - (2 * value))
  }

  private static func smootherstep(_ value: Double) -> Double {
    let value = min(max(value, 0), 1)
    return value * value * value * (value * ((value * 6) - 15) + 10)
  }
}

public struct JimDemoArtifact: Codable, Equatable, Sendable {
  public let url: URL
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let frameCount: Int
  public let loopCount: Int
  public let frameDelay: Double
  public let byteCount: Int
  public let hasTransparentBackground: Bool
}

/// Native Jim renderer for the production `OverlayView`. It captures only its
/// dedicated transparent AppKit window; desktop windows are never in scope.
@MainActor
public final class JimDemoRenderer {
  private static let gifType = "com.compuserve.gif" as CFString

  public init() {}

  public func render(
    to output: URL,
    configuration: JimDemoConfiguration = .default
  ) async throws -> JimDemoArtifact {
    let timeline = try JimDemoTimeline(configuration: configuration)
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: output)

    guard
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL,
        Self.gifType,
        configuration.frameCount,
        nil
      )
    else {
      throw JimError.gifDestinationCreationFailed
    }

    CGImageDestinationSetProperties(
      destination,
      [
        kCGImagePropertyGIFDictionary: [
          kCGImagePropertyGIFLoopCount: 0
        ]
      ] as CFDictionary
    )
    let host = try await JimDemoWindowHost(timeline: timeline)
    defer { host.close() }
    for index in 0..<configuration.frameCount {
      let image = try await host.capture(timeline.frame(at: index))
      let delay = configuration.encodedFrameDelay(at: index)
      let frameProperties =
        [
          kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay,
            kCGImagePropertyGIFUnclampedDelayTime: delay,
          ]
        ] as CFDictionary
      CGImageDestinationAddImage(destination, image, frameProperties)
    }
    guard CGImageDestinationFinalize(destination) else {
      throw JimError.gifEncodingFailed
    }

    let artifact = try Self.inspect(output)
    guard artifact.pixelWidth == configuration.pixelWidth,
      artifact.pixelHeight == configuration.pixelHeight,
      artifact.frameCount == configuration.frameCount,
      artifact.loopCount == 0,
      abs(artifact.frameDelay - configuration.frameDelay) < 0.001
    else {
      throw JimError.invalidGIF
    }
    guard artifact.hasTransparentBackground else {
      throw JimError.opaqueGIFBackground
    }
    return artifact
  }

  public static func inspect(_ url: URL) throws -> JimDemoArtifact {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetType(source) == Self.gifType,
      let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw JimError.invalidGIF
    }
    let frameCount = CGImageSourceGetCount(source)
    let globalProperties =
      CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    let gifProperties =
      globalProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    let loopCount = (gifProperties?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue ?? -1
    var totalFrameDelay = 0.0
    for index in 0..<frameCount {
      let properties =
        CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      let gifFrameProperties =
        properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
      guard
        let delay =
          (gifFrameProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
          ?? (gifFrameProperties?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue,
        delay > 0
      else {
        throw JimError.invalidGIF
      }
      totalFrameDelay += delay
    }
    let frameDelay = frameCount > 0 ? totalFrameDelay / Double(frameCount) : 0

    var hasTransparentBackground = true
    for index in 0..<frameCount {
      guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
        throw JimError.invalidGIF
      }
      let bitmap = NSBitmapImageRep(cgImage: image)
      let corners = [
        (0, 0),
        (image.width - 1, 0),
        (0, image.height - 1),
        (image.width - 1, image.height - 1),
      ]
      if corners.contains(where: { x, y in
        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) >= 0.01
      }) {
        hasTransparentBackground = false
        break
      }
    }
    let byteCount = try Data(contentsOf: url, options: [.mappedIfSafe]).count
    return JimDemoArtifact(
      url: url,
      pixelWidth: first.width,
      pixelHeight: first.height,
      frameCount: frameCount,
      loopCount: loopCount,
      frameDelay: frameDelay,
      byteCount: byteCount,
      hasTransparentBackground: hasTransparentBackground
    )
  }
}
