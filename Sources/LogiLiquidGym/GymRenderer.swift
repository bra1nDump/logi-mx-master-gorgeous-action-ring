import AppKit
import CoreGraphics
import Foundation
import LogiLiquidUI
import ScreenCaptureKit
import SwiftUI

public struct GymRenderConfiguration: Codable, Equatable, Sendable {
  public static let `default` = GymRenderConfiguration(
    logicalWidth: 720,
    logicalHeight: 520,
    scale: 2
  )

  public let logicalWidth: Int
  public let logicalHeight: Int
  public let scale: Int

  public init(logicalWidth: Int, logicalHeight: Int, scale: Int) {
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
    self.scale = scale
  }

  public var logicalSize: CGSize {
    CGSize(width: logicalWidth, height: logicalHeight)
  }

  public var pixelWidth: Int { logicalWidth * scale }
  public var pixelHeight: Int { logicalHeight * scale }

  public func validate() throws {
    guard (320...4_096).contains(logicalWidth) else {
      throw GymError.invalidDimension(name: "width", value: logicalWidth)
    }
    guard (320...4_096).contains(logicalHeight) else {
      throw GymError.invalidDimension(name: "height", value: logicalHeight)
    }
    guard (1...4).contains(scale) else {
      throw GymError.invalidScale(scale)
    }
  }
}

public struct GymRenderedImage: Sendable {
  public let state: GymSnapshotState
  public let pngData: Data
  public let pixelWidth: Int
  public let pixelHeight: Int

  public init(
    state: GymSnapshotState,
    pngData: Data,
    pixelWidth: Int,
    pixelHeight: Int
  ) {
    self.state = state
    self.pngData = pngData
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

/// Renders the production SwiftUI overlay while it is attached to a real
/// AppKit window. This is intentional: native Liquid Glass needs a hosted view
/// hierarchy and window-backed environment to resolve its visual material.
@MainActor
public final class GymRenderer {
  public init() {}

  public func render(
    state: GymSnapshotState,
    configuration: GymRenderConfiguration = .default
  ) async throws -> GymRenderedImage {
    try configuration.validate()
    let scenario = try GymScenario.make(state, logicalSize: configuration.logicalSize)

    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    application.appearance = NSAppearance(named: .darkAqua)
    application.finishLaunching()

    let backdropView = NSHostingView(
      rootView: GymBackdrop()
        .frame(width: configuration.logicalSize.width, height: configuration.logicalSize.height)
        .environment(\.colorScheme, .dark)
    )
    let overlayScene = GymOverlayScene(
      model: scenario.model,
      logicalSize: configuration.logicalSize
    )
    .environment(\.colorScheme, .dark)

    let overlayView = NSHostingView(rootView: overlayScene)
    let contentFrame = CGRect(origin: .zero, size: configuration.logicalSize)
    let contentView = NSView(frame: contentFrame)
    contentView.wantsLayer = true
    contentView.layer?.backgroundColor = NSColor.black.cgColor
    for hostedView in [backdropView, overlayView] {
      hostedView.frame = contentView.bounds
      hostedView.autoresizingMask = [.width, .height]
      hostedView.wantsLayer = true
      contentView.addSubview(hostedView)
    }

    let window = NSWindow(
      contentRect: contentFrame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.isOpaque = true
    window.backgroundColor = .black
    window.hasShadow = false
    window.appearance = NSAppearance(named: .darkAqua)
    // ScreenCaptureKit can briefly retain a closed window in its shareable
    // content inventory. A unique title plus the CGWindowID prevents a later
    // render from accidentally capturing that stale entry if AppKit reuses a
    // window number.
    let windowTitle = "Gym Snapshot Host \(UUID().uuidString)"
    window.title = windowTitle
    window.collectionBehavior = [.stationary]
    window.level = .floating
    if let screen = NSScreen.screens.max(by: {
      $0.visibleFrame.width * $0.visibleFrame.height
        < $1.visibleFrame.width * $1.visibleFrame.height
    }) {
      let frame = CGRect(
        x: screen.visibleFrame.midX - (configuration.logicalSize.width / 2),
        y: screen.visibleFrame.midY - (configuration.logicalSize.height / 2),
        width: configuration.logicalSize.width,
        height: configuration.logicalSize.height
      )
      window.setFrame(frame, display: false)
    }
    window.contentView = contentView
    window.orderFrontRegardless()
    window.makeKey()
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }

    contentView.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    // Let the production presentation spring settle and give the glass
    // container enough hosted run-loop turns to resolve its backing layers.
    try await Task.sleep(for: .seconds(1))
    contentView.layoutSubtreeIfNeeded()
    backdropView.needsDisplay = true
    backdropView.displayIfNeeded()
    overlayView.needsDisplay = true
    overlayView.displayIfNeeded()
    window.displayIfNeeded()

    let capturedImage = try await capture(
      window: window,
      windowTitle: windowTitle,
      expectedLogicalSize: configuration.logicalSize,
      pixelWidth: configuration.pixelWidth,
      pixelHeight: configuration.pixelHeight
    )
    let bitmap = NSBitmapImageRep(cgImage: capturedImage)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
      throw GymError.pngEncodingFailed
    }

    return GymRenderedImage(
      state: state,
      pngData: pngData,
      pixelWidth: bitmap.pixelsWide,
      pixelHeight: bitmap.pixelsHigh
    )
  }

  private func capture(
    window: NSWindow,
    windowTitle: String,
    expectedLogicalSize: CGSize,
    pixelWidth: Int,
    pixelHeight: Int
  ) async throws -> CGImage {
    let windowID = CGWindowID(window.windowNumber)
    var shareableWindow: SCWindow?
    for _ in 0..<20 {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: false
      )
      shareableWindow = content.windows.first(where: {
        $0.windowID == windowID && $0.title == windowTitle
      })
      if shareableWindow != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard let shareableWindow else {
      throw GymError.hostedWindowUnavailable(window.windowNumber)
    }
    let capturedFrame = shareableWindow.frame
    guard
      abs(capturedFrame.width - expectedLogicalSize.width) < 0.5,
      abs(capturedFrame.height - expectedLogicalSize.height) < 0.5
    else {
      throw GymError.hostedWindowFrameMismatch(
        expectedWidth: Int(expectedLogicalSize.width),
        expectedHeight: Int(expectedLogicalSize.height),
        actualWidth: capturedFrame.width,
        actualHeight: capturedFrame.height
      )
    }

    let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
    let captureConfiguration = SCStreamConfiguration()
    captureConfiguration.width = pixelWidth
    captureConfiguration.height = pixelHeight
    captureConfiguration.showsCursor = false
    captureConfiguration.capturesAudio = false
    captureConfiguration.ignoreShadowsSingleWindow = true
    return try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: captureConfiguration
    )
  }
}

private struct GymOverlayScene: View {
  let model: OverlayRenderModel
  let logicalSize: CGSize

  var body: some View {
    OverlayView(
      model: model,
      localOrigin: CGPoint(x: logicalSize.width / 2, y: logicalSize.height / 2),
      onPrimaryClick: {}
    )
    .frame(width: logicalSize.width, height: logicalSize.height)
    .clipped()
  }
}

/// A stable wallpaper gives translucent glass actual content to refract while
/// keeping snapshots independent of the user's desktop.
private struct GymBackdrop: View {
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.035, green: 0.040, blue: 0.075),
          Color(red: 0.095, green: 0.050, blue: 0.145),
          Color(red: 0.025, green: 0.075, blue: 0.105),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Circle()
        .fill(Color(red: 0.30, green: 0.20, blue: 0.68).opacity(0.42))
        .frame(width: 290, height: 290)
        .blur(radius: 22)
        .offset(x: -210, y: -145)
      Circle()
        .fill(Color(red: 0.85, green: 0.18, blue: 0.52).opacity(0.30))
        .frame(width: 250, height: 250)
        .blur(radius: 25)
        .offset(x: 235, y: 155)
      GymBackdropLines()
        .stroke(Color.white.opacity(0.055), lineWidth: 1)
    }
  }
}

private struct GymBackdropLines: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let spacing: CGFloat = 32
    var x = rect.minX
    while x <= rect.maxX {
      path.move(to: CGPoint(x: x, y: rect.minY))
      path.addLine(to: CGPoint(x: x, y: rect.maxY))
      x += spacing
    }
    var y = rect.minY
    while y <= rect.maxY {
      path.move(to: CGPoint(x: rect.minX, y: y))
      path.addLine(to: CGPoint(x: rect.maxX, y: y))
      y += spacing
    }
    return path
  }
}
