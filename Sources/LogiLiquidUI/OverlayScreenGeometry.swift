import CoreGraphics

/// One display expressed in both coordinate systems the overlay must reconcile.
///
/// The backend reports the ring origin as a CoreGraphics global point
/// (`CGEvent.location`): the origin is the top-left of the primary display and
/// `y` increases downward. AppKit windows, by contrast, live in a global space
/// whose origin is the bottom-left of the primary display with `y` increasing
/// upward. The overlay panel is sized to `appKitFrame`; SwiftUI content is then
/// positioned in the display's own top-left space, which matches CoreGraphics
/// and therefore also matches the relative vectors the backend already emits.
public struct OverlayDisplay: Equatable, Sendable {
  /// CoreGraphics global bounds: top-left origin, `y` increasing downward.
  public let cgFrame: CGRect
  /// AppKit global bounds: bottom-left origin, `y` increasing upward.
  public let appKitFrame: CGRect
  /// Backing scale factor (2 on Retina). Carried so the caller can reason about
  /// physical-pixel alignment without re-querying the window server.
  public let backingScaleFactor: CGFloat

  public init(cgFrame: CGRect, appKitFrame: CGRect, backingScaleFactor: CGFloat) {
    self.cgFrame = cgFrame
    self.appKitFrame = appKitFrame
    self.backingScaleFactor = backingScaleFactor
  }
}

/// The resolved home for one interaction: which display to cover and where,
/// inside that display's top-left space, the hidden cursor's origin falls.
public struct OverlayPlacement: Equatable, Sendable {
  public let display: OverlayDisplay
  /// The origin in the display's local, top-left, `y`-down space. SwiftUI content
  /// anchors here; a target at `vectorFromOrigin` renders at `localOrigin + vector`.
  public let localOrigin: CGPoint

  public init(display: OverlayDisplay, localOrigin: CGPoint) {
    self.display = display
    self.localOrigin = localOrigin
  }
}

/// Pure conversions between CoreGraphics global, AppKit global, and per-display
/// local coordinates. No AppKit dependency so every rule is unit-testable.
public enum OverlayScreenGeometry {
  /// Converts a CoreGraphics global point (top-left origin) to an AppKit global
  /// point (bottom-left origin). `primaryDisplayHeight` is the height of the
  /// display that owns the origin — `NSScreen.screens[0].frame.height`.
  public static func appKitPoint(
    fromCGGlobal point: CGPoint,
    primaryDisplayHeight: CGFloat
  ) -> CGPoint {
    CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
  }

  /// Converts an AppKit global frame (bottom-left origin) to a CoreGraphics
  /// global frame (top-left origin). The transform is its own inverse.
  public static func cgFrame(
    fromAppKit frame: CGRect,
    primaryDisplayHeight: CGFloat
  ) -> CGRect {
    CGRect(
      x: frame.minX,
      y: primaryDisplayHeight - frame.maxY,
      width: frame.width,
      height: frame.height
    )
  }

  /// The origin's position inside a display's local top-left space.
  public static func localOrigin(
    forCGGlobalPoint point: CGPoint,
    in display: OverlayDisplay
  ) -> CGPoint {
    CGPoint(
      x: point.x - display.cgFrame.minX,
      y: point.y - display.cgFrame.minY
    )
  }

  /// Resolves the placement for a CoreGraphics global origin. The display whose
  /// bounds contain the point wins; if none do (the point sits in dead space
  /// between mismatched displays), the display with the nearest edge is chosen
  /// so the overlay still appears rather than silently vanishing.
  public static func placement(
    forCGGlobalPoint point: CGPoint,
    displays: [OverlayDisplay]
  ) -> OverlayPlacement? {
    guard !displays.isEmpty else { return nil }

    let containing = displays.first { $0.cgFrame.contains(point) }
    let display =
      containing
      ?? displays.min {
        squaredDistance(from: point, to: $0.cgFrame)
          < squaredDistance(from: point, to: $1.cgFrame)
      }
    guard let display else { return nil }

    return OverlayPlacement(
      display: display,
      localOrigin: localOrigin(forCGGlobalPoint: point, in: display)
    )
  }

  private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let clampedX = min(max(point.x, rect.minX), rect.maxX)
    let clampedY = min(max(point.y, rect.minY), rect.maxY)
    let dx = point.x - clampedX
    let dy = point.y - clampedY
    return dx * dx + dy * dy
  }
}
