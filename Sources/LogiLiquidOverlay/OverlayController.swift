import AppKit
import LogiLiquidControl
import LogiLiquidCore
import LogiLiquidUI
import SwiftUI

/// Owns the overlay lifecycle: the hosting panel, the visibility reducer, the
/// event subscription, and the two backend commands the UI is allowed to send
/// (`simulate.click` and `simulate.dismiss`). It never hosts or drives the
/// daemon, and it never runs actions, haptics, or cursor changes itself.
@MainActor
final class OverlayController {
  private let store = OverlayModelStore()
  private let client = UnixControlClient()
  private let commandQueue = DispatchQueue(label: "com.logiliquid.controls.overlay.commands")

  private var reducer = OverlayReducer()
  private var panel: OverlayPanel?
  private var stream: OverlayEventStream?

  func start() {
    let hostingView = NSHostingView(
      rootView: OverlayHostView(
        store: store,
        onPrimaryClick: { [weak self] in self?.sendPrimaryClick() }
      )
    )
    let panel = OverlayPanel(
      contentView: hostingView,
      onDismiss: { [weak self] in self?.sendDismiss() }
    )
    self.panel = panel

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
      presentOverlay()
    case .hide:
      store.update(isVisible: false, model: reducer.model, localOrigin: store.localOrigin)
      panel?.dismissOverlay(after: OverlayTheme.dismissalDuration)
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

  private func presentOverlay() {
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
      return
    }

    OverlayLog.log("presenting ring at (\(model.cgOrigin.x), \(model.cgOrigin.y))")
    store.update(isVisible: true, model: model, localOrigin: placement.localOrigin)
    panel?.present(displayFrame: placement.display.appKitFrame)
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
