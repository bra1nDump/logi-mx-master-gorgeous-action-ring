import AppKit

/// A borderless, transparent, non-activating panel that hosts the overlay.
///
/// It is invisible when idle (ordered out) and, while presented, becomes key
/// only so it can receive a primary click and the Escape key. Because it uses
/// `.nonactivatingPanel`, becoming key never activates this process, so the
/// frontmost application keeps its activation and regains key focus cleanly the
/// moment the panel orders out.
final class OverlayPanel: NSPanel {
  private let onDismiss: () -> Void
  private var pendingDismissal: DispatchWorkItem?

  init(contentView: NSView, onDismiss: @escaping () -> Void) {
    self.onDismiss = onDismiss
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    level = .statusBar
    hidesOnDeactivate = false
    isMovableByWindowBackground = false
    ignoresMouseEvents = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    contentView.autoresizingMask = [.width, .height]
    self.contentView = contentView
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// AppKit routes the Escape key here. Dismiss through the backend.
  override func cancelOperation(_ sender: Any?) {
    onDismiss()
  }

  /// Presents the panel covering `frame` (AppKit global coordinates) and takes
  /// key focus without activating the app.
  func present(displayFrame frame: NSRect) {
    pendingDismissal?.cancel()
    pendingDismissal = nil
    setFrame(frame, display: true)
    alphaValue = 1
    orderFrontRegardless()
    makeKey()
  }

  /// Orders the panel out and yields key focus back to the previous window.
  func dismissOverlay(after duration: TimeInterval) {
    pendingDismissal?.cancel()
    let dismissal = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.orderOut(nil)
      self.pendingDismissal = nil
    }
    pendingDismissal = dismissal
    DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, 0), execute: dismissal)
  }
}
