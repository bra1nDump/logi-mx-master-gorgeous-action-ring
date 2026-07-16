import LogiLiquidCore

/// Inputs the overlay reducer folds into visibility decisions.
public enum OverlayInput: Equatable, Sendable {
  /// A decoded `ring.transition` frame from the backend event stream.
  case frame(RingFrame)
  /// The event stream closed or the daemon went away.
  case disconnected
}

/// The one-shot visibility side effect the host performs (present or order out
/// the panel). `nil` means "no visibility change."
public enum OverlayVisibilityEffect: Equatable, Sendable {
  case show
  case hide
}

/// Pure visibility state machine for the overlay.
///
/// Rules, per the interaction contract:
/// - The overlay is visible while the ring is `invoked`, `tracking`, or
///   `latched`; the latched frame must remain onscreen for the suction to finish.
/// - Sense-panel *release* is non-terminal and never hides: the backend keeps
///   emitting `invoked`/`tracking` frames, so visibility is unaffected.
/// - A terminal `committed`/`cancelled` frame (including the cancel produced by a
///   second Sense press) hides the overlay, and the hide effect fires exactly
///   once — repeated terminal or idle frames do not re-emit it.
/// - A disconnect hides immediately.
public struct OverlayReducer: Sendable {
  public private(set) var isVisible = false
  /// The most recent renderable model. Retained across a hide so the host can
  /// animate the overlay out instead of clipping it.
  public private(set) var model: OverlayRenderModel?

  public init() {}

  @discardableResult
  public mutating func reduce(_ input: OverlayInput) -> OverlayVisibilityEffect? {
    switch input {
    case .frame(let frame):
      let shouldShow =
        frame.phase == .invoked || frame.phase == .tracking || frame.phase == .latched
      if shouldShow {
        model = OverlayRenderModel(frame: frame)
      }
      return applyVisibility(shouldShow)
    case .disconnected:
      return applyVisibility(false)
    }
  }

  private mutating func applyVisibility(_ shouldShow: Bool) -> OverlayVisibilityEffect? {
    guard shouldShow != isVisible else { return nil }
    isVisible = shouldShow
    return shouldShow ? .show : .hide
  }
}
