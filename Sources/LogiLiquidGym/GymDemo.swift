import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import LogiLiquidCore
import LogiLiquidUI
import QuartzCore
import ScreenCaptureKit
import SwiftUI

/// Deterministic output settings for the CommandBloom demo video.
public struct GymDemoConfiguration: Codable, Equatable, Sendable {
  public static let `default` = GymDemoConfiguration(
    pixelWidth: 1_280,
    pixelHeight: 800,
    framesPerSecond: 60,
    duration: GymDemoTimeline.Timing.total
  )

  public let pixelWidth: Int
  public let pixelHeight: Int
  public let framesPerSecond: Int
  public let duration: Double

  public init(
    pixelWidth: Int,
    pixelHeight: Int,
    framesPerSecond: Int,
    duration: Double = GymDemoTimeline.Timing.total
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

  public func validate() throws {
    guard (320...1_920).contains(pixelWidth) else {
      throw GymError.invalidDimension(name: "demo width", value: pixelWidth)
    }
    guard (320...1_200).contains(pixelHeight) else {
      throw GymError.invalidDimension(name: "demo height", value: pixelHeight)
    }
    guard (12...60).contains(framesPerSecond) else {
      throw GymError.invalidFrameRate(framesPerSecond)
    }
    guard duration.isFinite, (2...8).contains(duration) else {
      throw GymError.invalidDuration(duration)
    }
  }
}

@MainActor
private final class GymDemoWindowHost {
  private let timeline: GymDemoTimeline
  private let window: NSWindow
  private let hostingView: NSHostingView<GymDemoScene>
  private let shareableWindow: SCWindow
  private let captureConfiguration: SCStreamConfiguration

  init(timeline: GymDemoTimeline) async throws {
    self.timeline = timeline
    let configuration = timeline.configuration
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    application.appearance = NSAppearance(named: .darkAqua)
    application.finishLaunching()

    let firstScene = GymDemoScene(
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

    window = NSWindow(
      contentRect: contentFrame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.isOpaque = true
    window.backgroundColor = .black
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.appearance = NSAppearance(named: .darkAqua)
    window.collectionBehavior = [.stationary]
    window.level = .floating
    let windowTitle = "Gym CommandBloom Demo \(UUID().uuidString)"
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
      throw GymError.hostedWindowUnavailable(window.windowNumber)
    }
    shareableWindow = resolvedWindow

    captureConfiguration = SCStreamConfiguration()
    captureConfiguration.width = configuration.pixelWidth
    captureConfiguration.height = configuration.pixelHeight
    captureConfiguration.showsCursor = false
    captureConfiguration.capturesAudio = false
    captureConfiguration.ignoreShadowsSingleWindow = true
    try await Task.sleep(for: .milliseconds(100))
  }

  func capture(_ frame: GymDemoFrame) async throws -> CGImage {
    hostingView.rootView = GymDemoScene(frame: frame, timeline: timeline)
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

/// The composed demo frame: a macOS-style wallpaper, the standard pointer, the
/// Sense Panel buzz, the production `OverlayView` on top, and a recording HUD
/// for the voice hand-off.
private struct GymDemoScene: View {
  let frame: GymDemoFrame
  let timeline: GymDemoTimeline

  var body: some View {
    let configuration = timeline.configuration
    let size = CGSize(
      width: CGFloat(configuration.pixelWidth),
      height: CGFloat(configuration.pixelHeight)
    )
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    ZStack {
      GymDemoWallpaper()
      ZStack {
        OverlayView(
          model: model,
          localOrigin: center,
          presentationProgress: CGFloat(frame.presentationProgress),
          onPrimaryClick: {}
        )
        .opacity(frame.overallOpacity)
        commitFlash(center: center)
        buzzRipples(center: center)
        pointer(center: center)
        recordingHUD(center: center)
      }
      .frame(width: size.width, height: size.height)
      .scaleEffect(sceneScale)
    }
    .frame(width: size.width, height: size.height)
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

  @ViewBuilder
  private func pointer(center: CGPoint) -> some View {
    if frame.cursorVisible {
      let image = NSCursor.arrow.image
      let hotSpot = NSCursor.arrow.hotSpot
      Image(nsImage: image)
        .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
        .position(
          x: center.x - hotSpot.x + (image.size.width / 2) + frame.cursorShakeOffset.x,
          y: center.y - hotSpot.y + (image.size.height / 2) + frame.cursorShakeOffset.y
        )
    }
  }

  /// Two expanding rings around the pointer read as the Sense Panel's haptic
  /// click without inventing UI the product does not have.
  @ViewBuilder
  private func buzzRipples(center: CGPoint) -> some View {
    if frame.buzzProgress > 0 {
      ForEach(0..<2, id: \.self) { ring in
        let progress = min(max((frame.buzzProgress * 1.35) - (Double(ring) * 0.3), 0), 1)
        if progress > 0 {
          Circle()
            .stroke(
              Color.white.opacity((1 - progress) * 0.85),
              lineWidth: 2.5 - CGFloat(progress)
            )
            .frame(
              width: 26 + CGFloat(progress) * 74,
              height: 26 + CGFloat(progress) * 74
            )
            .position(x: center.x, y: center.y)
        }
      }
    }
  }

  @ViewBuilder
  private func commitFlash(center: CGPoint) -> some View {
    if frame.commitPulse > 0, frame.commitPulse < 1 {
      let target = timeline.commitTargetOffset
      Circle()
        .stroke(
          OverlayTheme.violetStrong.opacity((1 - frame.commitPulse) * 0.8),
          lineWidth: 3 * (1 - CGFloat(frame.commitPulse)) + 0.5
        )
        .frame(
          width: OverlayTheme.targetBubbleDiameter * (1 + CGFloat(frame.commitPulse) * 0.9),
          height: OverlayTheme.targetBubbleDiameter * (1 + CGFloat(frame.commitPulse) * 0.9)
        )
        .position(x: center.x + target.x, y: center.y + target.y)
    }
  }

  /// The voice hand-off: once the microphone action commits, a floating pill
  /// shows live recording levels. This stands in for the voice app's own HUD,
  /// which only appears on a real desktop.
  @ViewBuilder
  private func recordingHUD(center: CGPoint) -> some View {
    if frame.recordingProgress > 0 {
      let time = Double(frame.index) / Double(timeline.configuration.framesPerSecond)
      HStack(spacing: 9) {
        Image(systemName: "mic.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(OverlayTheme.text)
        HStack(spacing: 3) {
          ForEach(0..<5, id: \.self) { bar in
            let level = 0.5 + (0.5 * sin((time * 7) + (Double(bar) * 1.1)))
            Capsule()
              .fill(OverlayTheme.text.opacity(0.85))
              .frame(width: 3, height: 5 + (9 * level))
          }
        }
        Circle()
          .fill(Color.red)
          .frame(width: 7, height: 7)
          .opacity(0.55 + (0.45 * sin(time * 5)))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .glassEffect(
        .regular.tint(OverlayTheme.violet.opacity(0.30)).interactive(),
        in: Capsule()
      )
      .scaleEffect(0.82 + (0.18 * frame.recordingProgress))
      .opacity(frame.recordingProgress)
      .position(x: center.x, y: center.y + 152)
    }
  }

  private var model: OverlayRenderModel {
    let targets = timeline.targets.map { target in
      OverlayTargetModel(
        id: target.id,
        actionName: target.actionName,
        zone: target.zone,
        presentation: target.presentation,
        offset: target.offset,
        isCurrent: target.id == frame.activeTargetID
      )
    }
    let phase: RingInteractionPhase =
      switch frame.phase {
      case .bloom, .rebloom: .invoked
      case .tease, .dwell, .travel: .tracking
      case .suction, .committed: .latched
      case .dismissing, .desktop, .recording: .idle
      }
    return OverlayRenderModel(
      phase: phase,
      cgOrigin: .zero,
      targets: targets,
      bubbleOffset: frame.bubbleOffset,
      mergeProgress: frame.mergeProgress,
      approachProgress: frame.approachProgress,
      currentTargetID: frame.activeTargetID
    )
  }
}

/// A deterministic macOS-style wallpaper: large soft color fields over a deep
/// blue base, so the glass ring reads exactly as it does on a real desktop
/// without ever capturing the user's actual screen.
private struct GymDemoWallpaper: View {
  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      ZStack {
        LinearGradient(
          colors: [
            Color(red: 0.09, green: 0.13, blue: 0.32),
            Color(red: 0.16, green: 0.11, blue: 0.38),
            Color(red: 0.05, green: 0.09, blue: 0.24),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        Ellipse()
          .fill(Color(red: 0.86, green: 0.32, blue: 0.55).opacity(0.55))
          .frame(width: size.width * 0.9, height: size.height * 0.7)
          .blur(radius: size.width * 0.09)
          .offset(x: -size.width * 0.32, y: -size.height * 0.34)
        Ellipse()
          .fill(Color(red: 0.35, green: 0.42, blue: 0.95).opacity(0.6))
          .frame(width: size.width * 1.0, height: size.height * 0.8)
          .blur(radius: size.width * 0.1)
          .offset(x: size.width * 0.36, y: -size.height * 0.18)
        Ellipse()
          .fill(Color(red: 0.16, green: 0.65, blue: 0.72).opacity(0.5))
          .frame(width: size.width * 0.95, height: size.height * 0.75)
          .blur(radius: size.width * 0.1)
          .offset(x: size.width * 0.12, y: size.height * 0.42)
        Ellipse()
          .fill(Color(red: 0.55, green: 0.30, blue: 0.85).opacity(0.45))
          .frame(width: size.width * 0.8, height: size.height * 0.6)
          .blur(radius: size.width * 0.09)
          .offset(x: -size.width * 0.3, y: size.height * 0.36)
      }
      .frame(width: size.width, height: size.height)
      .clipped()
    }
    .ignoresSafeArea()
  }
}

public enum GymDemoPhase: String, CaseIterable, Sendable {
  case bloom
  case tease
  case dwell
  case dismissing
  case desktop
  case rebloom
  case travel
  case suction
  case committed
  case recording
}

/// One deterministic visual frame. Geometry remains in the production
/// overlay's logical point space and is scaled only by the native renderer.
public struct GymDemoFrame: Equatable, Sendable {
  public let index: Int
  public let phase: GymDemoPhase
  public let presentationProgress: Double
  public let overallOpacity: Double
  public let bubbleOffset: CGPoint
  public let mergeProgress: Double
  /// Gradual selection lighting toward `activeTargetID`.
  public let approachProgress: Double
  /// The target lit by the current approach, if any.
  public let activeTargetID: String?
  public let cursorVisible: Bool
  public let cursorShakeOffset: CGPoint
  public let buzzProgress: Double
  public let commitPulse: Double
  /// 0 hides the voice-recording HUD; 1 shows it fully settled.
  public let recordingProgress: Double

  public init(
    index: Int,
    phase: GymDemoPhase,
    presentationProgress: Double,
    overallOpacity: Double,
    bubbleOffset: CGPoint,
    mergeProgress: Double,
    approachProgress: Double,
    activeTargetID: String?,
    cursorVisible: Bool,
    cursorShakeOffset: CGPoint = .zero,
    buzzProgress: Double = 0,
    commitPulse: Double = 0,
    recordingProgress: Double = 0
  ) {
    self.index = index
    self.phase = phase
    self.presentationProgress = presentationProgress
    self.overallOpacity = overallOpacity
    self.bubbleOffset = bubbleOffset
    self.mergeProgress = mergeProgress
    self.approachProgress = approachProgress
    self.activeTargetID = activeTargetID
    self.cursorVisible = cursorVisible
    self.cursorShakeOffset = cursorShakeOffset
    self.buzzProgress = buzzProgress
    self.commitPulse = commitPulse
    self.recordingProgress = recordingProgress
  }
}

/// A clock-free animation authored from the real Core/Gym scenarios. The first
/// frame already shows the bloomed ring, so the result is visible immediately.
/// Act 1 slowly teases the right-side middle target to show gradual approach
/// lighting, then a Sense Panel press dismisses the ring and the cursor
/// returns. Act 2 presses again, blooms, drops straight to the bottom
/// microphone target, latches with the haptic buzz, and hands off to a
/// recording HUD as the cursor reappears.
public struct GymDemoTimeline: Sendable {
  public enum Timing {
    // Act 1: tease one target, then toggle the ring closed.
    public static let teaseStart = 0.5
    public static let teaseEnd = 1.7
    public static let dwellEnd = 2.3
    public static let dismissEnd = 2.62
    public static let desktopEnd = 3.3
    // Act 2: reopen and commit straight down to the microphone.
    public static let rebloomEnd = 3.65
    public static let travelStart = 3.8
    public static let travelEnd = 4.6
    public static let suctionEnd = 4.76
    public static let commitEnd = 5.06
    public static let fadeEnd = 5.3
    public static let total = 7.5

    /// Every real buzz surfaces as one ripple window: both Sense Panel
    /// presses and the haptic fired exactly once when the action latches.
    public static let buzzWindows: [(start: Double, end: Double)] = [
      (dwellEnd, dwellEnd + 0.25),
      (desktopEnd, desktopEnd + 0.25),
      (travelEnd, travelEnd + 0.25),
    ]
  }

  /// Act 1 stops here: a fifth of the way to the teased target, far enough
  /// for the gradual lighting to read without ever threatening a latch.
  private static let teaseFraction = 0.2

  public let configuration: GymDemoConfiguration
  public let targets: [OverlayTargetModel]
  /// The right-zone middle target teased in act 1.
  public let teaseTargetID: String
  public let teaseTargetOffset: CGPoint
  /// The bottom target committed in act 2.
  public let commitTargetID: String
  public let commitTargetOffset: CGPoint
  /// Core's exact latch boundary along the path to the commit target.
  public let latchThresholdOffset: CGPoint

  public init(configuration: GymDemoConfiguration = .default) throws {
    try configuration.validate()
    let logicalSize = CGSize(width: configuration.pixelWidth, height: configuration.pixelHeight)
    let invoked = try GymScenario.make(.invoked, logicalSize: logicalSize)

    let rightTargets = invoked.model.targets.filter { $0.zone == .right }
    guard
      !rightTargets.isEmpty,
      let commit = invoked.model.targets.first(where: { $0.zone == .bottom })
    else {
      throw GymError.invalidDemoScenario
    }

    let tease = rightTargets[rightTargets.count / 2]
    let commitDistance = hypot(commit.offset.x, commit.offset.y)
    let latchDistance = GymScenario.latchThresholdCenterDistance()
    guard commitDistance > latchDistance else {
      throw GymError.invalidDemoScenario
    }
    let latchScale = (commitDistance - latchDistance) / commitDistance

    self.configuration = configuration
    targets = invoked.model.targets
    teaseTargetID = tease.id
    teaseTargetOffset = tease.offset
    commitTargetID = commit.id
    commitTargetOffset = commit.offset
    latchThresholdOffset = CGPoint(
      x: commit.offset.x * latchScale,
      y: commit.offset.y * latchScale
    )
  }

  public func frame(at index: Int) -> GymDemoFrame {
    let clampedIndex = min(max(index, 0), configuration.frameCount - 1)
    let time = Double(clampedIndex) / Double(configuration.framesPerSecond)
    let buzz = Self.buzzProgress(at: time)
    let shake = Self.cursorShake(buzz: buzz)

    switch time {
    // Act 1 opens on the fully bloomed ring: the first frame shows the result.
    case ..<Timing.teaseStart:
      return GymDemoFrame(
        index: clampedIndex,
        phase: .bloom,
        presentationProgress: 1,
        overallOpacity: 1,
        bubbleOffset: .zero,
        mergeProgress: 0,
        approachProgress: 0,
        activeTargetID: nil,
        cursorVisible: false,
        buzzProgress: buzz
      )

    case ..<Timing.teaseEnd:
      let progress = Self.smootherstep(
        (time - Timing.teaseStart) / (Timing.teaseEnd - Timing.teaseStart)
      )
      // A restrained lateral arc makes pointer motion legible without changing
      // the exact partial-approach endpoint.
      let lateralArc = 8 * sin(.pi * progress)
      let offset = CGPoint(
        x: Self.interpolate(0, teaseTargetOffset.x * Self.teaseFraction, progress),
        y: Self.interpolate(0, teaseTargetOffset.y * Self.teaseFraction, progress) + lateralArc
      )
      return GymDemoFrame(
        index: clampedIndex,
        phase: .tease,
        presentationProgress: 1,
        overallOpacity: 1,
        bubbleOffset: offset,
        mergeProgress: mergeProgress(at: offset, toward: teaseTargetOffset),
        approachProgress: approachProgress(at: offset, toward: teaseTargetOffset),
        activeTargetID: teaseTargetID,
        cursorVisible: false,
        buzzProgress: buzz
      )

    case ..<Timing.dwellEnd:
      // A slow breathe around the tease point makes the proximity lighting
      // visibly track distance.
      let breathe =
        2.5 * sin(2 * .pi * (time - Timing.teaseEnd) / (Timing.dwellEnd - Timing.teaseEnd))
      let offset = CGPoint(
        x: (teaseTargetOffset.x * Self.teaseFraction)
          + (breathe * Self.unitX(to: teaseTargetOffset)),
        y: (teaseTargetOffset.y * Self.teaseFraction)
          + (breathe * Self.unitY(to: teaseTargetOffset))
      )
      return GymDemoFrame(
        index: clampedIndex,
        phase: .dwell,
        presentationProgress: 1,
        overallOpacity: 1,
        bubbleOffset: offset,
        mergeProgress: mergeProgress(at: offset, toward: teaseTargetOffset),
        approachProgress: approachProgress(at: offset, toward: teaseTargetOffset),
        activeTargetID: teaseTargetID,
        cursorVisible: false,
        buzzProgress: buzz
      )

    case ..<Timing.dismissEnd:
      // The toggle press cancels the ring: it contracts and fades while the
      // cursor returns.
      let progress = Self.smootherstep(
        (time - Timing.dwellEnd) / (Timing.dismissEnd - Timing.dwellEnd)
      )
      let offset = CGPoint(
        x: teaseTargetOffset.x * Self.teaseFraction,
        y: teaseTargetOffset.y * Self.teaseFraction
      )
      return GymDemoFrame(
        index: clampedIndex,
        phase: .dismissing,
        presentationProgress: 1 - (0.12 * progress),
        overallOpacity: 1 - progress,
        bubbleOffset: offset,
        mergeProgress: mergeProgress(at: offset, toward: teaseTargetOffset),
        approachProgress: approachProgress(at: offset, toward: teaseTargetOffset),
        activeTargetID: teaseTargetID,
        cursorVisible: true,
        cursorShakeOffset: shake,
        buzzProgress: buzz
      )

    case ..<Timing.desktopEnd:
      return desktopFrame(index: clampedIndex, buzz: buzz, shake: shake)

    // Act 2: the second press re-blooms the ring around the hidden cursor.
    case ..<Timing.rebloomEnd:
      let progress = Self.smoothstep(
        (time - Timing.desktopEnd) / (Timing.rebloomEnd - Timing.desktopEnd)
      )
      return GymDemoFrame(
        index: clampedIndex,
        phase: .rebloom,
        presentationProgress: progress,
        overallOpacity: min(1, progress * 1.7),
        bubbleOffset: .zero,
        mergeProgress: 0,
        approachProgress: 0,
        activeTargetID: nil,
        cursorVisible: false,
        buzzProgress: buzz
      )

    case ..<Timing.travelStart:
      return GymDemoFrame(
        index: clampedIndex,
        phase: .rebloom,
        presentationProgress: 1,
        overallOpacity: 1,
        bubbleOffset: .zero,
        mergeProgress: 0,
        approachProgress: 0,
        activeTargetID: nil,
        cursorVisible: false,
        buzzProgress: buzz
      )

    case ..<Timing.travelEnd:
      let progress = Self.smootherstep(
        (time - Timing.travelStart) / (Timing.travelEnd - Timing.travelStart)
      )
      let offset = CGPoint(
        x: Self.interpolate(0, latchThresholdOffset.x, progress),
        y: Self.interpolate(0, latchThresholdOffset.y, progress)
      )
      return GymDemoFrame(
        index: clampedIndex,
        phase: .travel,
        presentationProgress: 1,
        overallOpacity: 1,
        bubbleOffset: offset,
        mergeProgress: mergeProgress(at: offset, toward: commitTargetOffset),
        approachProgress: approachProgress(at: offset, toward: commitTargetOffset),
        activeTargetID: commitTargetID,
        cursorVisible: false,
        buzzProgress: buzz
      )

    case ..<Timing.suctionEnd:
      let progress = Self.smootherstep(
        (time - Timing.travelEnd) / (Timing.suctionEnd - Timing.travelEnd)
      )
      return GymDemoFrame(
        index: clampedIndex,
        phase: .suction,
        presentationProgress: 1,
        overallOpacity: 1,
        bubbleOffset: Self.interpolate(latchThresholdOffset, commitTargetOffset, progress),
        mergeProgress: Self.interpolate(
          mergeProgress(at: latchThresholdOffset, toward: commitTargetOffset), 1, progress
        ),
        approachProgress: Self.interpolate(
          approachProgress(at: latchThresholdOffset, toward: commitTargetOffset), 1, progress
        ),
        activeTargetID: commitTargetID,
        cursorVisible: false,
        buzzProgress: buzz
      )

    case ..<Timing.commitEnd:
      let progress = (time - Timing.suctionEnd) / (Timing.commitEnd - Timing.suctionEnd)
      return GymDemoFrame(
        index: clampedIndex,
        phase: .committed,
        presentationProgress: 1,
        overallOpacity: 1,
        bubbleOffset: commitTargetOffset,
        mergeProgress: 1,
        approachProgress: 1,
        activeTargetID: commitTargetID,
        cursorVisible: false,
        buzzProgress: buzz,
        commitPulse: min(max(progress, 0), 1)
      )

    case ..<Timing.fadeEnd:
      let progress = Self.smootherstep(
        (time - Timing.commitEnd) / (Timing.fadeEnd - Timing.commitEnd)
      )
      return GymDemoFrame(
        index: clampedIndex,
        phase: .dismissing,
        presentationProgress: 1 - (0.12 * progress),
        overallOpacity: 1 - progress,
        bubbleOffset: commitTargetOffset,
        mergeProgress: 1,
        approachProgress: 1,
        activeTargetID: commitTargetID,
        cursorVisible: true,
        commitPulse: 1
      )

    default:
      // The voice app takes over: the recording HUD settles in with the
      // cursor back on the desktop.
      let progress = Self.smoothstep((time - Timing.fadeEnd) / 0.32)
      return GymDemoFrame(
        index: clampedIndex,
        phase: .recording,
        presentationProgress: 1,
        overallOpacity: 0,
        bubbleOffset: commitTargetOffset,
        mergeProgress: 1,
        approachProgress: 1,
        activeTargetID: nil,
        cursorVisible: true,
        recordingProgress: progress
      )
    }
  }

  private func desktopFrame(index: Int, buzz: Double, shake: CGPoint) -> GymDemoFrame {
    GymDemoFrame(
      index: index,
      phase: .desktop,
      presentationProgress: 0,
      overallOpacity: 0,
      bubbleOffset: .zero,
      mergeProgress: 0,
      approachProgress: 0,
      activeTargetID: nil,
      cursorVisible: true,
      cursorShakeOffset: shake,
      buzzProgress: buzz
    )
  }

  private func mergeProgress(at offset: CGPoint, toward target: CGPoint) -> Double {
    let distance = Self.distance(offset, target)
    return min(
      max(1 - (distance / RingInteractionProfile.default.mergeStartDistance), 0),
      1
    )
  }

  private func approachProgress(at offset: CGPoint, toward target: CGPoint) -> Double {
    min(
      max(1 - (Self.distance(offset, target) / RingInteractionProfile.default.ringRadius), 0),
      1
    )
  }

  private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    hypot(a.x - b.x, a.y - b.y)
  }

  private static func unitX(to target: CGPoint) -> Double {
    let magnitude = hypot(target.x, target.y)
    return magnitude > 0 ? target.x / magnitude : 0
  }

  private static func unitY(to target: CGPoint) -> Double {
    let magnitude = hypot(target.x, target.y)
    return magnitude > 0 ? target.y / magnitude : 0
  }

  private static func buzzProgress(at time: Double) -> Double {
    for window in Timing.buzzWindows where time >= window.start && time < window.end {
      return (time - window.start) / (window.end - window.start)
    }
    return 0
  }

  /// A decaying shake sells the physical Sense Panel click.
  private static func cursorShake(buzz: Double) -> CGPoint {
    guard buzz > 0 else { return .zero }
    let decay = 1 - smoothstep(buzz)
    return CGPoint(
      x: 3.4 * sin(buzz * .pi * 9) * decay,
      y: 1.2 * sin(buzz * .pi * 13) * decay
    )
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

public struct GymDemoArtifact: Codable, Equatable, Sendable {
  public let url: URL
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let frameCount: Int
  public let duration: Double
  public let byteCount: Int
  public let isH264: Bool
  public let hasOpaqueBackground: Bool
}

/// Native Gym renderer for the production `OverlayView`. It captures only its
/// dedicated AppKit window; desktop windows are never in scope. The output is
/// a high-quality H.264 MP4 suitable for GitHub and the project site.
@MainActor
public final class GymDemoRenderer {
  public init() {}

  public func render(
    to output: URL,
    poster posterURL: URL? = nil,
    configuration: GymDemoConfiguration = .default
  ) async throws -> GymDemoArtifact {
    let timeline = try GymDemoTimeline(configuration: configuration)
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: output)

    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    } catch {
      throw GymError.videoWriterCreationFailed(String(describing: error))
    }
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: configuration.pixelWidth,
        AVVideoHeightKey: configuration.pixelHeight,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 10_000_000,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          AVVideoExpectedSourceFrameRateKey: configuration.framesPerSecond,
          AVVideoMaxKeyFrameIntervalKey: configuration.framesPerSecond * 2,
        ],
      ]
    )
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: configuration.pixelWidth,
        kCVPixelBufferHeightKey as String: configuration.pixelHeight,
      ]
    )
    writer.add(input)
    guard writer.startWriting() else {
      throw GymError.videoEncodingFailed(String(describing: writer.error))
    }
    writer.startSession(atSourceTime: .zero)

    // The poster is the mid-suction moment: the bubble fusing into the
    // selected target tells the whole story in one still.
    let posterTime = (GymDemoTimeline.Timing.travelEnd + GymDemoTimeline.Timing.suctionEnd) / 2
    let posterIndex = min(
      configuration.frameCount - 1,
      Int((posterTime * Double(configuration.framesPerSecond)).rounded())
    )

    let host = try await GymDemoWindowHost(timeline: timeline)
    defer { host.close() }
    for index in 0..<configuration.frameCount {
      let image = try await host.capture(timeline.frame(at: index))
      if index == posterIndex, let posterURL {
        try Self.writePNG(image, to: posterURL)
      }
      while !input.isReadyForMoreMediaData {
        try await Task.sleep(for: .milliseconds(4))
      }
      let buffer = try Self.makePixelBuffer(
        from: image,
        pool: adaptor.pixelBufferPool,
        width: configuration.pixelWidth,
        height: configuration.pixelHeight
      )
      guard
        adaptor.append(
          buffer,
          withPresentationTime: CMTime(
            value: CMTimeValue(index),
            timescale: CMTimeScale(configuration.framesPerSecond)
          )
        )
      else {
        throw GymError.videoEncodingFailed(String(describing: writer.error))
      }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw GymError.videoEncodingFailed(String(describing: writer.error))
    }

    let artifact = try await Self.inspect(output)
    guard artifact.pixelWidth == configuration.pixelWidth,
      artifact.pixelHeight == configuration.pixelHeight,
      artifact.frameCount == configuration.frameCount,
      abs(artifact.duration - configuration.duration) < 0.05,
      artifact.isH264
    else {
      throw GymError.invalidVideo
    }
    guard artifact.hasOpaqueBackground else {
      throw GymError.demoBackgroundMissing
    }
    return artifact
  }

  public static func inspect(_ url: URL) async throws -> GymDemoArtifact {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw GymError.invalidVideo
    }
    let (naturalSize, formatDescriptions) = try await track.load(.naturalSize, .formatDescriptions)
    let duration = try await asset.load(.duration).seconds
    let isH264 = formatDescriptions.contains { description in
      CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264
    }

    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    reader.add(readerOutput)
    guard reader.startReading() else {
      throw GymError.invalidVideo
    }
    var frameCount = 0
    var middleFrame: CVPixelBuffer?
    while let sample = readerOutput.copyNextSampleBuffer() {
      if CMSampleBufferGetNumSamples(sample) > 0 {
        frameCount += 1
        let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        if middleFrame == nil, sampleTime >= duration / 2 {
          middleFrame = CMSampleBufferGetImageBuffer(sample)
        }
      }
    }
    guard reader.status == .completed, let middleFrame else {
      throw GymError.invalidVideo
    }

    let byteCount = try Data(contentsOf: url, options: [.mappedIfSafe]).count
    return GymDemoArtifact(
      url: url,
      pixelWidth: Int(naturalSize.width.rounded()),
      pixelHeight: Int(naturalSize.height.rounded()),
      frameCount: frameCount,
      duration: duration,
      byteCount: byteCount,
      isH264: isH264,
      hasOpaqueBackground: Self.cornersAreLit(middleFrame)
    )
  }

  /// The wallpaper must reach every corner of every frame; a black corner
  /// means the backdrop failed to cover the canvas.
  private static func cornersAreLit(_ buffer: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let inset = max(1, min(width, height) / 64)
    let corners = [
      (inset, inset),
      (width - inset - 1, inset),
      (inset, height - inset - 1),
      (width - inset - 1, height - inset - 1),
    ]
    return corners.allSatisfy { x, y in
      let pixel = base.advanced(by: (y * bytesPerRow) + (x * 4))
        .assumingMemoryBound(to: UInt8.self)
      // BGRA: any channel comfortably above black proves wallpaper coverage.
      return max(pixel[0], max(pixel[1], pixel[2])) > 8
    }
  }

  private static func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw GymError.pngEncodingFailed
    }
    try data.write(to: url, options: .atomic)
  }

  private static func makePixelBuffer(
    from image: CGImage,
    pool: CVPixelBufferPool?,
    width: Int,
    height: Int
  ) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    if let pool {
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    }
    if buffer == nil {
      CVPixelBufferCreate(
        nil,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [
          kCVPixelBufferWidthKey: width,
          kCVPixelBufferHeightKey: height,
        ] as CFDictionary,
        &buffer
      )
    }
    guard let buffer else {
      throw GymError.pixelBufferCreationFailed
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue
      )
    else {
      throw GymError.pixelBufferCreationFailed
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}
