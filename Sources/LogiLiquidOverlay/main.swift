import AppKit
import LogiLiquidControl

/// `logi-liquid-overlay` is the native Liquid Glass overlay for the standalone
/// mouse ring. It is transport and window glue only: it subscribes to the
/// existing daemon event stream, renders the ring, and forwards a primary click
/// or Escape back to the daemon. It hosts no daemon, settings, menu bar item, or
/// dock icon, and shows no window when idle — suitable for a per-user
/// LaunchAgent.
final class OverlayAppDelegate: NSObject, NSApplicationDelegate {
  private var controller: OverlayController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    OverlayLog.log(
      "starting (pid \(ProcessInfo.processInfo.processIdentifier)), daemon socket: "
        + LogiLiquidControlProtocol.defaultSocketURL.path
    )
    let controller = OverlayController()
    self.controller = controller
    controller.start()
  }
}

let application = NSApplication.shared
// Accessory: no dock icon, no menu bar presence, never becomes the active app.
application.setActivationPolicy(.accessory)
let delegate = OverlayAppDelegate()
application.delegate = delegate
application.run()
