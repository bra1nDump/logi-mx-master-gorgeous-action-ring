import AppKit
import LogiLiquidControl
import LogiLiquidCore
import LogiLiquidUI
import SwiftUI

enum OverlayWindowEnvironmentChange: String, CaseIterable {
  case activeSpace
  case screenParameters
  case screensSleeping
  case screensWoke
  case systemSleeping
  case systemWoke

  var invalidatesInteraction: Bool {
    switch self {
    case .screensSleeping, .systemSleeping:
      true
    case .activeSpace, .screenParameters, .screensWoke, .systemWoke:
      false
    }
  }

  var refreshesPresentation: Bool {
    self == .activeSpace || self == .screenParameters
  }
}

/// Owns the overlay lifecycle: the hosting panel, the visibility reducer, the
/// event subscription, and the two backend commands the UI is allowed to send
/// (`simulate.click` and `simulate.dismiss`). It never hosts or drives the
/// daemon, and it never runs actions, haptics, or cursor changes itself.
@MainActor
final class OverlayController {
  private static let environmentRecoveryDelay: TimeInterval = 0.15
  private static let maximumPresentationAttempts = 3
  private static let restartDelayAfterPresentationFailure: TimeInterval = 0.5

  private let store = OverlayModelStore()
  private let client = UnixControlClient()
  private let commandQueue = DispatchQueue(label: "com.logiliquid.controls.overlay.commands")
  private let recoveryCommandQueue = DispatchQueue(
    label: "com.logiliquid.controls.overlay.recovery-commands",
    attributes: .concurrent
  )

  private var reducer = OverlayReducer()
  private var panel: OverlayPanel?
  private var stream: OverlayEventStream?
  private var observerTokens: [(NotificationCenter, NSObjectProtocol)] = []
  private var environmentRecovery: DispatchWorkItem?
  private var panelRetirement: DispatchWorkItem?
  private var presentationVerification: DispatchWorkItem?

  func start() {
    installWindowEnvironmentObservers()

    let stream = OverlayEventStream(client: client) { [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
    self.stream = stream
    stream.start()
  }

  private func handle(_ event: OverlayStreamEvent) {
    let input: OverlayInput
    switch event {
    case .transition(let frame): input = .frame(frame)
    case .disconnected: input = .disconnected
    }

    let effect = reducer.reduce(input)

    switch effect {
    case .show:
      cancelEnvironmentRecovery()
      presentOverlay(replacingPanel: true, reason: "new interaction")
    case .hide:
      cancelEnvironmentRecovery()
      cancelPresentationVerification()
      store.update(isVisible: false, model: reducer.model, localOrigin: store.localOrigin)
      dismissAndRetirePanel(after: OverlayTheme.dismissalDuration)
    case nil:
      // Within one interaction the origin is fixed; only the moving bubble,
      // selection, and merge progress change. Refresh render state in place.
      store.update(
        isVisible: reducer.isVisible,
        model: reducer.model,
        localOrigin: store.localOrigin
      )
    }
  }

  private func presentOverlay(
    replacingPanel: Bool,
    reason: String,
    attempt: Int = 1
  ) {
    cancelPresentationVerification()
    guard let model = reducer.model else { return }
    let placement = OverlayScreenGeometry.placement(
      forCGGlobalPoint: model.cgOrigin,
      displays: currentDisplays()
    )
    guard let placement else {
      // No display resolved (no screens): keep the panel hidden rather than
      // presenting an unplaced window.
      OverlayLog.log(
        "no display resolved for ring origin (\(model.cgOrigin.x), \(model.cgOrigin.y)); "
          + "keeping the overlay hidden"
      )
      store.update(isVisible: false, model: model, localOrigin: store.localOrigin)
      resetOverlayForInvalidWindowEnvironment(reason: "no display available")
      return
    }

    store.update(isVisible: true, model: model, localOrigin: placement.localOrigin)
    if replacingPanel || panel == nil {
      replacePanel(reason: reason)
    }
    guard let panel else { return }

    OverlayLog.log(
      "presenting ring at (\(model.cgOrigin.x), \(model.cgOrigin.y)); "
        + "reason=\(reason), attempt=\(attempt)"
    )
    panel.present(displayFrame: placement.display.appKitFrame)
    schedulePresentationVerification(for: panel, attempt: attempt)
  }

  private func makePanel() -> OverlayPanel {
    let hostingView = NSHostingView(
      rootView: OverlayHostView(
        store: store,
        onPrimaryClick: { [weak self] in self?.sendPrimaryClick() }
      )
    )
    return OverlayPanel(
      contentView: hostingView,
      onDismiss: { [weak self] in self?.sendDismiss() }
    )
  }

  private func replacePanel(reason: String) {
    panelRetirement?.cancel()
    panelRetirement = nil
    panel?.retire()
    let panel = makePanel()
    self.panel = panel
    OverlayLog.log("created fresh overlay panel; reason=\(reason), window=\(panel.windowNumber)")
  }

  private func dismissAndRetirePanel(after duration: TimeInterval) {
    panelRetirement?.cancel()
    guard let panel else { return }
    panel.dismissOverlay(after: duration)

    let retirement = DispatchWorkItem { [weak self, weak panel] in
      guard let self, let panel, self.panel === panel else { return }
      panel.retire()
      self.panel = nil
      self.panelRetirement = nil
    }
    panelRetirement = retirement
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(duration, 0) + 0.05,
      execute: retirement
    )
  }

  private func schedulePresentationVerification(for panel: OverlayPanel, attempt: Int) {
    let verification = DispatchWorkItem { [weak self, weak panel] in
      guard let self, let panel, self.panel === panel, self.reducer.isVisible else { return }
      self.presentationVerification = nil

      guard let isOnScreen = panel.isOnScreenInWindowServer else {
        OverlayLog.log(
          "overlay panel verification was inconclusive; keeping the panel; "
            + panel.presentationDiagnostics
        )
        return
      }
      guard !isOnScreen else {
        OverlayLog.log("overlay panel verified on-screen; \(panel.presentationDiagnostics)")
        return
      }

      OverlayLog.log(
        "overlay panel failed on-screen verification; attempt=\(attempt), "
          + panel.presentationDiagnostics
      )
      if attempt == 1 {
        // Space/fullscreen animations can briefly de-order a healthy panel.
        // Reassert it once before replacing the native window and its key focus.
        panel.present(displayFrame: panel.frame)
        self.schedulePresentationVerification(for: panel, attempt: attempt + 1)
      } else if attempt < Self.maximumPresentationAttempts {
        self.presentOverlay(
          replacingPanel: true,
          reason: "WindowServer verification retry",
          attempt: attempt + 1
        )
      } else {
        self.recoverFromPresentationFailure()
      }
    }
    presentationVerification = verification
    DispatchQueue.main.asyncAfter(
      deadline: .now() + presentationVerificationDelay(for: attempt),
      execute: verification
    )
  }

  private func presentationVerificationDelay(for attempt: Int) -> TimeInterval {
    0.18 * Double(max(attempt, 1))
  }

  private func recoverFromPresentationFailure() {
    OverlayLog.log(
      "overlay remained off-screen after rebuilding; cancelling the interaction "
        + "and restarting the overlay process"
    )
    resetOverlayForInvalidWindowEnvironment(reason: "presentation verification failed")

    let client = self.client
    recoveryCommandQueue.async {
      do {
        _ = try client.request(method: .simulateDismiss)
      } catch {
        OverlayLog.log("failed to dismiss the daemon before overlay restart: \(error)")
      }
    }
    // The control request is synchronous and the socket may itself be wedged.
    // Restart independently of its acknowledgement so launchd recovery is
    // always bounded.
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.restartDelayAfterPresentationFailure
    ) {
      NSApplication.shared.terminate(nil)
    }
  }

  @discardableResult
  private func resetOverlayForInvalidWindowEnvironment(reason: String) -> Bool {
    let wasVisible = reducer.isVisible
    cancelEnvironmentRecovery()
    cancelPresentationVerification()
    panelRetirement?.cancel()
    panelRetirement = nil
    _ = reducer.reduce(.disconnected)
    store.update(isVisible: false, model: reducer.model, localOrigin: store.localOrigin)
    panel?.retire()
    panel = nil
    OverlayLog.log("reset overlay window state; reason=\(reason)")
    return wasVisible
  }

  private func installWindowEnvironmentObservers() {
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    observe(
      center: workspaceCenter,
      name: NSWorkspace.activeSpaceDidChangeNotification,
      change: .activeSpace
    )
    observe(
      center: workspaceCenter,
      name: NSWorkspace.screensDidSleepNotification,
      change: .screensSleeping
    )
    observe(
      center: workspaceCenter,
      name: NSWorkspace.screensDidWakeNotification,
      change: .screensWoke
    )
    observe(
      center: workspaceCenter,
      name: NSWorkspace.willSleepNotification,
      change: .systemSleeping
    )
    observe(
      center: workspaceCenter,
      name: NSWorkspace.didWakeNotification,
      change: .systemWoke
    )
    observe(
      center: NotificationCenter.default,
      name: NSApplication.didChangeScreenParametersNotification,
      change: .screenParameters
    )
  }

  private func observe(
    center: NotificationCenter,
    name: Notification.Name,
    change: OverlayWindowEnvironmentChange
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleWindowEnvironmentChange(change)
      }
    }
    observerTokens.append((center, token))
  }

  private func handleWindowEnvironmentChange(_ change: OverlayWindowEnvironmentChange) {
    OverlayLog.log("window environment changed: \(change.rawValue)")
    if change.invalidatesInteraction {
      resetOverlayForInvalidWindowEnvironment(reason: change.rawValue)
      return
    }
    guard change.refreshesPresentation else { return }

    guard reducer.isVisible else {
      panel?.retire()
      panel = nil
      return
    }

    environmentRecovery?.cancel()
    let recovery = DispatchWorkItem { [weak self] in
      guard let self, self.reducer.isVisible else { return }
      self.environmentRecovery = nil
      self.presentOverlay(
        replacingPanel: false,
        reason: "window environment changed: \(change.rawValue)"
      )
    }
    environmentRecovery = recovery
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.environmentRecoveryDelay,
      execute: recovery
    )
  }

  private func cancelEnvironmentRecovery() {
    environmentRecovery?.cancel()
    environmentRecovery = nil
  }

  private func cancelPresentationVerification() {
    presentationVerification?.cancel()
    presentationVerification = nil
  }

  private func currentDisplays() -> [OverlayDisplay] {
    let screens = NSScreen.screens
    guard let primaryHeight = screens.first?.frame.height else { return [] }
    return screens.map { screen in
      OverlayDisplay(
        cgFrame: OverlayScreenGeometry.cgFrame(
          fromAppKit: screen.frame,
          primaryDisplayHeight: primaryHeight
        ),
        appKitFrame: screen.frame,
        backingScaleFactor: screen.backingScaleFactor
      )
    }
  }

  private func sendPrimaryClick() {
    send(.simulateClick)
  }

  private func sendDismiss() {
    send(.simulateDismiss)
  }

  private func send(_ method: ControlMethod) {
    let client = self.client
    commandQueue.async {
      do {
        _ = try client.request(method: method)
      } catch {
        OverlayLog.log("failed to send \(method.rawValue) to the daemon: \(error)")
      }
    }
  }
}
