import AppKit
import CoreGraphics

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
    isFloatingPanel = true
    worksWhenModal = true
    // Above everything, including full-screen spaces and the menu bar: the
    // ring must present wherever the pointer is. `.statusBar` is too low —
    // another app's full-screen space can cover it.
    level = .screenSaver
    hidesOnDeactivate = false
    isMovableByWindowBackground = false
    ignoresMouseEvents = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
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

  /// Whether WindowServer has actually composited this panel on the current
  /// Space. `isVisible` alone is insufficient: after sleep or a display/Space
  /// reconfiguration AppKit can report a window as visible while WindowServer
  /// keeps it detached from every active Space.
  var isOnScreenInWindowServer: Bool? {
    let number = windowNumber
    guard number > 0,
      let windows = CGWindowListCopyWindowInfo(
        .optionIncludingWindow,
        CGWindowID(number)
      ) as? [[String: Any]],
      let window = windows.first(where: {
        ($0[kCGWindowNumber as String] as? Int) == number
      })
    else {
      return nil
    }
    return window[kCGWindowIsOnscreen as String] as? Bool
  }

  var presentationDiagnostics: String {
    let windowServerState = isOnScreenInWindowServer.map(String.init) ?? "unknown"
    return "window=\(windowNumber) visible=\(isVisible) activeSpace=\(isOnActiveSpace) "
      + "occlusionVisible=\(occlusionState.contains(.visible)) "
      + "windowServerOnScreen=\(windowServerState)"
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

  /// Permanently retires this panel. Panels are deliberately single-use: a
  /// fresh native window gets a fresh WindowServer/Space association for every
  /// ring invocation.
  func retire() {
    pendingDismissal?.cancel()
    pendingDismissal = nil
    orderOut(nil)
    contentView = nil
    close()
  }
}
